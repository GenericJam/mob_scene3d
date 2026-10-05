// MobScene3dViewport — the SwiftUI wrapper the ui_components registration
// instantiates (registry key "Mob_Scene3d_Viewport", the Mob.Component
// module-name encoding of Mob.Scene3d.Viewport).
//
// MobScene3dView is ObjC (Filament behind it, ObjC++); it resolves through
// the host bridging header, which must #import MobScene3dView.h (manifest
// host_requirements).
import SwiftUI

// Mirrors Mob.Scene3d.default_max_asset_bytes/0 (64 MiB), for a host whose
// props predate max_asset_bytes.
private let defaultMaxAssetBytes: Int64 = 64 * 1024 * 1024

private struct MobScene3dRepresentable: UIViewRepresentable {
    let viewportId: String
    // 0xAARRGGBB (sRGB) clear colour, or nil for the default dark skybox.
    let background: NSNumber?
    // Largest model file (bytes) the viewport loads.
    let maxAssetBytes: Int64

    func makeUIView(context: Context) -> MobScene3dView {
        let view = MobScene3dView(frame: .zero, viewportId: viewportId)
        view.backgroundArgb = background
        view.maxAssetBytes = maxAssetBytes
        return view
    }

    func updateUIView(_ uiView: MobScene3dView, context: Context) {
        uiView.backgroundArgb = background
        uiView.maxAssetBytes = maxAssetBytes
    }
}

public struct MobScene3dViewport: View {
    let props: [String: Any]

    public init(props: [String: Any]) {
        self.props = props
    }

    public var body: some View {
        let viewportId = props["viewport_id"] as? String ?? ""
        let width = (props["width"] as? NSNumber)?.doubleValue ?? 340
        let height = (props["height"] as? NSNumber)?.doubleValue ?? 420
        let background = props["background"] as? NSNumber
        let maxAssetBytes =
            (props["max_asset_bytes"] as? NSNumber)?.int64Value ?? defaultMaxAssetBytes
        if viewportId.isEmpty {
            EmptyView()
        } else {
            MobScene3dRepresentable(
                viewportId: viewportId, background: background, maxAssetBytes: maxAssetBytes
            )
            .frame(width: width, height: height)
            .clipped()
        }
    }
}
