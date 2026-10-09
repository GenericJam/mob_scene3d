// MobScene3dView — the iOS Filament renderer + surface/lifecycle shim.
// Plain-ObjC interface; the implementation (MobScene3dView.mm) is ObjC++
// against Filament's C++ API, archived with the NIF into
// libmob_scene3d_nif.a by mob_dev (manifest `lang: :cpp_archive`, Filament
// headers and static libraries from the `prebuilt:` bundle).
//
// Swift (MobScene3dViewport.swift) creates the view by class name through
// +viewWithViewportId: and sets the properties by key, so the host's
// bridging header never has to import this file.
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface MobScene3dView : UIView

/// The view for one viewport, framed by its SwiftUI container.
+ (instancetype)viewWithViewportId:(NSString *)viewportId;

- (instancetype)initWithFrame:(CGRect)frame viewportId:(NSString *)viewportId;

/// The clear colour as 0xAARRGGBB (sRGB); nil restores the default dark
/// skybox. Settable at any time — the skybox is re-tinted in place.
@property(nonatomic, strong, nullable) NSNumber *backgroundArgb;

/// Largest model file (bytes) this viewport loads; bigger files fail with
/// bad_asset "too_large" before a byte is read. Default 64 MiB. Read when
/// a load starts, so a change applies to the next load.
@property(nonatomic, assign) long long maxAssetBytes;

@end

NS_ASSUME_NONNULL_END
