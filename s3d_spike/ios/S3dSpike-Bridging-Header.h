// Project bridging header — extends mob's bridging header with the
// spike's ObjC surface so Swift can instantiate Scene3dFilamentView.
// Wired in ios/build.zig (-import-objc-header points here; mob's header
// resolves via -Xcc -I<mob_dir>/ios).
#import "MobDemo-Bridging-Header.h"
#import "Scene3dFilamentView.h"
