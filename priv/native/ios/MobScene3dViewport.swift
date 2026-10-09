// MobScene3dViewport — the SwiftUI wrapper the ui_components registration
// instantiates (registry key "Mob_Scene3d_Viewport", the Mob.Component
// module-name encoding of Mob.Scene3d.Viewport).
//
// MobScene3dView is ObjC (Filament behind it, ObjC++), linked from the
// plugin's static archive. The host's bridging header is mob's and doesn't
// import plugin headers, so this file reaches the class through the ObjC
// runtime: +viewWithViewportId: by selector, the properties by key.
import SwiftUI

// Mirrors Mob.Scene3d.default_max_asset_bytes/0 (64 MiB), for a host whose
// props predate max_asset_bytes.
private let defaultMaxAssetBytes: Int64 = 64 * 1024 * 1024

private func makeScene3dView(viewportId: String) -> UIView {
    // The NIF refuses to load without the class (mob_scene3d_nif.m), so a
    // miss here means the app was linked without the plugin's archive.
    guard let cls = NSClassFromString("MobScene3dView") else {
        preconditionFailure("mob_scene3d: MobScene3dView is not linked into this app")
    }
    let factory: AnyObject = cls
    guard
        let view = factory.perform(
            NSSelectorFromString("viewWithViewportId:"), with: viewportId
        )?.takeUnretainedValue() as? UIView
    else {
        preconditionFailure("mob_scene3d: +[MobScene3dView viewWithViewportId:] returned no view")
    }
    return view
}

private struct MobScene3dRepresentable: UIViewRepresentable {
    let viewportId: String
    // 0xAARRGGBB (sRGB) clear colour, or nil for the default dark skybox.
    let background: NSNumber?
    // Largest model file (bytes) the viewport loads.
    let maxAssetBytes: Int64

    func makeUIView(context: Context) -> UIView {
        let view = makeScene3dView(viewportId: viewportId)
        configure(view)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        configure(uiView)
    }

    private func configure(_ view: UIView) {
        view.setValue(background, forKey: "backgroundArgb")
        view.setValue(NSNumber(value: maxAssetBytes), forKey: "maxAssetBytes")
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
