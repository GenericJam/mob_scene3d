/* mob_scene3d_nif — iOS NIF wire for the scene3d applier (Objective-C).
 *
 * Owns the shadow registry: every patch is validated atomically
 * (reject-all, the scene-IR decision record's error taxonomy) against pure
 * bookkeeping state, synchronously on the calling BEAM thread — no Filament
 * here. Validated ops queue for the renderer (MobScene3dView.mm), which
 * drains them from its CADisplayLink tick on the main thread — the thread
 * that created the Engine (the spike's binding threading contract). The
 * shadow can bootstrap a (re)attached renderer at any time, which is what
 * survives mob's iOS navVersion root reset (any push/pop transition rebuilds
 * the SwiftUI tree and recreates the native view).
 *
 * Compiled as plain ObjC (-fobjc-arc) via the plugin objc-NIF path
 * (manifest lang: :objc); Foundation only — no vendored include paths.
 *
 * Wire contract: see Mob.Scene3d.Wire (Elixir) and the Kotlin twin
 * (MobScene3dBridge.kt); the parity harness bead (zn8) checks agreement.
 */
#import <Foundation/Foundation.h>
#include <erl_nif.h>

#import "MobScene3dRuntime.h"

static NSString *const kOkJson = @"{\"ok\":true}";

// set_animation deliberately absent: animation playback is a later bead; the
// Elixir caps guard refuses it loudly before it reaches this wire.
static NSString *const kCapsJson =
    @"{\"schema\":1,\"ops\":[\"add_entity\",\"replace_entity\",\"remove_"
    @"entity\","
    @"\"set_parent\",\"set_transform\",\"set_visible\",\"set_pickable\","
    @"\"set_material\",\"set_camera\",\"set_light\",\"set_environment\"]}";

@implementation MobScene3dDrain
@end

// ── Per-viewport state ─────────────────────────────────────────────────────

@interface S3dViewportState : NSObject
@property(nonatomic, strong) NSMutableArray<NSString *> *order;
@property(nonatomic, strong)
    NSMutableDictionary<NSString *, NSDictionary *> *shadow;
@property(nonatomic, strong) NSMutableArray<NSArray *> *pendingOps;
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *sceneRequests;
@property(nonatomic, strong, nullable) NSData *ownerPid;
@property(nonatomic, weak, nullable) NSObject *view;
@property(nonatomic, assign) BOOL resetRequested;
@end

@implementation S3dViewportState
- (instancetype)init {
  self = [super init];
  if (self) {
    _order = [NSMutableArray array];
    _shadow = [NSMutableDictionary dictionary];
    _pendingOps = [NSMutableArray array];
    _sceneRequests = [NSMutableArray array];
  }
  return self;
}
@end

static NSMutableDictionary<NSString *, S3dViewportState *> *
s3d_viewports(void) {
  static NSMutableDictionary *map = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    map = [NSMutableDictionary dictionary];
  });
  return map;
}

static NSLock *s3d_lock(void) {
  static NSLock *lock = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    lock = [[NSLock alloc] init];
  });
  return lock;
}

// ── Shadow semantics (mirrors Mob.Scene3d.IR.Patch, the Elixir reference) ──

static NSArray *s3d_err(NSArray<NSString *> *args) { return args; }

static NSString *s3d_kind_of(NSDictionary *entity) {
  id data = entity[@"data"];
  if (![data isKindOfClass:[NSDictionary class]])
    return @"group";
  NSString *kind = ((NSDictionary *)data)[@"kind"];
  return [kind isKindOfClass:[NSString class]] ? kind : @"group";
}

static NSString *_Nullable s3d_parent_of(NSDictionary *entity) {
  id parent = entity[@"parent"];
  return [parent isKindOfClass:[NSString class]] ? parent : nil;
}

static BOOL s3d_has_animation(NSDictionary *entity) {
  id data = entity[@"data"];
  if (![data isKindOfClass:[NSDictionary class]])
    return NO;
  if (![s3d_kind_of(entity) isEqualToString:@"model"])
    return NO;
  id anim = ((NSDictionary *)data)[@"animation"];
  return anim != nil && anim != [NSNull null];
}

static BOOL s3d_cyclic(NSDictionary<NSString *, NSDictionary *> *shadow,
                       NSString *start) {
  NSMutableSet *seen = [NSMutableSet set];
  NSString *current = start;
  while (current != nil) {
    if ([seen containsObject:current])
      return YES;
    [seen addObject:current];
    NSDictionary *entity = shadow[current];
    current = entity ? s3d_parent_of(entity) : nil;
  }
  return NO;
}

static NSDictionary *s3d_put_field(NSDictionary *entity, NSString *field,
                                   id value) {
  NSMutableDictionary *updated = [entity mutableCopy];
  updated[field] = value ?: [NSNull null];
  return [updated copy];
}

static NSDictionary *s3d_put_data_field(NSDictionary *entity, NSString *field,
                                        id value) {
  NSMutableDictionary *updated = [entity mutableCopy];
  NSMutableDictionary *data = [((NSDictionary *)entity[@"data"]) mutableCopy];
  data[field] = value ?: [NSNull null];
  updated[@"data"] = [data copy];
  return [updated copy];
}

/// Applies one op to the working shadow. Returns an error array or nil.
static NSArray *_Nullable s3d_apply_op(
    NSMutableArray<NSString *> *order,
    NSMutableDictionary<NSString *, NSDictionary *> *shadow, NSArray *op) {
  if (op.count < 2 || ![op[0] isKindOfClass:[NSString class]])
    return s3d_err(@[ @"bad_patch", @"op shape" ]);
  NSString *name = op[0];

  if ([name isEqualToString:@"add_entity"] ||
      [name isEqualToString:@"replace_entity"]) {
    if (![op[1] isKindOfClass:[NSDictionary class]])
      return s3d_err(@[ @"bad_patch", name ]);
    NSDictionary *entity = op[1];
    NSString *eid = entity[@"id"];
    NSString *parent = s3d_parent_of(entity);
    BOOL replacing = [name isEqualToString:@"replace_entity"];
    if (replacing && shadow[eid] == nil)
      return s3d_err(@[ @"unknown_entity", eid ]);
    if (!replacing && shadow[eid] != nil)
      return s3d_err(@[ @"duplicate_entity", eid ]);
    if (parent != nil && shadow[parent] == nil)
      return s3d_err(@[ @"unknown_parent", eid, parent ]);
    if (s3d_has_animation(entity))
      return s3d_err(@[ @"unsupported", @"animation" ]);
    if (!replacing)
      [order addObject:eid];
    shadow[eid] = entity;
    return nil;
  }

  NSString *eid = [op[1] isKindOfClass:[NSString class]] ? op[1] : @"";
  NSDictionary *entity = shadow[eid];

  if ([name isEqualToString:@"remove_entity"]) {
    if (entity == nil)
      return s3d_err(@[ @"unknown_entity", eid ]);
    for (NSDictionary *other in shadow.allValues) {
      if ([s3d_parent_of(other) isEqualToString:eid])
        return s3d_err(@[ @"has_children", eid ]);
    }
    [shadow removeObjectForKey:eid];
    [order removeObject:eid];
    return nil;
  }

  if (entity == nil)
    return s3d_err(@[ @"unknown_entity", eid ]);
  id value = op.count > 2 ? op[2] : [NSNull null];

  if ([name isEqualToString:@"set_parent"]) {
    NSString *parent = [value isKindOfClass:[NSString class]] ? value : nil;
    if (parent != nil && shadow[parent] == nil)
      return s3d_err(@[ @"unknown_parent", eid, parent ]);
    shadow[eid] = s3d_put_field(entity, @"parent", parent);
    if (s3d_cyclic(shadow, eid))
      return s3d_err(@[ @"invalid_result", @"parent_cycle" ]);
    return nil;
  }
  if ([name isEqualToString:@"set_transform"] ||
      [name isEqualToString:@"set_visible"] ||
      [name isEqualToString:@"set_pickable"]) {
    NSString *field =
        [name substringFromIndex:4]; // "transform" | "visible" | "pickable"
    shadow[eid] = s3d_put_field(entity, field, value);
    return nil;
  }
  if ([name isEqualToString:@"set_material"]) {
    if (![s3d_kind_of(entity) isEqualToString:@"model"])
      return s3d_err(@[ @"kind_mismatch", eid, @"model" ]);
    shadow[eid] = s3d_put_data_field(entity, @"material", value);
    return nil;
  }
  if ([name isEqualToString:@"set_animation"]) {
    return s3d_err(@[ @"unsupported", @"animation" ]);
  }
  if ([name isEqualToString:@"set_camera"] ||
      [name isEqualToString:@"set_light"] ||
      [name isEqualToString:@"set_environment"]) {
    NSString *kind = [name substringFromIndex:4];
    if (![s3d_kind_of(entity) isEqualToString:kind])
      return s3d_err(@[ @"kind_mismatch", eid, kind ]);
    if (![value isKindOfClass:[NSDictionary class]])
      return s3d_err(@[ @"bad_patch", name ]);
    NSDictionary *current = entity[@"data"];
    NSDictionary *next = value;
    if ([name isEqualToString:@"set_light"]) {
      if (![current[@"type"] isEqual:next[@"type"]])
        return s3d_err(@[ @"structural_field", eid, @"light_type" ]);
    }
    if ([name isEqualToString:@"set_environment"]) {
      id cIbl = current[@"ibl"] ?: [NSNull null],
         nIbl = next[@"ibl"] ?: [NSNull null];
      id cSky = current[@"skybox"] ?: [NSNull null],
         nSky = next[@"skybox"] ?: [NSNull null];
      if (![cIbl isEqual:nIbl] || ![cSky isEqual:nSky])
        return s3d_err(@[ @"structural_field", eid, @"environment_assets" ]);
    }
    NSMutableDictionary *tagged = [next mutableCopy];
    tagged[@"kind"] = kind;
    shadow[eid] = s3d_put_field(entity, @"data", [tagged copy]);
    return nil;
  }
  return s3d_err(@[ @"unknown_op", name ]);
}

static NSArray *_Nullable s3d_validate_result(
    NSDictionary<NSString *, NSDictionary *> *shadow) {
  NSUInteger cameras = 0, environments = 0;
  for (NSDictionary *entity in shadow.allValues) {
    NSString *kind = s3d_kind_of(entity);
    if ([kind isEqualToString:@"camera"])
      cameras++;
    if ([kind isEqualToString:@"environment"])
      environments++;
  }
  if (cameras > 1)
    return s3d_err(@[ @"invalid_result", @"multiple_cameras" ]);
  if (environments > 1)
    return s3d_err(@[ @"invalid_result", @"multiple_environments" ]);
  return nil;
}

// ── JSON plumbing ──────────────────────────────────────────────────────────

static NSString *s3d_error_json(NSArray *error) {
  NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"error" : error}
                                                 options:0
                                                   error:nil];
  return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

// ── The runtime seam (renderer side, main thread) ──────────────────────────

NSArray<NSArray *> *MobScene3dAttach(NSString *viewportId, NSObject *view) {
  [s3d_lock() lock];
  S3dViewportState *state = s3d_viewports()[viewportId];
  if (state == nil) {
    state = [[S3dViewportState alloc] init];
    s3d_viewports()[viewportId] = state;
  }
  state.view = view;
  state.resetRequested = NO;
  [state.pendingOps removeAllObjects]; // subsumed by the shadow replay
  NSMutableArray *bootstrap =
      [NSMutableArray arrayWithCapacity:state.order.count];
  for (NSString *eid in state.order) {
    NSDictionary *entity = state.shadow[eid];
    if (entity)
      [bootstrap addObject:@[ @"add_entity", entity ]];
  }
  [s3d_lock() unlock];
  return bootstrap;
}

void MobScene3dDetach(NSString *viewportId, NSObject *view) {
  [s3d_lock() lock];
  S3dViewportState *state = s3d_viewports()[viewportId];
  if (state != nil && state.view == view)
    state.view = nil;
  [s3d_lock() unlock];
}

MobScene3dDrain *MobScene3dDrainTick(NSString *viewportId) {
  MobScene3dDrain *drain = [[MobScene3dDrain alloc] init];
  [s3d_lock() lock];
  S3dViewportState *state = s3d_viewports()[viewportId];
  if (state == nil) {
    drain.ops = @[];
    drain.sceneRequests = @[];
    drain.reset = NO;
  } else {
    drain.ops = [state.pendingOps copy];
    [state.pendingOps removeAllObjects];
    drain.sceneRequests = [state.sceneRequests copy];
    [state.sceneRequests removeAllObjects];
    drain.reset = state.resetRequested;
    state.resetRequested = NO;
  }
  [s3d_lock() unlock];
  return drain;
}

static void s3d_send_to(NSData *pidData, ERL_NIF_TERM (^build)(ErlNifEnv *)) {
  if (pidData == nil || pidData.length != sizeof(ErlNifPid))
    return;
  ErlNifPid pid;
  memcpy(&pid, pidData.bytes, sizeof(ErlNifPid));
  ErlNifEnv *env = enif_alloc_env();
  if (env == NULL)
    return;
  ERL_NIF_TERM msg = build(env);
  enif_send(NULL, &pid, env, msg);
  enif_free_env(env);
}

static ERL_NIF_TERM s3d_make_bin(ErlNifEnv *env, NSString *string) {
  NSData *data = [string dataUsingEncoding:NSUTF8StringEncoding];
  ERL_NIF_TERM term;
  unsigned char *buf = enif_make_new_binary(env, data.length, &term);
  memcpy(buf, data.bytes, data.length);
  return term;
}

void MobScene3dDeliverScene(NSData *token, NSString *viewportId,
                            NSString *requestId, NSString *sceneJson) {
  s3d_send_to(token, ^ERL_NIF_TERM(ErlNifEnv *env) {
    return enif_make_tuple4(env, enif_make_atom(env, "scene3d_scene"),
                            s3d_make_bin(env, viewportId),
                            s3d_make_bin(env, requestId),
                            s3d_make_bin(env, sceneJson));
  });
}

static NSData *s3d_owner(NSString *viewportId) {
  [s3d_lock() lock];
  NSData *owner = s3d_viewports()[viewportId].ownerPid;
  [s3d_lock() unlock];
  return owner;
}

void MobScene3dDeliverError(NSString *viewportId, NSString *errorJson) {
  s3d_send_to(s3d_owner(viewportId), ^ERL_NIF_TERM(ErlNifEnv *env) {
    return enif_make_tuple3(env, enif_make_atom(env, "scene3d_error"),
                            s3d_make_bin(env, viewportId),
                            s3d_make_bin(env, errorJson));
  });
}

void MobScene3dDeliverReady(NSString *viewportId) {
  s3d_send_to(s3d_owner(viewportId), ^ERL_NIF_TERM(ErlNifEnv *env) {
    return enif_make_tuple2(env, enif_make_atom(env, "scene3d_ready"),
                            s3d_make_bin(env, viewportId));
  });
}

// ── NIF marshalling ────────────────────────────────────────────────────────

static NSString *_Nullable s3d_term_to_string(ErlNifEnv *env,
                                              ERL_NIF_TERM term) {
  ErlNifBinary bin;
  if (!enif_inspect_binary(env, term, &bin) &&
      !enif_inspect_iolist_as_binary(env, term, &bin))
    return nil;
  return [[NSString alloc] initWithBytes:bin.data
                                  length:bin.size
                                encoding:NSUTF8StringEncoding];
}

static ERL_NIF_TERM s3d_result(ErlNifEnv *env, NSString *json) {
  return s3d_make_bin(env, json);
}

// ── NIFs ───────────────────────────────────────────────────────────────────

static ERL_NIF_TERM nif_scene3d_caps(ErlNifEnv *env, int argc,
                                     const ERL_NIF_TERM argv[]) {
  (void)argc;
  (void)argv;
  return s3d_result(env, kCapsJson);
}

static ERL_NIF_TERM nif_scene3d_apply(ErlNifEnv *env, int argc,
                                      const ERL_NIF_TERM argv[]) {
  (void)argc;
  NSString *viewportId = s3d_term_to_string(env, argv[0]);
  NSString *patchJson = s3d_term_to_string(env, argv[1]);
  if (viewportId == nil || patchJson == nil)
    return enif_make_badarg(env);

  NSData *patchData = [patchJson dataUsingEncoding:NSUTF8StringEncoding];
  NSError *jsonError = nil;
  id envelope = [NSJSONSerialization JSONObjectWithData:patchData
                                                options:0
                                                  error:&jsonError];
  if (![envelope isKindOfClass:[NSDictionary class]])
    return s3d_result(env, s3d_error_json(@[ @"bad_patch", @"parse" ]));
  if (![envelope[@"schema"] isEqual:@1])
    return s3d_result(env, s3d_error_json(@[ @"bad_patch", @"schema" ]));
  NSArray *ops = envelope[@"ops"];
  if (![ops isKindOfClass:[NSArray class]])
    return s3d_result(env, s3d_error_json(@[ @"bad_patch", @"ops" ]));

  ErlNifPid selfPid;
  enif_self(env, &selfPid);
  NSData *pidData = [NSData dataWithBytes:&selfPid length:sizeof(ErlNifPid)];

  [s3d_lock() lock];
  S3dViewportState *state = s3d_viewports()[viewportId];
  if (state == nil) {
    state = [[S3dViewportState alloc] init];
    s3d_viewports()[viewportId] = state;
  }
  state.ownerPid = pidData;

  // Dry-run the whole patch against working copies: atomic reject-all
  // before anything is queued for Filament.
  NSMutableArray *workOrder = [state.order mutableCopy];
  NSMutableDictionary *workShadow = [state.shadow mutableCopy];
  NSArray *failure = nil;
  for (id op in ops) {
    if (![op isKindOfClass:[NSArray class]]) {
      failure = @[ @"bad_patch", @"op shape" ];
      break;
    }
    failure = s3d_apply_op(workOrder, workShadow, op);
    if (failure != nil)
      break;
  }
  if (failure == nil)
    failure = s3d_validate_result(workShadow);

  if (failure == nil) {
    state.order = workOrder;
    state.shadow = workShadow;
    [state.pendingOps addObjectsFromArray:ops];
  }
  [s3d_lock() unlock];

  return failure == nil ? s3d_result(env, kOkJson)
                        : s3d_result(env, s3d_error_json(failure));
}

static ERL_NIF_TERM nif_scene3d_scene(ErlNifEnv *env, int argc,
                                      const ERL_NIF_TERM argv[]) {
  (void)argc;
  NSString *viewportId = s3d_term_to_string(env, argv[0]);
  NSString *requestId = s3d_term_to_string(env, argv[1]);
  if (viewportId == nil || requestId == nil)
    return enif_make_badarg(env);

  ErlNifPid selfPid;
  enif_self(env, &selfPid);
  NSData *pidData = [NSData dataWithBytes:&selfPid length:sizeof(ErlNifPid)];

  [s3d_lock() lock];
  S3dViewportState *state = s3d_viewports()[viewportId];
  BOOL attached = state != nil && state.view != nil;
  if (attached) {
    [state.sceneRequests
        addObject:@{@"request_id" : requestId, @"token" : pidData}];
  }
  [s3d_lock() unlock];

  if (!attached)
    return s3d_result(env, s3d_error_json(@[ @"no_viewport", viewportId ]));
  return s3d_result(env, kOkJson);
}

static ERL_NIF_TERM nif_scene3d_destroy(ErlNifEnv *env, int argc,
                                        const ERL_NIF_TERM argv[]) {
  (void)argc;
  NSString *viewportId = s3d_term_to_string(env, argv[0]);
  if (viewportId == nil)
    return enif_make_badarg(env);

  [s3d_lock() lock];
  S3dViewportState *state = s3d_viewports()[viewportId];
  if (state != nil) {
    [state.order removeAllObjects];
    [state.shadow removeAllObjects];
    [state.pendingOps removeAllObjects];
    [state.sceneRequests removeAllObjects];
    state.resetRequested = YES;
  }
  [s3d_lock() unlock];
  return s3d_result(env, kOkJson);
}

// ── Registration ───────────────────────────────────────────────────────────

static int load(ErlNifEnv *env, void **priv_data, ERL_NIF_TERM load_info) {
  (void)env;
  (void)priv_data;
  (void)load_info;
  return 0;
}

static ErlNifFunc nif_funcs[] = {
    {"scene3d_caps", 0, nif_scene3d_caps, 0},
    {"scene3d_apply", 2, nif_scene3d_apply, 0},
    {"scene3d_scene", 2, nif_scene3d_scene, 0},
    {"scene3d_destroy", 1, nif_scene3d_destroy, 0},
};

ERL_NIF_INIT(mob_scene3d_nif, nif_funcs, load, NULL, NULL, NULL)
