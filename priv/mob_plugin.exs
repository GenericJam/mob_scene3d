%{
  name: :mob_scene3d,
  mob_version: "~> 0.7",
  plugin_spec_version: 1,
  description:
    "Declarative 3D scenes rendered by Filament on both platforms — " <>
      "scene IR in assigns, diffed and patched over a dedicated NIF wire",

  # The NIF wire: shadow-registry patch validation + render-thread queues.
  # iOS: ObjC (Foundation only — the Filament applier itself is the ObjC++
  # MobScene3dView.mm, see host_requirements). Android: zig, bridging to the
  # Kotlin applier in MobScene3dBridge.kt via JNI.
  nifs: [
    %{module: :mob_scene3d_nif, native_dir: "priv/native/ios", lang: :objc, platform: :ios},
    %{module: :mob_scene3d_nif, native_dir: "priv/native/jni", lang: :zig, platform: :android}
  ],
  ui_components: [
    %{
      tag: "Scene3d",
      atom: :scene3d,
      props: [:id, :ir, :width, :height],
      # Registry key = Elixir module name, dots → underscores (the
      # Mob.Component convention).
      ios: %{view_module: "Mob_Scene3d_Viewport", swift_struct: "MobScene3dViewport"},
      android: %{composable: "MobScene3dViewport"}
    }
  ],
  ios: %{
    frameworks: ["Metal", "CoreVideo"],
    swift_files: ["priv/native/ios/MobScene3dViewport.swift"]
  },
  android: %{
    bridge_kt: "priv/native/android/MobScene3dBridge.kt",
    bridge_class: "io.mob.scene3d.MobScene3dBridge",
    # Pinned to the newest version published to Maven Central (GitHub
    # releases lead Maven — see decisions/2026-08-30-filament-spike.md).
    # Record any bump in the changelog.
    gradle_deps: [
      "com.google.android.filament:filament-android:1.75.1",
      "com.google.android.filament:gltfio-android:1.75.1",
      "com.google.android.filament:filament-utils-android:1.75.1"
    ]
  },
  host_requirements: [
    "Android: filament-utils-android ships Java-17 bytecode — the app's " <>
      "build.gradle needs compileOptions/kotlinOptions jvmTarget 17 " <>
      "(mob_new templates pin 1.8; see the spike decision record).",
    "iOS: there is no manifest mechanism for prebuilt static libraries yet " <>
      "(spike landmine 6), so the host wires two things in ios/build.zig " <>
      "(and build_device.zig): (1) an ObjC++ compile step for " <>
      "deps/mob_scene3d/priv/native/ios/MobScene3dView.mm with " <>
      "-I<vendored filament>/include, and (2) the Filament static archives " <>
      "from the vendored xcframeworks (scripts/fetch_filament_ios.sh) — " <>
      "simulator slices for build.zig, ios-arm64 slices for " <>
      "build_device.zig. The host bridging header must #import " <>
      "MobScene3dView.h and MobScene3dRuntime.h.",
    "Assets: .glb refs resolve against `config :mob_scene3d, asset_root: " <>
      "{otp_app, \"priv/scene3d_assets\"}` until the asset-pipeline bead " <>
      "(mob_scene3d-392) lands the final layout."
  ]
}
