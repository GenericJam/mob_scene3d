// MobScene3dRuntime.h — the seam between the scene3d NIF wire (ObjC,
// mob_scene3d_nif.m — shadow registry, queues, enif_send) and the Filament
// renderer (ObjC++, MobScene3dView.mm). The renderer polls the runtime from
// the CADisplayLink tick on the main thread; the NIF side fills it from BEAM
// scheduler threads under a lock. No Filament types cross this header, so
// the NIF compiles as plain ObjC with no vendored include paths.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// One render tick's worth of work.
@interface MobScene3dDrain : NSObject
@property(nonatomic, strong) NSArray<NSArray *> *ops;
/// Each: @{ @"request_id": NSString, @"token": NSData (opaque pid) }
@property(nonatomic, strong) NSArray<NSDictionary *> *sceneRequests;
/// Introspection queries. Each: @{ @"kind": @"pick"|@"sample"|@"stats",
/// @"request_id": NSString, @"token": NSData, @"params": NSDictionary }
@property(nonatomic, strong) NSArray<NSDictionary *> *queries;
@property(nonatomic, assign) BOOL reset;
@end

#ifdef __cplusplus
extern "C" {
#endif

/// Register the renderer for a viewport; returns bootstrap ops replaying the
/// shadow registry (parents-first). Main thread.
NSArray<NSArray *> *MobScene3dAttach(NSString *viewportId, NSObject *view);
void MobScene3dDetach(NSString *viewportId, NSObject *view);
MobScene3dDrain *MobScene3dDrainTick(NSString *viewportId);

/// Async replies back to the BEAM (enif_send — safe from any thread).
void MobScene3dDeliverScene(NSData *token, NSString *viewportId,
                            NSString *requestId, NSString *sceneJson);
/// kind = @"pick" | @"sample" | @"stats" → {:scene3d_pick | :scene3d_sample
/// | :scene3d_frame_stats, viewport, request_id, json} to the query's owner.
void MobScene3dDeliverReply(NSString *kind, NSData *token,
                            NSString *viewportId, NSString *requestId,
                            NSString *json);
/// Touch-path pick hit → {:scene3d_pick_event, viewport, entity_id} to the
/// viewport owner. Misses deliver nothing (the honest-miss ruling).
void MobScene3dDeliverPickEvent(NSString *viewportId, NSString *entityId);
void MobScene3dDeliverError(NSString *viewportId, NSString *errorJson);
void MobScene3dDeliverReady(NSString *viewportId);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
