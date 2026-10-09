%{
  name: :mob_scene3d,
  mob_version: "~> 0.9",
  plugin_spec_version: 1,
  description:
    "Declarative 3D scenes rendered by Filament on both platforms — " <>
      "scene IR in assigns, diffed and patched over a dedicated NIF wire",

  # On-device proof for `mix mob.selftest` / mob_ci: scene3d_caps/0 plus a
  # patch the native shadow registry must reject (Mob.Plugin.SelfTest).
  selftest: Mob.Scene3d.SelfTest,

  # The NIF wire: shadow-registry patch validation + render-thread queues.
  # iOS: the ObjC NIF (Foundation only) and the ObjC++ Filament renderer
  # (MobScene3dView.mm) are cross-compiled by mob_dev into one
  # libmob_scene3d_nif.a (lang: :cpp_archive, mob_dev >= 0.7.21). Filament's
  # headers and static libraries come from its pinned iOS release tarball
  # (`prebuilt:`), which mob_dev downloads once into ~/.mob/cache, checks
  # against the sha256 and links per target: simulator slices for the sim
  # build, ios-arm64 for device builds and `mix mob.release --ios`.
  # Android: zig, bridging to the Kotlin applier in MobScene3dBridge.kt via JNI.
  nifs: [
    %{
      module: :mob_scene3d_nif,
      lang: :cpp_archive,
      platform: :ios,
      sources: ["priv/native/ios/mob_scene3d_nif.m", "priv/native/ios/MobScene3dView.mm"],
      includes: ["priv/native/ios", {:prebuilt, "filament/include"}],
      # .m → the C driver (cflags), .mm → clang++ (cxxflags).
      cflags: [
        "-fobjc-arc",
        "-Os",
        "-ffunction-sections",
        "-fdata-sections",
        "-DSTATIC_ERLANG_NIF_LIBNAME=mob_scene3d_nif"
      ],
      cxxflags: ["-std=gnu++17", "-fobjc-arc", "-Os", "-ffunction-sections", "-fdata-sections"],
      nm_symbol: "mob_scene3d_nif_nif_init",
      # Same Filament release as the Android AARs below and priv/filament-version.
      prebuilt: %{
        url:
          "https://github.com/google/filament/releases/download/v1.75.1/filament-v1.75.1-ios.tgz",
        sha256: "afdfdccfb0870a667c73400d9e81e5ec69c8604d867fc4430b9fbfe72934ade3",
        static_libs:
          Map.new(
            [ios_sim: "ios-arm64_x86_64-simulator", ios_device: "ios-arm64"],
            fn {target, slice} ->
              {target,
               for lib <-
                     ~w(filament backend filabridge filaflat utils geometry smol-v ibl image
                        gltfio_core ktxreader basis_transcoder meshoptimizer dracodec
                        uberarchive uberzlib stb zstd perfetto abseil) do
                 "filament/lib/lib#{lib}.xcframework/#{slice}/lib#{lib}.a"
               end}
            end
          )
      }
    },
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
      # composable is the registry key; factory opts into mob_dev's generated
      # MobPluginBootstrap registration (qualified with the bridge package).
      android: %{composable: "Mob_Scene3d_Viewport", factory: "MobScene3dViewport"}
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
    "Android: needs mob_dev >= 0.6.31 (AndroidBootstrap `factory` support), " <>
      "which generates the MobNativeViewRegistry registration for the " <>
      "viewport — no hand registration in MainActivity.",
    "Android: filament-utils-android ships Java-17 bytecode — the app's " <>
      "build.gradle needs compileOptions/kotlinOptions jvmTarget 17 " <>
      "(mob_new templates pin 1.8; see the spike decision record).",
    "Assets: .glb refs resolve against `config :mob_scene3d, asset_root: " <>
      "{otp_app, \"priv/scene3d_assets\"}` until the asset-pipeline bead " <>
      "(mob_scene3d-392) lands the final layout."
  ]
}
