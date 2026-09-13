// MobScene3dView — the iOS Filament renderer + surface/lifecycle shim.
// Plain-ObjC interface so Swift consumes it through the host bridging
// header; the implementation (MobScene3dView.mm) is ObjC++ against
// Filament's C++ API and is compiled by the host's ios/build.zig with the
// vendored Filament include path (manifest host_requirements — spike
// landmine 6: no manifest key for prebuilt static libs yet).
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface MobScene3dView : UIView

- (instancetype)initWithFrame:(CGRect)frame viewportId:(NSString *)viewportId;

/// The clear colour as 0xAARRGGBB (sRGB); nil restores the default dark
/// skybox. Settable at any time — the skybox is re-tinted in place.
@property(nonatomic, strong, nullable) NSNumber *backgroundArgb;

@end

NS_ASSUME_NONNULL_END
