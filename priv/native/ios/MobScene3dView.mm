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

#include <gltfio/Animator.h>
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
#include <utils/NameComponentManager.h>

#include <backend/PixelBufferDescriptor.h>

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <map>
#include <optional>
#include <string>
#include <vector>

using namespace filament;
using namespace filament::math;
using namespace filament::gltfio;

namespace {

// The render-thread clip clock for one model's declarative animation state.
// The Animator itself is NOT held here — it belongs to the gltfio instance
// and is looked up per frame, so a material-clear instance rebuild keeps the
// clock without holding a stale pointer.
struct S3dAnimState {
  std::string name;
  std::string playId;
  int index = -1; // -1 = unknown clip (error state, readback-visible)
  double duration = 0.0;
  double clock = 0.0;
  bool loop = false;
  double speed = 1.0;
  bool paused = false;
  bool hasSeek = false;
  double lastSeek = 0.0;
  bool done = false;
  bool doneDelivered = false;
  double appliedTime = 0.0;
};

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
  std::optional<S3dAnimState> anim;
  // Applied material-override truth for scene/1 readback: one entry per
  // override (scope, applied params, matched instance names, or an
  // unknown_material error marker). Nil = no override applied.
  NSArray *materialState = nil;
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

/// Normalize a wire material override — a single object (scope nil = every
/// instance, the pre-scope wire shape) or an array of scoped overrides — to
/// an array of override dictionaries. Anything else is "no override".
NSArray<NSDictionary *> *s3dOverrides(id material) {
  if ([material isKindOfClass:[NSDictionary class]])
    return @[ material ];
  if ([material isKindOfClass:[NSArray class]]) {
    NSMutableArray *overrides = [NSMutableArray array];
    for (id entry in (NSArray *)material) {
      if ([entry isKindOfClass:[NSDictionary class]])
        [overrides addObject:entry];
    }
    return overrides;
  }
  return @[];
}

/// The scope of one override entry: a glTF material name, or nil = all.
NSString *s3dScopeOf(NSDictionary *override) {
  id scope = override[@"scope"];
  return [scope isKindOfClass:[NSString class]] ? scope : nil;
}

/// The parameter names one override entry actually sets.
NSArray<NSString *> *s3dParamNames(NSDictionary *override) {
  NSMutableArray *params = [NSMutableArray array];
  for (NSString *key in
       @[ @"base_color", @"metallic", @"roughness", @"emissive" ]) {
    if (!jnull(override[key]))
      [params addObject:key];
  }
  return params;
}

/// True when the new override keeps every previously overridden
/// (scope, parameter) pair set — the condition for in-place application;
/// anything vacated must return to asset-authored values, which only a
/// fresh instance has. Conservative: matches entries by identical scope.
bool s3dCovers(NSArray<NSDictionary *> *old,
               NSArray<NSDictionary *> *replacementOverrides) {
  for (NSDictionary *previous in old) {
    NSString *scope = s3dScopeOf(previous);
    NSDictionary *replacement = nil;
    for (NSDictionary *candidate in replacementOverrides) {
      NSString *candidateScope = s3dScopeOf(candidate);
      bool sameScope = (scope == nil && candidateScope == nil) ||
                       (scope != nil && candidateScope != nil &&
                        [scope isEqualToString:candidateScope]);
      if (sameScope) {
        replacement = candidate;
        break;
      }
    }
    if (replacement == nil)
      return false;
    NSArray<NSString *> *replacementParams = s3dParamNames(replacement);
    for (NSString *param in s3dParamNames(previous)) {
      if (![replacementParams containsObject:param])
        return false;
    }
  }
  return true;
}

/// A JSON string literal (quotes included) for embedding in a reply.
NSString *s3d_json_string(NSString *value) {
  NSData *data = [NSJSONSerialization dataWithJSONObject:@[ value ]
                                                 options:0
                                                   error:nil];
  NSString *array = [[NSString alloc] initWithData:data
                                          encoding:NSUTF8StringEncoding];
  return [array substringWithRange:NSMakeRange(1, array.length - 2)];
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
  utils::NameComponentManager *_names;

  std::map<std::string, S3dRec> _registry;
  std::map<std::string, S3dAssetEntry> _assets;
  std::string _irCameraId;

  NSUInteger _frameCount;
  BOOL _readySent;
  BOOL _destroyed;

  // Sample queries wait for a frame we actually render: readPixels must sit
  // between render() and endFrame() to read the swap chain.
  NSMutableArray<NSDictionary *> *_pendingSamples;

  // Frame timing ring buffer — one delta per CADisplayLink tick, cheap by
  // construction. 120 entries ≈ the last two seconds at 60 Hz.
  double _frameDeltasMs[120];
  int _frameDeltaCount;
  int _frameDeltaIndex;
  CFTimeInterval _lastFrameTimestamp;
  NSUInteger _framesSinceQuery;
  NSUInteger _droppedSinceQuery;

  // Animation clock: one dt per CADisplayLink tick, shared by every playing
  // clip (main thread only).
  CFTimeInterval _lastAnimTimestamp;
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
    _pendingSamples = [NSMutableArray array];
    self.contentScaleFactor = UIScreen.mainScreen.scale;
    // Tap capture: a single tap inside the viewport rides the same native
    // pick path pick/3 uses. Hits on pickable models become pick events;
    // misses are silence (the decision record's honest-miss ruling).
    UITapGestureRecognizer *tap =
        [[UITapGestureRecognizer alloc] initWithTarget:self
                                                action:@selector(handleTap:)];
    [self addGestureRecognizer:tap];
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
  // Name components make FilamentAsset::getName answer for instance node
  // entities — the readback's named-node world transforms (and therefore
  // the Chopaat slot-orientation contract) depend on it. The Android AAR
  // wires one implicitly; here it is explicit.
  _names = new utils::NameComponentManager(utils::EntityManager::get());
  AssetConfiguration config;
  config.engine = _engine;
  config.materials = _materials;
  config.names = _names;
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
  [self recordFrameDelta];

  MobScene3dDrain *drain = MobScene3dDrainTick(self.viewportId);
  if (drain.reset)
    [self clearScene];
  [self applyOps:drain.ops];
  [self advanceAnimations];
  for (NSDictionary *request in drain.sceneRequests) {
    MobScene3dDeliverScene(request[@"token"], self.viewportId,
                           request[@"request_id"], [self sceneJson]);
  }
  for (NSDictionary *query in drain.queries) {
    NSString *kind = query[@"kind"];
    if ([kind isEqualToString:@"pick"]) {
      NSDictionary *params = query[@"params"];
      CGFloat scale = self.contentScaleFactor;
      [self pickAtPixelX:jnum(params[@"x"], 0.0) * scale
                       y:jnum(params[@"y"], 0.0) * scale
                   query:query];
    } else if ([kind isEqualToString:@"sample"]) {
      [_pendingSamples addObject:query];
    } else if ([kind isEqualToString:@"stats"]) {
      [self deliverFrameStats:query];
    }
  }

  if (_swapChain == nullptr)
    return;
  if (_renderer->beginFrame(_swapChain)) {
    _renderer->render(_view);
    // GPU readback rides between render() and endFrame(): that is the
    // window where the swap chain is readable. Window capture cannot see
    // this surface at all (the SurfaceView/CAMetalLayer blindspot) — this
    // IS the pixel-truth path.
    for (NSDictionary *query in _pendingSamples)
      [self readbackSample:query];
    [_pendingSamples removeAllObjects];
    _renderer->endFrame();
    _frameCount++;
    _framesSinceQuery++;
    if (!_readySent) {
      _readySent = YES;
      MobScene3dDeliverReady(self.viewportId);
    }
  }
}

// ── input: tap → ray pick → {tag, entity} event (bead na8) ────────────────

- (void)handleTap:(UITapGestureRecognizer *)recognizer {
  if (recognizer.state != UIGestureRecognizerStateEnded)
    return;
  CGPoint point = [recognizer locationInView:self];
  CGFloat scale = self.contentScaleFactor;
  [self pickAtPixelX:point.x * scale y:point.y * scale query:nil];
}

/// Ray-pick at viewport pixel coords. `query == nil` is the touch path
/// (hit → pick event to the owner; miss → silence). A query gets an
/// explicit reply either way. Filament picks async on the GPU; the callback
/// fires a frame or two later on Filament's dispatch — it touches only the
/// captured snapshot and enif_send (thread-safe), never Filament state.
- (void)pickAtPixelX:(double)xPx y:(double)yPx query:(NSDictionary *)query {
  const Viewport &vp = _view->getViewport();
  // Filament pick coords: viewport pixels, origin bottom-left.
  uint32_t px = (uint32_t)std::max(0.0, std::round(xPx));
  uint32_t flippedY = 0;
  double fromBottom = (double)vp.height - std::round(yPx);
  if (fromBottom > 0)
    flippedY = (uint32_t)fromBottom;

  // Snapshot of pickable renderables → IR ids, resolved in the callback.
  NSMutableDictionary<NSNumber *, NSString *> *pickables =
      [NSMutableDictionary dictionary];
  for (auto &pair : _registry) {
    S3dRec &rec = pair.second;
    if (rec.instance == nullptr)
      continue;
    id pickable = rec.json[@"pickable"];
    if (jnull(pickable) || ![pickable boolValue])
      continue;
    const utils::Entity *entities = rec.instance->getEntities();
    size_t count = rec.instance->getEntityCount();
    NSString *irId = @(pair.first.c_str());
    for (size_t i = 0; i < count; i++) {
      pickables[@(entities[i].getId())] = irId;
    }
  }

  NSString *viewportId = self.viewportId;
  NSData *token = query ? query[@"token"] : nil;
  NSString *requestId = query ? query[@"request_id"] : nil;
  _view->pick(
      px, flippedY,
      [pickables, viewportId, token,
       requestId](filament::View::PickingQueryResult const &result) {
        NSString *entityId = pickables[@(result.renderable.getId())];
        if (token != nil) {
          NSString *reply =
              entityId != nil
                  ? [NSString stringWithFormat:@"{\"entity\":%@}",
                                               s3d_json_string(entityId)]
                  : @"{\"miss\":true}";
          MobScene3dDeliverReply(@"pick", token, viewportId, requestId, reply);
        } else if (entityId != nil) {
          MobScene3dDeliverPickEvent(viewportId, entityId);
        }
      });
}

// ── pixel truth: Filament readPixels over a viewport-local pt rect ────────

struct S3dSampleCtx {
  const void *token;     // NSData, CFBridgingRetained
  const void *viewport;  // NSString
  const void *requestId; // NSString
  int width;
  int height;
};

static void s3d_sample_done(void *buffer, size_t size, void *user) {
  S3dSampleCtx *ctx = (S3dSampleCtx *)user;
  NSData *token = CFBridgingRelease(ctx->token);
  NSString *viewportId = CFBridgingRelease(ctx->viewport);
  NSString *requestId = CFBridgingRelease(ctx->requestId);
  // The swap chain's alpha channel is not part of the composited output
  // (the layer is opaque) — report the pixels as displayed: opaque. Keeps
  // 0xAARRGGBB comparisons against Mob.Test's sampler sane.
  uint8_t *bytes = (uint8_t *)buffer;
  for (size_t i = 3; i < size; i += 4)
    bytes[i] = 0xFF;
  NSData *rgba = [NSData dataWithBytesNoCopy:buffer
                                      length:size
                                freeWhenDone:NO];
  NSString *reply = [NSString
      stringWithFormat:@"{\"width\":%d,\"height\":%d,\"rgba\":\"%@\"}",
                       ctx->width, ctx->height,
                       [rgba base64EncodedStringWithOptions:0]];
  MobScene3dDeliverReply(@"sample", token, viewportId, requestId, reply);
  free(buffer);
  delete ctx;
}

- (void)readbackSample:(NSDictionary *)query {
  NSDictionary *params = query[@"params"];
  const Viewport &vp = _view->getViewport();
  CGFloat scale = self.contentScaleFactor;
  // pt rect → device pixels, clamped to the viewport.
  double x = jnum(params[@"x"], 0.0) * scale;
  double y = jnum(params[@"y"], 0.0) * scale;
  double w = jnum(params[@"w"], 0.0) * scale;
  double h = jnum(params[@"h"], 0.0) * scale;
  int32_t x0 = (int32_t)std::clamp(std::round(x), 0.0, (double)vp.width);
  int32_t y0 = (int32_t)std::clamp(std::round(y), 0.0, (double)vp.height);
  int32_t x1 = (int32_t)std::clamp(std::round(x + w), 0.0, (double)vp.width);
  int32_t y1 = (int32_t)std::clamp(std::round(y + h), 0.0, (double)vp.height);
  int32_t width = x1 - x0;
  int32_t height = y1 - y0;
  if (width <= 0 || height <= 0) {
    MobScene3dDeliverReply(@"sample", query[@"token"], self.viewportId,
                           query[@"request_id"],
                           @"{\"error\":[\"offscreen\"]}");
    return;
  }

  // readPixels origin is bottom-left (GL convention); rows arrive
  // bottom-to-top, which the order-invariant stats reduction ignores.
  uint32_t glY = vp.height - (uint32_t)(y0 + height);
  size_t bufferSize = (size_t)width * (size_t)height * 4;
  void *buffer = malloc(bufferSize);
  if (buffer == nullptr) {
    MobScene3dDeliverReply(@"sample", query[@"token"], self.viewportId,
                           query[@"request_id"],
                           @"{\"error\":[\"empty_region\"]}");
    return;
  }
  S3dSampleCtx *ctx = new S3dSampleCtx{
      CFBridgingRetain(query[@"token"]), CFBridgingRetain(self.viewportId),
      CFBridgingRetain(query[@"request_id"]), width, height};
  backend::PixelBufferDescriptor descriptor(
      buffer, bufferSize, backend::PixelDataFormat::RGBA,
      backend::PixelDataType::UBYTE, s3d_sample_done, ctx);
  _renderer->readPixels((uint32_t)x0, glY, (uint32_t)width, (uint32_t)height,
                        std::move(descriptor));
}

// ── perf readback: ring buffer of vsync deltas (bead 0n7 scope note) ──────

- (void)recordFrameDelta {
  CFTimeInterval now = self.displayLink.timestamp;
  if (_lastFrameTimestamp > 0) {
    double deltaMs = (now - _lastFrameTimestamp) * 1000.0;
    _frameDeltasMs[_frameDeltaIndex] = deltaMs;
    _frameDeltaIndex = (_frameDeltaIndex + 1) % 120;
    if (_frameDeltaCount < 120)
      _frameDeltaCount++;
    double periodMs = self.displayLink.duration > 0
                          ? self.displayLink.duration * 1000.0
                          : 1000.0 / 60.0;
    if (deltaMs > 1.5 * periodMs)
      _droppedSinceQuery++;
  }
  _lastFrameTimestamp = now;
}

- (void)deliverFrameStats:(NSDictionary *)query {
  std::vector<double> window(_frameDeltasMs, _frameDeltasMs + _frameDeltaCount);
  std::sort(window.begin(), window.end());
  double avg = 0.0;
  double p95 = 0.0;
  if (!window.empty()) {
    for (double delta : window)
      avg += delta;
    avg /= (double)window.size();
    size_t index = ((window.size() - 1) * 95 + 99) / 100;
    p95 = window[std::min(index, window.size() - 1)];
  }
  size_t renderables = _scene->getRenderableCount();
  NSString *reply = [NSString
      stringWithFormat:@"{\"frames\":%lu,\"avg_ms\":%.3f,\"p95_ms\":%.3f,"
                       @"\"dropped\":%lu,\"entities\":%zu,\"renderables\":%zu}",
                       (unsigned long)_framesSinceQuery, avg, p95,
                       (unsigned long)_droppedSinceQuery, _registry.size(),
                       renderables];
  _framesSinceQuery = 0;
  _droppedSinceQuery = 0;
  MobScene3dDeliverReply(@"stats", query[@"token"], self.viewportId,
                         query[@"request_id"], reply);
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
    // The registry json is what pick resolution snapshots (pickAtPixelX),
    // so flipping the flag takes effect on the next tap/pick.
    [self setEntityField:op[1] field:@"pickable" value:op[2]];
  } else if ([name isEqualToString:@"set_material"]) {
    [self setMaterial:op[1] material:op[2]];
  } else if ([name isEqualToString:@"set_animation"]) {
    [self setAnimation:op[1] animation:op[2]];
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
  rec->materialState = nil;
  TransformManager &tm = _engine->getTransformManager();
  tm.setParent(tm.getInstance(instance->getRoot()),
               tm.getInstance(rec->entity));
  id material = data[@"material"];
  if (!jnull(material))
    [self applyMaterial:rec material:material];
  // Reconcile the declared animation with the (possibly fresh) instance:
  // same play_id keeps its clock across a material-clear rebuild; a new
  // entity starts from seek ?: 0.
  NSDictionary *animation = data[@"animation"];
  [self applyAnimationState:rec
                   entityId:rec->json[@"id"]
                  animation:[animation isKindOfClass:[NSDictionary class]]
                                ? animation
                                : nil];
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
  // Structural teardown (replace/remove): the clip identity dies with the
  // data payload; a replacement entity re-resolves from its json.
  rec->anim.reset();
  rec->materialState = nil;
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
  NSDictionary *currentData = rec->json[@"data"];
  id previous = [currentData isKindOfClass:[NSDictionary class]]
                    ? currentData[@"material"]
                    : nil;
  NSMutableDictionary *data = [currentData mutableCopy];
  data[@"material"] = material ?: [NSNull null];
  rec->json[@"data"] = data;
  NSArray<NSDictionary *> *next = s3dOverrides(material);
  if (next.count == 0) {
    // Clearing an override restores asset-authored factors: recreate the
    // instance from the shared asset (no readback exists for the originals).
    [self rebuildModelInstance:rec entityId:entityId];
  } else if (rec->overridden && !s3dCovers(s3dOverrides(previous), next)) {
    // Whole-value replace semantics: a (scope, parameter) pair the new
    // override no longer touches must return to its asset-authored value,
    // and only a fresh instance has those — rebuild, then buildModel
    // re-applies the stored new override.
    [self rebuildModelInstance:rec entityId:entityId];
  } else {
    [self applyMaterial:rec material:material];
  }
}

// Apply an override (single object or array of scoped overrides) to the
// instance's material instances. scope == nil hits every instance (the
// pre-scope behaviour); a named scope hits only instances whose glTF
// material name matches (gltfio carries the authored name onto each
// MaterialInstance). A named scope matching nothing is the async half of
// the unknown_material honesty: an error event to the owner AND an error
// marker in the readback — never a silently unstyled model.
- (void)applyMaterial:(S3dRec *)rec material:(id)material {
  if (rec->instance == nullptr)
    return;
  NSString *entityId = rec->json[@"id"];
  MaterialInstance *const *instances = rec->instance->getMaterialInstances();
  size_t count = rec->instance->getMaterialInstanceCount();
  NSMutableArray *state = [NSMutableArray array];
  for (NSDictionary *override in s3dOverrides(material)) {
    NSString *scope = s3dScopeOf(override);
    std::vector<MaterialInstance *> targets;
    for (size_t i = 0; i < count; i++) {
      MaterialInstance *mi = instances[i];
      const char *name = mi->getName();
      if (scope == nil ||
          (name != nullptr && strcmp(name, scope.UTF8String) == 0)) {
        targets.push_back(mi);
      }
    }
    NSMutableDictionary *entry = [NSMutableDictionary dictionary];
    entry[@"scope"] = scope ?: [NSNull null];
    if (scope != nil && targets.empty()) {
      entry[@"error"] = @"unknown_material";
      [state addObject:entry];
      NSString *error = [NSString
          stringWithFormat:@"[\"unknown_material\",%@,%@]",
                           s3d_json_string(entityId), s3d_json_string(scope)];
      MobScene3dDeliverError(self.viewportId, error);
      continue;
    }
    rec->overridden = true;
    for (MaterialInstance *mi : targets)
      [self applyOverrideParams:mi material:override];
    entry[@"applied"] = s3dParamNames(override);
    NSMutableArray *names = [NSMutableArray array];
    for (MaterialInstance *mi : targets) {
      const char *name = mi->getName();
      [names addObject:name != nullptr ? @(name) : @""];
    }
    entry[@"instances"] = names;
    [state addObject:entry];
  }
  rec->materialState = state;
}

- (void)applyOverrideParams:(MaterialInstance *)mi
                   material:(NSDictionary *)material {
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
    mi->setParameter("roughnessFactor", (float)jnum(material[@"roughness"], 1));
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

- (void)setAnimation:(NSString *)entityId animation:(id)animation {
  S3dRec *rec = [self rec:entityId];
  if (rec == nullptr)
    return;
  NSMutableDictionary *data =
      [((NSDictionary *)rec->json[@"data"]) mutableCopy];
  data[@"animation"] = animation ?: [NSNull null];
  rec->json[@"data"] = data;
  [self applyAnimationState:rec
                   entityId:entityId
                  animation:[animation isKindOfClass:[NSDictionary class]]
                                ? animation
                                : nil];
}

/// Reconcile the declarative animation intent with the render-thread clip
/// clock. Replay = a play_id change (restart from seek ?: 0); same play_id =
/// in-place field updates, a changed non-null seek repositions the clock
/// without restarting (the decision record's seek semantics).
- (void)applyAnimationState:(S3dRec *)rec
                   entityId:(NSString *)entityId
                  animation:(NSDictionary *)animation {
  if (animation == nil) {
    // Declaratively "no animation": stop driving the clip; the pose stays
    // where the clock left it (resources untouched).
    rec->anim.reset();
    return;
  }
  Animator *animator =
      rec->instance != nullptr ? rec->instance->getAnimator() : nullptr;
  if (animator == nullptr) {
    // No instance = bad_asset already reported; nothing to drive.
    rec->anim.reset();
    return;
  }
  NSString *name = animation[@"name"];
  NSString *playId = animation[@"play_id"];
  if (![name isKindOfClass:[NSString class]] ||
      ![playId isKindOfClass:[NSString class]]) {
    rec->anim.reset(); // shadow-validated shape; a raw-op side door isn't
    return;
  }
  std::string nameStr(name.UTF8String);
  std::string playStr(playId.UTF8String);
  int index = -1;
  for (size_t i = 0; i < animator->getAnimationCount(); i++) {
    if (nameStr == animator->getAnimationName(i)) {
      index = (int)i;
      break;
    }
  }
  if (index < 0) {
    // Unknown clip that raced the shadow's name registry: honest and loud —
    // an error event to the owner AND an error-shaped animation_state in
    // the readback. Never a silently idle model.
    S3dAnimState errorState;
    errorState.name = nameStr;
    errorState.playId = playStr;
    rec->anim = errorState;
    NSString *error = [NSString
        stringWithFormat:@"[\"unknown_animation\",%@,%@]",
                         s3d_json_string(entityId), s3d_json_string(name)];
    MobScene3dDeliverError(self.viewportId, error);
    return;
  }
  bool hasSeek = !jnull(animation[@"seek"]);
  double seek = hasSeek ? jnum(animation[@"seek"], 0.0) : 0.0;
  bool restart = !rec->anim.has_value() || rec->anim->playId != playStr ||
                 rec->anim->name != nameStr || rec->anim->index < 0;
  if (restart) {
    S3dAnimState fresh;
    fresh.name = nameStr;
    fresh.playId = playStr;
    fresh.index = index;
    fresh.duration = (double)animator->getAnimationDuration((size_t)index);
    fresh.clock = hasSeek ? seek : 0.0;
    rec->anim = fresh;
  } else if (hasSeek && (!rec->anim->hasSeek || rec->anim->lastSeek != seek)) {
    rec->anim->clock = seek;
  }
  rec->anim->loop = [animation[@"loop"] boolValue];
  rec->anim->speed = jnum(animation[@"speed"], 1.0);
  rec->anim->paused = [animation[@"paused"] boolValue];
  rec->anim->hasSeek = hasSeek;
  rec->anim->lastSeek = seek;
}

/// Advance every model's clip clock and pose; deliver completions.
- (void)advanceAnimations {
  // Clamped dt: a background pause must not fast-forward clips to their end
  // on resume (the clock freezes with the vsync loop).
  CFTimeInterval now = self.displayLink.timestamp;
  double dt = 0.0;
  if (_lastAnimTimestamp > 0)
    dt = std::clamp(now - _lastAnimTimestamp, 0.0, 0.1);
  _lastAnimTimestamp = now;
  for (auto &pair : _registry) {
    S3dRec &rec = pair.second;
    if (!rec.anim.has_value() || rec.anim->index < 0)
      continue;
    Animator *animator =
        rec.instance != nullptr ? rec.instance->getAnimator() : nullptr;
    if (animator == nullptr)
      continue;
    S3dAnimState &st = *rec.anim;
    if (!st.paused && !st.done)
      st.clock += dt * st.speed;
    if (st.duration <= 0.0) {
      st.appliedTime = 0.0;
    } else if (st.loop) {
      st.appliedTime = std::fmod(st.clock, st.duration);
      if (st.appliedTime < 0)
        st.appliedTime += st.duration;
    } else {
      st.appliedTime = std::min(st.clock, st.duration);
    }
    animator->applyAnimation((size_t)st.index, (float)st.appliedTime);
    animator->updateBoneMatrices();
    if (!st.loop && !st.paused && !st.done && st.clock >= st.duration) {
      // Clip end: clamp the pose at the final frame and deliver
      // {:animation_done, play_id} once per play_id. Completion needs a
      // RUNNING clock — a paused clip seeked to the end holds the final
      // pose without completing until unpaused. Seeking a completed clip
      // repositions the pose; only a new play_id runs it again.
      st.done = true;
      if (!st.doneDelivered) {
        st.doneDelivered = true;
        MobScene3dDeliverAnimationDone(self.viewportId, @(st.playId.c_str()));
      }
    }
  }
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
  // Publish the asset's clip names so the BEAM-thread shadow can reject
  // unknown animation names synchronously from now on.
  NSMutableArray<NSString *> *clipNames = [NSMutableArray array];
  Animator *animator = first != nullptr ? first->getAnimator() : nullptr;
  if (animator != nullptr) {
    for (size_t i = 0; i < animator->getAnimationCount(); i++) {
      [clipNames addObject:@(animator->getAnimationName(i))];
    }
  }
  MobScene3dRegisterAssetAnimations(path, clipNames);
  // Publish the glTF material names too, so unknown material scopes reject
  // synchronously once the asset is loaded.
  NSMutableArray<NSString *> *materialNames = [NSMutableArray array];
  if (first != nullptr) {
    MaterialInstance *const *materials = first->getMaterialInstances();
    for (size_t i = 0; i < first->getMaterialInstanceCount(); i++) {
      const char *name = materials[i]->getName();
      NSString *materialName = name != nullptr ? @(name) : @"";
      if (![materialNames containsObject:materialName])
        [materialNames addObject:materialName];
    }
  }
  MobScene3dRegisterAssetMaterials(path, materialNames);
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
    if (rec.anim.has_value()) {
      // Native truth, not intent echoed back: the applier's own clip clock
      // (data.animation above is the mirrored intent).
      const S3dAnimState &st = *rec.anim;
      NSMutableDictionary *animState = [NSMutableDictionary dictionary];
      animState[@"name"] = @(st.name.c_str());
      animState[@"play_id"] = @(st.playId.c_str());
      if (st.index < 0) {
        animState[@"error"] = @"unknown_animation";
      } else {
        animState[@"time"] = @(std::round(st.appliedTime * 1000.0) / 1000.0);
        animState[@"done"] = @(st.done);
        animState[@"paused"] = @(st.paused);
        animState[@"loop"] = @(st.loop);
      }
      entity[@"animation_state"] = animState;
    }
    if (rec.materialState != nil && rec.materialState.count > 0) {
      // Applied override truth (which scopes matched which glTF material
      // instances) — data.material above is the mirrored intent; this is
      // what the applier actually did.
      entity[@"material_state"] = rec.materialState;
    }
    // World transforms of the instance's NAMED glTF nodes: animation
    // retargets nodes inside the asset, so post-settle orientations (the
    // Chopaat shell-slot contract) are readable per node.
    if (rec.instance != nullptr) {
      auto assetIt = _assets.find(rec.assetRef);
      const FilamentAsset *asset =
          assetIt != _assets.end() ? assetIt->second.asset : nullptr;
      if (asset != nullptr) {
        NSMutableDictionary *nodes = [NSMutableDictionary dictionary];
        const utils::Entity *nodeEntities = rec.instance->getEntities();
        size_t nodeCount = rec.instance->getEntityCount();
        for (size_t i = 0; i < nodeCount; i++) {
          const char *nodeName = asset->getName(nodeEntities[i]);
          if (nodeName == nullptr)
            continue;
          const mat4f nodeWorld =
              tm.getWorldTransform(tm.getInstance(nodeEntities[i]));
          NSMutableArray *nodeArr = [NSMutableArray arrayWithCapacity:16];
          const float *nm = nodeWorld.asArray();
          for (int j = 0; j < 16; j++)
            [nodeArr addObject:@(nm[j])];
          nodes[@(nodeName)] = nodeArr;
        }
        if (nodes.count > 0)
          entity[@"nodes"] = nodes;
      }
    }
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
  delete _names;
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
