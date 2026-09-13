// MobScene3dViewport — the SwiftUI wrapper the ui_components registration
// instantiates (registry key "Mob_Scene3d_Viewport", the Mob.Component
// module-name encoding of Mob.Scene3d.Viewport).
//
// MobScene3dView is ObjC (Filament behind it, ObjC++); it resolves through
// the host bridging header, which must #import MobScene3dView.h (manifest
// host_requirements).
import SwiftUI

private struct MobScene3dRepresentable: UIViewRepresentable {
    let viewportId: String
    // 0xAARRGGBB (sRGB) clear colour, or nil for the default dark skybox.
    let background: NSNumber?

    func makeUIView(context: Context) -> MobScene3dView {
        let view = MobScene3dView(frame: .zero, viewportId: viewportId)
        view.backgroundArgb = background
        return view
    }

    func updateUIView(_ uiView: MobScene3dView, context: Context) {
        uiView.backgroundArgb = background
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
        if viewportId.isEmpty {
            EmptyView()
        } else {
            MobScene3dRepresentable(viewportId: viewportId, background: background)
                .frame(width: width, height: height)
                .clipped()
        }
    }
}
