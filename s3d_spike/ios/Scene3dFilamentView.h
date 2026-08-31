// Scene3dFilamentView — Filament embedding spike (bead mob_scene3d-b9g).
//
// Plain-ObjC interface so Swift can consume it through the bridging
// header; the implementation (.mm) is ObjC++ against Filament's C++ API.
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^S3dReadyBlock)(void);

@interface Scene3dFilamentView : UIView

- (instancetype)initWithFrame:(CGRect)frame
                    assetPath:(NSString *)assetPath
                      onReady:(nullable S3dReadyBlock)onReady;

@end

NS_ASSUME_NONNULL_END
