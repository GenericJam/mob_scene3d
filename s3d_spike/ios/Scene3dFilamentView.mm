// Scene3dFilamentView.mm — Filament embedding spike (bead mob_scene3d-b9g).
//
// Creates a Filament Engine (Metal backend) with a swapchain against this
// view's CAMetalLayer, loads a .glb via gltfio (ubershader materials from
// libuberarchive.a), lights it with one directional light, and spins it
// from a CADisplayLink. All Filament calls stay on the main thread — the
// thread that created the Engine (Filament's single-threaded API contract;
// its backend driver runs on an internal thread it manages itself).

#import "Scene3dFilamentView.h"

#import <QuartzCore/CAMetalLayer.h>

#include <filament/Box.h>
#include <filament/Camera.h>
#include <filament/Engine.h>
#include <filament/LightManager.h>
#include <filament/Renderer.h>
#include <filament/Scene.h>
#include <filament/Skybox.h>
#include <filament/SwapChain.h>
#include <filament/TransformManager.h>
#include <filament/View.h>
#include <filament/Viewport.h>

#include <gltfio/AssetLoader.h>
#include <gltfio/FilamentAsset.h>
#include <gltfio/MaterialProvider.h>
#include <gltfio/ResourceLoader.h>
#include <gltfio/materials/uberarchive.h>

#include <math/mat4.h>
#include <math/vec3.h>

#include <utils/Entity.h>
#include <utils/EntityManager.h>

#include <algorithm>

using namespace filament;
using namespace filament::math;
using namespace filament::gltfio;

@interface Scene3dFilamentView () {
  Engine *_engine;
  Renderer *_renderer;
  Scene *_scene;
  View *_view;
  SwapChain *_swapChain;
  Camera *_camera;
  utils::Entity _cameraEntity;
  utils::Entity _lightEntity;
  Skybox *_skybox;
  MaterialProvider *_materials;
  AssetLoader *_assetLoader;
  FilamentAsset *_asset;
  mat4f _baseTransform;
  CFTimeInterval _startTime;
  NSUInteger _frameCount;
}
@property(nonatomic, strong) CADisplayLink *displayLink;
@property(nonatomic, copy) NSString *assetPath;
@property(nonatomic, copy, nullable) S3dReadyBlock onReady;
@end

@implementation Scene3dFilamentView

+ (Class)layerClass {
  return [CAMetalLayer class];
}

- (instancetype)initWithFrame:(CGRect)frame
                    assetPath:(NSString *)assetPath
                      onReady:(nullable S3dReadyBlock)onReady {
  self = [super initWithFrame:frame];
  if (self) {
    _assetPath = [assetPath copy];
    _onReady = [onReady copy];
    _startTime = 0;
    _frameCount = 0;
    self.contentScaleFactor = UIScreen.mainScreen.scale;
    [self setupFilament];
  }
  return self;
}

- (void)setupFilament {
  CAMetalLayer *metalLayer = (CAMetalLayer *)self.layer;
  metalLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;

  // Backend::DEFAULT resolves to Metal on iOS.
  _engine = Engine::create();
  _renderer = _engine->createRenderer();
  _scene = _engine->createScene();
  _view = _engine->createView();

  _cameraEntity = utils::EntityManager::get().create();
  _camera = _engine->createCamera(_cameraEntity);
  // Physical-light exposure: sunny-16. Matches the 110k-lux directional
  // light below (same values as the Android side).
  _camera->setExposure(16.0f, 1 / 125.0f, 100.0f);
  _camera->lookAt(float3{0, 1.8f, 4.8f}, float3{0, 0, 0}, float3{0, 1, 0});

  _view->setScene(_scene);
  _view->setCamera(_camera);
  // Metal-on-simulator: the shadow pass zeroes the direct-light term
  // (fully black model, correct silhouette); a real device doesn't need
  // this. Spike keeps shadows off on iOS and notes it in the decision
  // record.
  _view->setShadowingEnabled(false);

  // Solid dark skybox so the surface is visibly alive even with no model.
  _skybox =
      Skybox::Builder().color({0.035f, 0.04f, 0.07f, 1.0f}).build(*_engine);
  _scene->setSkybox(_skybox);

  // The spike's directional light.
  _lightEntity = utils::EntityManager::get().create();
  LightManager::Builder(LightManager::Type::DIRECTIONAL)
      .color({1.0f, 0.98f, 0.92f})
      .intensity(110000.0f)
      .direction(normalize(float3{0.5f, -1.0f, -0.6f}))
      .castShadows(false)
      .build(*_engine, _lightEntity);
  _scene->addEntity(_lightEntity);

  [self loadGlb];
}

- (void)loadGlb {
  NSData *data = [NSData dataWithContentsOfFile:self.assetPath];
  if (data == nil) {
    NSLog(@"[scene3d] missing glb at %@", self.assetPath);
    return;
  }

  _materials = createUbershaderProvider(_engine, UBERARCHIVE_DEFAULT_DATA,
                                        UBERARCHIVE_DEFAULT_SIZE);

  AssetConfiguration config;
  config.engine = _engine;
  config.materials = _materials;
  _assetLoader = AssetLoader::create(config);

  _asset = _assetLoader->createAsset(static_cast<const uint8_t *>(data.bytes),
                                     (uint32_t)data.length);
  if (_asset == nullptr) {
    NSLog(@"[scene3d] gltfio failed to parse %@", self.assetPath);
    return;
  }

  ResourceConfiguration resources{};
  resources.engine = _engine;
  resources.normalizeSkinningWeights = true;
  ResourceLoader(resources).loadResources(_asset);
  _asset->releaseSourceData();

  _scene->addEntities(_asset->getEntities(), _asset->getEntityCount());

  // Center + scale into a unit cube at the origin (ModelViewer parity).
  Aabb bounds = _asset->getBoundingBox();
  float3 center = bounds.center();
  float3 halfExtent = bounds.extent();
  float maxExtent = 2.0f * std::max({halfExtent.x, halfExtent.y, halfExtent.z});
  float scaleFactor = 2.0f / maxExtent;
  _baseTransform =
      mat4f::scaling(float3{scaleFactor}) * mat4f::translation(-center);
  NSLog(@"[scene3d] bounds min=(%f,%f,%f) max=(%f,%f,%f) center=(%f,%f,%f) "
        @"scale=%f entities=%zu",
        bounds.min.x, bounds.min.y, bounds.min.z, bounds.max.x, bounds.max.y,
        bounds.max.z, center.x, center.y, center.z, scaleFactor,
        _asset->getEntityCount());

  TransformManager &tm = _engine->getTransformManager();
  tm.setTransform(tm.getInstance(_asset->getRoot()), _baseTransform);
}

- (void)didMoveToWindow {
  [super didMoveToWindow];
  if (self.window != nil && self.displayLink == nil) {
    self.displayLink =
        [CADisplayLink displayLinkWithTarget:self
                                    selector:@selector(renderFrame)];
    [self.displayLink addToRunLoop:NSRunLoop.mainRunLoop
                           forMode:NSRunLoopCommonModes];
  } else if (self.window == nil && self.displayLink != nil) {
    [self.displayLink invalidate];
    self.displayLink = nil;
  }
}

- (void)layoutSubviews {
  [super layoutSubviews];
  CAMetalLayer *metalLayer = (CAMetalLayer *)self.layer;
  CGFloat scale = self.contentScaleFactor;
  CGSize size = CGSizeMake(self.bounds.size.width * scale,
                           self.bounds.size.height * scale);
  if (size.width < 1 || size.height < 1) {
    return;
  }
  metalLayer.drawableSize = size;

  if (_swapChain == nullptr) {
    _swapChain = _engine->createSwapChain((__bridge void *)metalLayer);
  }
  _view->setViewport(
      Viewport(0, 0, (uint32_t)size.width, (uint32_t)size.height));
  _camera->setProjection(35.0, size.width / size.height, 0.05, 100.0,
                         Camera::Fov::VERTICAL);
}

- (void)renderFrame {
  if (_swapChain == nullptr) {
    return;
  }

  if (_startTime == 0) {
    _startTime = CACurrentMediaTime();
  }
  if (_asset != nullptr) {
    float angle =
        (float)((CACurrentMediaTime() - _startTime) * (45.0 * M_PI / 180.0));
    TransformManager &tm = _engine->getTransformManager();
    tm.setTransform(tm.getInstance(_asset->getRoot()),
                    mat4f::rotation(angle, float3{0, 1, 0}) * _baseTransform);
  }

  if (_renderer->beginFrame(_swapChain)) {
    _renderer->render(_view);
    _renderer->endFrame();
    _frameCount++;
    if (_frameCount % 120 == 1) {
      const Viewport &vp = _view->getViewport();
      NSLog(@"[scene3d] frame=%lu viewport=%ux%u scale=%f",
            (unsigned long)_frameCount, vp.width, vp.height,
            (double)self.contentScaleFactor);
    }
    if (_frameCount == 1 && self.onReady != nil) {
      S3dReadyBlock ready = self.onReady;
      dispatch_async(dispatch_get_main_queue(), ^{
        ready();
      });
    }
  }
}

- (void)dealloc {
  [_displayLink invalidate];
  if (_engine == nullptr) {
    return;
  }
  if (_asset != nullptr) {
    _scene->removeEntities(_asset->getEntities(), _asset->getEntityCount());
    _assetLoader->destroyAsset(_asset);
  }
  if (_assetLoader != nullptr) {
    AssetLoader::destroy(&_assetLoader);
  }
  if (_materials != nullptr) {
    _materials->destroyMaterials();
    delete _materials;
  }
  _engine->destroy(_skybox);
  _engine->destroyCameraComponent(_cameraEntity);
  utils::EntityManager::get().destroy(_cameraEntity);
  _scene->remove(_lightEntity);
  _engine->destroy(_lightEntity);
  _engine->destroy(_view);
  _engine->destroy(_scene);
  _engine->destroy(_renderer);
  if (_swapChain != nullptr) {
    _engine->destroy(_swapChain);
  }
  Engine::destroy(&_engine);
}

@end
