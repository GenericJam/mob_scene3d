// MobScene3dView.mm — the iOS Filament applier + surface/lifecycle shim.
//
// CAMetalLayer surface, CADisplayLink vsync. The Engine is created on the
// main thread and every Filament call stays there (the spike's binding
// threading contract; Filament's backend driver runs on its own internal
// thread). Each display-link tick drains validated ops from the NIF-side
// runtime (mob_scene3d_nif.m) and applies them between frames — the
// scene-IR decision record's Filament mapping table, implemented.
//
// The renderer is fully rebuildable from the runtime's shadow registry:
// (re)attaching replays the scene, which is what survives mob's iOS
// navVersion root reset (any push/pop transition rebuilds the SwiftUI tree
// and recreates this view).
//
// Shadows are gated OFF under TARGET_OS_SIMULATOR: the Metal-on-simulator
// shadow pass zeroes the direct-light term (spike landmine 7). Physical
// Metal renders shadows.

#import "MobScene3dView.h"
#import "MobScene3dRuntime.h"

#import <QuartzCore/CAMetalLayer.h>

#include <filament/Box.h>
#include <filament/Camera.h>
#include <filament/Engine.h>
#include <filament/LightManager.h>
#include <filament/MaterialInstance.h>
#include <filament/Renderer.h>
#include <filament/Scene.h>
#include <filament/Skybox.h>
#include <filament/SwapChain.h>
#include <filament/TransformManager.h>
#include <filament/View.h>
#include <filament/Viewport.h>

#include <gltfio/AssetLoader.h>
#include <gltfio/FilamentAsset.h>
#include <gltfio/FilamentInstance.h>
#include <gltfio/MaterialProvider.h>
#include <gltfio/ResourceLoader.h>
#include <gltfio/materials/uberarchive.h>

#include <math/mat4.h>
#include <math/norm.h>
#include <math/quat.h>
#include <math/vec3.h>
#include <math/vec4.h>

#include <utils/Entity.h>
#include <utils/EntityManager.h>

#include <cmath>
#include <deque>
#include <map>
#include <string>
#include <vector>

using namespace filament;
using namespace filament::math;
using namespace filament::gltfio;

namespace {

struct S3dRec {
  utils::Entity entity{};
  NSMutableDictionary *json = nil;
  FilamentInstance *instance = nullptr;
  std::string assetRef;
  bool overridden = false;
  bool inScene = false;
  bool hasLight = false;
  Camera *camera = nullptr;
  std::string status = "ready";
  std::string statusDetail;
};

struct S3dAssetEntry {
  FilamentAsset *asset = nullptr;
  std::deque<FilamentInstance *> freeInstances;
};

double jnum(id value, double fallback) {
  return [value isKindOfClass:[NSNumber class]] ? [value doubleValue]
                                                : fallback;
}

bool jnull(id value) { return value == nil || value == [NSNull null]; }

NSString *kindOf(NSDictionary *entity) {
  id data = entity[@"data"];
  if (![data isKindOfClass:[NSDictionary class]])
    return @"group";
  NSString *kind = ((NSDictionary *)data)[@"kind"];
  return [kind isKindOfClass:[NSString class]] ? kind : @"group";
}

} // namespace

@interface MobScene3dView () {
  Engine *_engine;
  Renderer *_renderer;
  Scene *_scene;
  View *_view;
  SwapChain *_swapChain;
  Skybox *_skybox;

  utils::Entity _fallbackCameraEntity;
  Camera *_fallbackCamera;

  MaterialProvider *_materials;
  AssetLoader *_assetLoader;
  ResourceLoader *_resourceLoader;

  std::map<std::string, S3dRec> _registry;
  std::map<std::string, S3dAssetEntry> _assets;
  std::string _irCameraId;

  NSUInteger _frameCount;
  BOOL _readySent;
  BOOL _destroyed;
}
@property(nonatomic, strong, nullable) CADisplayLink *displayLink;
@property(nonatomic, copy) NSString *viewportId;
@end

@implementation MobScene3dView

+ (Class)layerClass {
  return [CAMetalLayer class];
}

- (instancetype)initWithFrame:(CGRect)frame viewportId:(NSString *)viewportId {
  self = [super initWithFrame:frame];
  if (self) {
    _viewportId = [viewportId copy];
    self.contentScaleFactor = UIScreen.mainScreen.scale;
    [self setupFilament];
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(appDidEnterBackground)
               name:UIApplicationDidEnterBackgroundNotification
             object:nil];
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(appWillEnterForeground)
               name:UIApplicationWillEnterForegroundNotification
             object:nil];
  }
  return self;
}

- (void)setupFilament {
  CAMetalLayer *metalLayer = (CAMetalLayer *)self.layer;
  metalLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;

  _engine = Engine::create(); // Backend::DEFAULT == Metal on iOS
  _renderer = _engine->createRenderer();
  _scene = _engine->createScene();
  _view = _engine->createView();
  _view->setScene(_scene);

#if TARGET_OS_SIMULATOR
  // Spike landmine 7: the Metal-on-simulator shadow pass blacks out the
  // direct-light term. Physical Metal renders shadows (verified on the
  // spike's Android hardware; this build re-verifies on iPhone hardware).
  _view->setShadowingEnabled(false);
#endif

  _fallbackCameraEntity = utils::EntityManager::get().create();
  _fallbackCamera = _engine->createCamera(_fallbackCameraEntity);
  _fallbackCamera->setExposure(16.0f, 1 / 125.0f, 100.0f);
  _fallbackCamera->lookAt(double3{0, 1.8, 4.8}, double3{0, 0, 0},
                          double3{0, 1, 0});
  _view->setCamera(_fallbackCamera);

  // Solid dark skybox: the surface is visibly alive even with no model.
  _skybox =
      Skybox::Builder().color({0.035f, 0.04f, 0.07f, 1.0f}).build(*_engine);
  _scene->setSkybox(_skybox);

  _materials = createUbershaderProvider(_engine, UBERARCHIVE_DEFAULT_DATA,
                                        UBERARCHIVE_DEFAULT_SIZE);
  AssetConfiguration config;
  config.engine = _engine;
  config.materials = _materials;
  _assetLoader = AssetLoader::create(config);
  ResourceConfiguration resources{};
  resources.engine = _engine;
  resources.normalizeSkinningWeights = true;
  _resourceLoader = new ResourceLoader(resources);
}

// ── lifecycle ────────────────────────────────────────────────────────────

- (void)didMoveToWindow {
  [super didMoveToWindow];
  if (self.window != nil) {
    // (Re)attach: rebuild the applied scene from the shadow registry.
    [self clearScene];
    [self applyOps:MobScene3dAttach(self.viewportId, self)];
    if (self.displayLink == nil) {
      self.displayLink =
          [CADisplayLink displayLinkWithTarget:self
                                      selector:@selector(renderFrame)];
      [self.displayLink addToRunLoop:NSRunLoop.mainRunLoop
                             forMode:NSRunLoopCommonModes];
    }
  } else {
    MobScene3dDetach(self.viewportId, self);
    [self.displayLink invalidate];
    self.displayLink = nil;
  }
}

- (void)appDidEnterBackground {
  // Metal command submission from a backgrounded app is a kill offense;
  // pause the vsync loop entirely.
  self.displayLink.paused = YES;
}

- (void)appWillEnterForeground {
  self.displayLink.paused = NO;
}

- (void)layoutSubviews {
  [super layoutSubviews];
  CAMetalLayer *metalLayer = (CAMetalLayer *)self.layer;
  CGFloat scale = self.contentScaleFactor;
  CGSize size = CGSizeMake(self.bounds.size.width * scale,
                           self.bounds.size.height * scale);
  if (size.width < 1 || size.height < 1)
    return;
  metalLayer.drawableSize = size;
  if (_swapChain == nullptr) {
    _swapChain = _engine->createSwapChain((__bridge void *)metalLayer);
  }
  _view->setViewport(
      Viewport(0, 0, (uint32_t)size.width, (uint32_t)size.height));
  [self updateProjection];
}

// ── the vsync tick: drain, apply between frames, render ─────────────────

- (void)renderFrame {
  if (_destroyed)
    return;

  MobScene3dDrain *drain = MobScene3dDrainTick(self.viewportId);
  if (drain.reset)
    [self clearScene];
  [self applyOps:drain.ops];
  for (NSDictionary *request in drain.sceneRequests) {
    MobScene3dDeliverScene(request[@"token"], self.viewportId,
                           request[@"request_id"], [self sceneJson]);
  }

  if (_swapChain == nullptr)
    return;
  if (_renderer->beginFrame(_swapChain)) {
    _renderer->render(_view);
    _renderer->endFrame();
    _frameCount++;
    if (!_readySent) {
      _readySent = YES;
      MobScene3dDeliverReady(self.viewportId);
    }
  }
}

// ── the applier: patch ops → Filament mutations (the mapping table) ──────

- (void)applyOps:(NSArray<NSArray *> *)ops {
  for (NSArray *op in ops) {
    @try {
      [self applyOp:op];
    } @catch (NSException *exception) {
      // Shadow-validated ops shouldn't throw; if one does, that's an
      // applier bug — surface it, never swallow it.
      NSString *error =
          [NSString stringWithFormat:@"[\"bad_patch\",\"applier: %@\"]",
                                     exception.reason ?: @"?"];
      MobScene3dDeliverError(self.viewportId, error);
      NSLog(@"[scene3d] applier failure on %@: %@", op.firstObject, exception);
    }
  }
}

- (void)applyOp:(NSArray *)op {
  NSString *name = op[0];
  if ([name isEqualToString:@"add_entity"]) {
    [self addEntity:op[1]];
  } else if ([name isEqualToString:@"replace_entity"]) {
    [self replaceEntity:op[1]];
  } else if ([name isEqualToString:@"remove_entity"]) {
    [self removeEntity:op[1]];
  } else if ([name isEqualToString:@"set_parent"]) {
    [self setEntityField:op[1] field:@"parent" value:op[2]];
    [self applyParent:op[1]];
  } else if ([name isEqualToString:@"set_transform"]) {
    [self setEntityField:op[1] field:@"transform" value:op[2]];
    [self applyLocalTransform:op[1]];
  } else if ([name isEqualToString:@"set_visible"]) {
    [self setEntityField:op[1] field:@"visible" value:op[2]];
    [self applyVisibility:op[1]];
  } else if ([name isEqualToString:@"set_pickable"]) {
    // Picking is a later bead (mob_scene3d-na8); readback reflects intent.
    [self setEntityField:op[1] field:@"pickable" value:op[2]];
  } else if ([name isEqualToString:@"set_material"]) {
    [self setMaterial:op[1] material:op[2]];
  } else if ([name isEqualToString:@"set_camera"]) {
    [self setCameraParams:op[1] camera:op[2]];
  } else if ([name isEqualToString:@"set_light"]) {
    [self setLightParams:op[1] light:op[2]];
  } else if ([name isEqualToString:@"set_environment"]) {
    [self setEnvironmentParams:op[1] environment:op[2]];
  }
}

- (S3dRec *)rec:(NSString *)entityId {
  auto it = _registry.find(std::string(entityId.UTF8String));
  return it == _registry.end() ? nullptr : &it->second;
}

- (void)setEntityField:(NSString *)entityId
                 field:(NSString *)field
                 value:(id)value {
  S3dRec *rec = [self rec:entityId];
  if (rec == nullptr)
    return;
  rec->json[field] = value ?: [NSNull null];
}

- (void)addEntity:(NSDictionary *)json {
  NSString *entityId = json[@"id"];
  S3dRec rec;
  rec.entity = utils::EntityManager::get().create();
  rec.json = [json mutableCopy];
  _engine->getTransformManager().create(rec.entity);
  _registry[std::string(entityId.UTF8String)] = rec;
  [self applyLocalTransform:entityId];
  [self applyParent:entityId];
  [self buildData:entityId];
  [self applyVisibility:entityId];
}

// Same id, structural change: kind-specific native resources destroyed and
// recreated; the transform entity persists, so children stay parented.
- (void)replaceEntity:(NSDictionary *)json {
  NSString *entityId = json[@"id"];
  S3dRec *rec = [self rec:entityId];
  if (rec == nullptr)
    return;
  [self tearDownData:rec entityId:entityId];
  rec->json = [json mutableCopy];
  rec->status = "ready";
  rec->statusDetail.clear();
  [self applyLocalTransform:entityId];
  [self applyParent:entityId];
  [self buildData:entityId];
  [self applyVisibility:entityId];
}

- (void)removeEntity:(NSString *)entityId {
  S3dRec *rec = [self rec:entityId];
  if (rec == nullptr)
    return;
  [self tearDownData:rec entityId:entityId];
  _engine->getTransformManager().destroy(rec->entity);
  _engine->destroy(rec->entity);
  utils::EntityManager::get().destroy(rec->entity);
  _registry.erase(std::string(entityId.UTF8String));
}

- (void)buildData:(NSString *)entityId {
  S3dRec *rec = [self rec:entityId];
  if (rec == nullptr)
    return;
  NSDictionary *data = rec->json[@"data"];
  if (![data isKindOfClass:[NSDictionary class]])
    return;
  NSString *kind = data[@"kind"];
  if ([kind isEqualToString:@"model"]) {
    [self buildModel:rec data:data];
  } else if ([kind isEqualToString:@"light"]) {
    [self buildLight:rec data:data];
  } else if ([kind isEqualToString:@"camera"]) {
    [self buildCamera:rec entityId:entityId];
  } else if ([kind isEqualToString:@"environment"]) {
    [self setEnvironmentParams:entityId environment:data];
  }
}

- (void)buildModel:(S3dRec *)rec data:(NSDictionary *)data {
  NSString *ref = data[@"asset"];
  S3dAssetEntry *entry = [self loadAsset:ref];
  FilamentInstance *instance = nullptr;
  if (entry != nullptr) {
    if (!entry->freeInstances.empty()) {
      instance = entry->freeInstances.front();
      entry->freeInstances.pop_front();
    } else {
      instance = _assetLoader->createInstance(entry->asset);
    }
  }
  if (instance == nullptr) {
    rec->status = "error";
    rec->statusDetail = "bad_asset";
    NSString *error = [NSString
        stringWithFormat:@"[\"bad_asset\",\"%@\",\"load_failed\"]", ref];
    MobScene3dDeliverError(self.viewportId, error);
    return;
  }
  rec->instance = instance;
  rec->assetRef = std::string(ref.UTF8String);
  rec->overridden = false;
  TransformManager &tm = _engine->getTransformManager();
  tm.setParent(tm.getInstance(instance->getRoot()),
               tm.getInstance(rec->entity));
  NSDictionary *material = data[@"material"];
  if ([material isKindOfClass:[NSDictionary class]])
    [self applyMaterial:rec material:material];
}

- (void)buildLight:(S3dRec *)rec data:(NSDictionary *)data {
  NSString *typeName = data[@"type"];
  LightManager::Type type = LightManager::Type::DIRECTIONAL;
  if ([typeName isEqualToString:@"point"])
    type = LightManager::Type::POINT;
  if ([typeName isEqualToString:@"spot"])
    type = LightManager::Type::SPOT;

  LightManager::Builder builder(type);
  builder.intensity((float)jnum(data[@"intensity"], 0.0));
  builder.castShadows([data[@"cast_shadows"] boolValue]);
  // Lights shine down local -Z (the IR convention); the entity's transform
  // orients them.
  builder.direction(float3{0.0f, 0.0f, -1.0f});
  NSArray *color = data[@"color"];
  if ([color isKindOfClass:[NSArray class]] && color.count == 3) {
    builder.color(float3{(float)jnum(color[0], 1), (float)jnum(color[1], 1),
                         (float)jnum(color[2], 1)});
  }
  if (!jnull(data[@"falloff"]))
    builder.falloff((float)jnum(data[@"falloff"], 1.0));
  if (!jnull(data[@"spot_inner"]) && !jnull(data[@"spot_outer"])) {
    builder.spotLightCone((float)(jnum(data[@"spot_inner"], 0) * M_PI / 180.0),
                          (float)(jnum(data[@"spot_outer"], 0) * M_PI / 180.0));
  }
  builder.build(*_engine, rec->entity);
  rec->hasLight = true;
}

- (void)buildCamera:(S3dRec *)rec entityId:(NSString *)entityId {
  Camera *camera = _engine->createCamera(rec->entity);
  camera->setExposure(16.0f, 1 / 125.0f, 100.0f);
  rec->camera = camera;
  _irCameraId = std::string(entityId.UTF8String);
  _view->setCamera(camera);
  [self updateProjection];
}

- (void)tearDownData:(S3dRec *)rec entityId:(NSString *)entityId {
  if (rec->instance != nullptr) {
    if (rec->inScene) {
      _scene->removeEntities(rec->instance->getEntities(),
                             rec->instance->getEntityCount());
    }
    rec->inScene = false;
    TransformManager &tm = _engine->getTransformManager();
    tm.setParent(tm.getInstance(rec->instance->getRoot()),
                 TransformManager::Instance{});
    // gltfio has no per-instance destroy; un-overridden instances are
    // reused, overridden ones are abandoned until asset teardown (their
    // asset-authored factors are unrecoverable).
    if (!rec->overridden) {
      auto it = _assets.find(rec->assetRef);
      if (it != _assets.end())
        it->second.freeInstances.push_back(rec->instance);
    }
    rec->instance = nullptr;
    rec->assetRef.clear();
  }
  if (rec->hasLight) {
    _scene->remove(rec->entity);
    _engine->getLightManager().destroy(rec->entity);
    rec->hasLight = false;
    rec->inScene = false;
  }
  if (rec->camera != nullptr) {
    _engine->destroyCameraComponent(rec->entity);
    rec->camera = nullptr;
    if (_irCameraId == std::string(entityId.UTF8String)) {
      _irCameraId.clear();
      _view->setCamera(_fallbackCamera);
      [self updateProjection];
    }
  }
}

- (void)setMaterial:(NSString *)entityId material:(id)material {
  S3dRec *rec = [self rec:entityId];
  if (rec == nullptr)
    return;
  NSMutableDictionary *data =
      [((NSDictionary *)rec->json[@"data"]) mutableCopy];
  data[@"material"] = material ?: [NSNull null];
  rec->json[@"data"] = data;
  if ([material isKindOfClass:[NSDictionary class]]) {
    [self applyMaterial:rec material:material];
  } else {
    // Clearing an override restores asset-authored factors: recreate the
    // instance from the shared asset (no readback exists for the originals).
    [self rebuildModelInstance:rec entityId:entityId];
  }
}

- (void)applyMaterial:(S3dRec *)rec material:(NSDictionary *)material {
  if (rec->instance == nullptr)
    return;
  rec->overridden = true;
  MaterialInstance *const *instances = rec->instance->getMaterialInstances();
  size_t count = rec->instance->getMaterialInstanceCount();
  for (size_t i = 0; i < count; i++) {
    MaterialInstance *mi = instances[i];
    NSArray *baseColor = material[@"base_color"];
    if ([baseColor isKindOfClass:[NSArray class]] &&
        mi->getMaterial()->hasParameter("baseColorFactor")) {
      mi->setParameter("baseColorFactor", float4{(float)jnum(baseColor[0], 1),
                                                 (float)jnum(baseColor[1], 1),
                                                 (float)jnum(baseColor[2], 1),
                                                 (float)jnum(baseColor[3], 1)});
    }
    if (!jnull(material[@"metallic"]) &&
        mi->getMaterial()->hasParameter("metallicFactor")) {
      mi->setParameter("metallicFactor", (float)jnum(material[@"metallic"], 0));
    }
    if (!jnull(material[@"roughness"]) &&
        mi->getMaterial()->hasParameter("roughnessFactor")) {
      mi->setParameter("roughnessFactor",
                       (float)jnum(material[@"roughness"], 1));
    }
    NSArray *emissive = material[@"emissive"];
    if ([emissive isKindOfClass:[NSArray class]] &&
        mi->getMaterial()->hasParameter("emissiveFactor")) {
      // float3, matching what gltfio's own asset loading sets (and the
      // Kotlin twin's 3-float overload).
      mi->setParameter("emissiveFactor", float3{(float)jnum(emissive[0], 0),
                                                (float)jnum(emissive[1], 0),
                                                (float)jnum(emissive[2], 0)});
    }
  }
}

- (void)rebuildModelInstance:(S3dRec *)rec entityId:(NSString *)entityId {
  NSDictionary *data = rec->json[@"data"];
  if (![data isKindOfClass:[NSDictionary class]])
    return;
  if (rec->instance != nullptr) {
    if (rec->inScene) {
      _scene->removeEntities(rec->instance->getEntities(),
                             rec->instance->getEntityCount());
    }
    rec->inScene = false;
    TransformManager &tm = _engine->getTransformManager();
    tm.setParent(tm.getInstance(rec->instance->getRoot()),
                 TransformManager::Instance{});
    rec->instance = nullptr; // overridden by definition — abandoned
    rec->assetRef.clear();
  }
  [self buildModel:rec data:data];
  [self applyVisibility:entityId];
}

- (void)setCameraParams:(NSString *)entityId camera:(NSDictionary *)camera {
  S3dRec *rec = [self rec:entityId];
  if (rec == nullptr)
    return;
  NSMutableDictionary *tagged = [camera mutableCopy];
  tagged[@"kind"] = @"camera";
  rec->json[@"data"] = tagged;
  [self updateProjection];
}

- (void)setLightParams:(NSString *)entityId light:(NSDictionary *)light {
  S3dRec *rec = [self rec:entityId];
  if (rec == nullptr)
    return;
  NSMutableDictionary *tagged = [light mutableCopy];
  tagged[@"kind"] = @"light";
  rec->json[@"data"] = tagged;
  LightManager &lm = _engine->getLightManager();
  auto li = lm.getInstance(rec->entity);
  if (!li)
    return;
  lm.setIntensity(li, (float)jnum(light[@"intensity"], 0.0));
  NSArray *color = light[@"color"];
  if ([color isKindOfClass:[NSArray class]] && color.count == 3) {
    lm.setColor(li, float3{(float)jnum(color[0], 1), (float)jnum(color[1], 1),
                           (float)jnum(color[2], 1)});
  }
  lm.setShadowCaster(li, [light[@"cast_shadows"] boolValue]);
  if (!jnull(light[@"falloff"]))
    lm.setFalloff(li, (float)jnum(light[@"falloff"], 1.0));
  if (!jnull(light[@"spot_inner"]) && !jnull(light[@"spot_outer"])) {
    lm.setSpotLightCone(li,
                        (float)(jnum(light[@"spot_inner"], 0) * M_PI / 180.0),
                        (float)(jnum(light[@"spot_outer"], 0) * M_PI / 180.0));
  }
}

- (void)setEnvironmentParams:(NSString *)entityId
                 environment:(NSDictionary *)environment {
  S3dRec *rec = [self rec:entityId];
  if (rec == nullptr)
    return;
  NSMutableDictionary *tagged = [environment mutableCopy];
  tagged[@"kind"] = @"environment";
  rec->json[@"data"] = tagged;
  // IBL/skybox KTX loading is the asset-pipeline bead (mob_scene3d-392).
  // Accepted and recorded for readback; loudly logged, never silent.
  NSLog(
      @"[scene3d] environment accepted but IBL/skybox loading is not wired yet "
      @"(bead mob_scene3d-392): %@",
      environment[@"ibl"]);
}

// ── per-frame state pokes ────────────────────────────────────────────────

- (void)applyParent:(NSString *)entityId {
  S3dRec *rec = [self rec:entityId];
  if (rec == nullptr)
    return;
  TransformManager &tm = _engine->getTransformManager();
  TransformManager::Instance parentInstance{};
  id parent = rec->json[@"parent"];
  if ([parent isKindOfClass:[NSString class]]) {
    S3dRec *parentRec = [self rec:parent];
    if (parentRec != nullptr)
      parentInstance = tm.getInstance(parentRec->entity);
  }
  tm.setParent(tm.getInstance(rec->entity), parentInstance);
}

- (void)applyLocalTransform:(NSString *)entityId {
  S3dRec *rec = [self rec:entityId];
  if (rec == nullptr)
    return;
  NSDictionary *t = rec->json[@"transform"];
  if (![t isKindOfClass:[NSDictionary class]])
    return;
  NSArray *p = t[@"position"], *q = t[@"rotation"], *s = t[@"scale"];
  double qx = jnum(q[0], 0), qy = jnum(q[1], 0), qz = jnum(q[2], 0),
         qw = jnum(q[3], 1);
  double norm = std::sqrt(qx * qx + qy * qy + qz * qz + qw * qw);
  quatf rotation = norm > 1e-9 ? quatf{(float)(qw / norm), (float)(qx / norm),
                                       (float)(qy / norm), (float)(qz / norm)}
                               : quatf{1, 0, 0, 0};
  mat4f matrix =
      mat4f::translation(float3{(float)jnum(p[0], 0), (float)jnum(p[1], 0),
                                (float)jnum(p[2], 0)}) *
      mat4f(rotation) *
      mat4f::scaling(float3{(float)jnum(s[0], 1), (float)jnum(s[1], 1),
                            (float)jnum(s[2], 1)});
  TransformManager &tm = _engine->getTransformManager();
  tm.setTransform(tm.getInstance(rec->entity), matrix);
}

- (void)applyVisibility:(NSString *)entityId {
  S3dRec *rec = [self rec:entityId];
  if (rec == nullptr)
    return;
  id visibleValue = rec->json[@"visible"];
  bool visible = jnull(visibleValue) ? true : [visibleValue boolValue];
  if (visible == rec->inScene)
    return;
  if (rec->instance != nullptr) {
    if (visible) {
      _scene->addEntities(rec->instance->getEntities(),
                          rec->instance->getEntityCount());
    } else {
      _scene->removeEntities(rec->instance->getEntities(),
                             rec->instance->getEntityCount());
    }
  }
  if (rec->hasLight) {
    if (visible) {
      _scene->addEntity(rec->entity);
    } else {
      _scene->remove(rec->entity);
    }
  }
  rec->inScene = visible && (rec->instance != nullptr || rec->hasLight);
}

- (void)updateProjection {
  const Viewport &vp = _view->getViewport();
  if (vp.width == 0 || vp.height == 0)
    return;
  double aspect = (double)vp.width / (double)vp.height;
  double fov = 35.0, near = 0.05, far = 100.0;
  if (!_irCameraId.empty()) {
    auto it = _registry.find(_irCameraId);
    if (it != _registry.end()) {
      NSDictionary *data = it->second.json[@"data"];
      fov = jnum(data[@"fov_y"], 45.0);
      near = jnum(data[@"near"], 0.1);
      far = jnum(data[@"far"], 100.0);
    }
  }
  Camera *camera = _irCameraId.empty() ? _fallbackCamera : nullptr;
  if (camera == nullptr) {
    auto it = _registry.find(_irCameraId);
    camera = it != _registry.end() && it->second.camera ? it->second.camera
                                                        : _fallbackCamera;
  }
  camera->setProjection(fov, aspect, near, far, Camera::Fov::VERTICAL);
}

- (S3dAssetEntry *)loadAsset:(NSString *)path {
  std::string key(path.UTF8String);
  auto it = _assets.find(key);
  if (it != _assets.end())
    return &it->second;
  NSData *data = [NSData dataWithContentsOfFile:path];
  if (data == nil)
    return nullptr;
  // Instanced creation, source data retained: both are what makes
  // createInstance work for later entities sharing this ref.
  FilamentInstance *first = nullptr;
  FilamentAsset *asset = _assetLoader->createInstancedAsset(
      static_cast<const uint8_t *>(data.bytes), (uint32_t)data.length, &first,
      1);
  if (asset == nullptr)
    return nullptr;
  _resourceLoader->loadResources(asset);
  S3dAssetEntry entry;
  entry.asset = asset;
  if (first != nullptr)
    entry.freeInstances.push_back(first);
  auto [inserted, _] = _assets.emplace(key, entry);
  return &inserted->second;
}

// ── readback: the applied scene, from the applier's own registry ─────────

- (NSString *)sceneJson {
  NSMutableDictionary *entities = [NSMutableDictionary dictionary];
  TransformManager &tm = _engine->getTransformManager();
  for (auto &pair : _registry) {
    S3dRec &rec = pair.second;
    NSMutableDictionary *entity = [rec.json mutableCopy];
    entity[@"kind"] = kindOf(rec.json);
    const mat4f world = tm.getWorldTransform(tm.getInstance(rec.entity));
    NSMutableArray *worldArr = [NSMutableArray arrayWithCapacity:16];
    const float *m = world.asArray();
    for (int i = 0; i < 16; i++)
      [worldArr addObject:@(m[i])];
    entity[@"world_transform"] = worldArr;
    entity[@"status"] = @(rec.status.c_str());
    if (!rec.statusDetail.empty())
      entity[@"status_detail"] = @(rec.statusDetail.c_str());
    entities[@(pair.first.c_str())] = entity;
  }
  NSData *json =
      [NSJSONSerialization dataWithJSONObject:@{@"entities" : entities}
                                      options:0
                                        error:nil];
  return [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
}

- (void)clearScene {
  std::vector<std::string> ids;
  for (auto &pair : _registry)
    ids.push_back(pair.first);
  for (auto it = ids.rbegin(); it != ids.rend(); ++it) {
    [self removeEntity:@(it->c_str())];
  }
  _irCameraId.clear();
  _view->setCamera(_fallbackCamera);
}

// ── teardown ─────────────────────────────────────────────────────────────

- (void)dealloc {
  [[NSNotificationCenter defaultCenter] removeObserver:self];
  [_displayLink invalidate];
  if (_engine == nullptr)
    return;
  _destroyed = YES;
  [self clearScene];
  for (auto &pair : _assets) {
    _assetLoader->destroyAsset(pair.second.asset);
  }
  _assets.clear();
  AssetLoader::destroy(&_assetLoader);
  _materials->destroyMaterials();
  delete _materials;
  delete _resourceLoader;
  _engine->destroy(_skybox);
  _engine->destroyCameraComponent(_fallbackCameraEntity);
  utils::EntityManager::get().destroy(_fallbackCameraEntity);
  _engine->destroy(_view);
  _engine->destroy(_scene);
  _engine->destroy(_renderer);
  if (_swapChain != nullptr)
    _engine->destroy(_swapChain);
  Engine::destroy(&_engine);
  _engine = nullptr;
}

@end
