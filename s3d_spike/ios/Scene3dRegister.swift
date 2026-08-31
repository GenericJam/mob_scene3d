// Scene3dRegister.swift — Filament embedding spike (bead mob_scene3d-b9g).
//
// Registers the Filament native view under the Mob.Component registry key
// for S3dSpike.Scene3dComponent. Called from AppDelegate right after
// mob_register_plugins() (same startup slot the generated plugin
// bootstrap uses).
import SwiftUI

private struct Scene3dFilamentRepresentable: UIViewRepresentable {
    let assetPath: String
    let onReady: () -> Void

    func makeUIView(context: Context) -> Scene3dFilamentView {
        Scene3dFilamentView(frame: .zero, assetPath: assetPath, onReady: onReady)
    }

    func updateUIView(_ uiView: Scene3dFilamentView, context: Context) {}
}

@_cdecl("s3d_register_scene3d")
public func s3dRegisterScene3d() {
    MobNativeViewRegistry.shared.register("S3dSpike_Scene3dComponent") { props, send in
        guard let assetPath = props["asset_path"] as? String else {
            return AnyView(EmptyView())
        }
        let w = (props["width"] as? NSNumber)?.doubleValue ?? 340
        let h = (props["height"] as? NSNumber)?.doubleValue ?? 420
        return AnyView(
            Scene3dFilamentRepresentable(
                assetPath: assetPath,
                onReady: { send("ready", ["frames": 1]) }
            )
            .frame(width: w, height: h)
            .clipped()
        )
    }
}
