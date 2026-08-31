// Project bridging header — extends mob's bridging header with the
// spike's ObjC surface so Swift can instantiate Scene3dFilamentView.
// Wired in ios/build.zig (-import-objc-header points here; mob's header
// resolves via -Xcc -I<mob_dir>/ios).
#import "MobDemo-Bridging-Header.h"
#import "Scene3dFilamentView.h"
// mob_scene3d plugin (host_requirements): the viewport UIView + runtime
// seam, resolved via -Xcc -I<plugin>/priv/native/ios in build*.zig.
#import "MobScene3dRuntime.h"
#import "MobScene3dView.h"
