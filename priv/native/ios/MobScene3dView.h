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

@end

NS_ASSUME_NONNULL_END
