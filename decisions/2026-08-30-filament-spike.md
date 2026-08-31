# 2026-08-30 — Filament embedding spike (bead mob_scene3d-b9g)

**Verdict: TBD**

Spike app: `s3d_spike/` on this branch (generated with released mob_new
0.4.28, `--local` against mob 0.7.37 / mob_dev 0.6.x checkouts). One added
screen hosts a native Filament view rendering a spinning beveled-cube
`.glb` (generated with python trimesh, `priv/models/bevel_cube.glb`) under
one directional light, on both platforms, through Mob's tier-2
native-view seam (`Mob.UI.native_view/2` + `Mob.Component` +
`MobNativeViewRegistry`).

## Question answers

### Exact version pinned

**Filament v1.75.1**, both platforms.

Landmine: GitHub releases lead Maven Central. v1.76.0 (2026-08-28) has all
GitHub release assets but its AARs were not on Maven Central as of
2026-08-30 (`maven-metadata.xml` tops out at 1.75.1). mob_dev's plugin
`gradle_deps` mechanism is Maven-Central/Google-repo-only (no manifest key
for a custom repo or local .aar), so **the pin must be the newest version
published to Maven Central**, not the newest GitHub release.

### How the artifacts are obtained

- **Android:** Maven Central coordinates, plain Gradle `implementation`
  deps (no manual AAR handling):
  `com.google.android.filament:{filament-android,gltfio-android,filament-utils-android}:1.75.1`
- **iOS:** direct download of the GitHub release asset
  `filament-v1.75.1-ios.tgz` (~30 MB, ~104 MB extracted), vendored into
  `s3d_spike/ios/vendor/filament/` (gitignored) by
  `s3d_spike/scripts/fetch_filament_ios.sh`. **Not** CocoaPods: mob apps
  have no `.xcodeproj` at all (the iOS build is `zig build` driving
  `xcrun swiftc`/`cc`), so CocoaPods has nothing to integrate with. The
  tgz contains 32 **xcframeworks of static archives** (`ios-arm64` device
  slice + `ios-arm64_x86_64-simulator` slice each) plus one shared
  `include/` tree.

### gltfio + utils (KTX2) included in prebuilts?

**Yes, on both platforms — no extra libs needed.**

- iOS tgz includes `libgltfio_core`, `libktxreader`, `libbasis_transcoder`
  (KTX2/BasisU transcode), `libdracodec` (Draco), `libuberarchive`
  (ubershader materials for gltfio), `libcamutils`, `libibl`, plus the core
  libs. The `gltfio/materials/uberarchive.h` header ships the
  `UBERARCHIVE_DEFAULT_DATA/SIZE` accessors for `createUbershaderProvider`.
- Android: `gltfio-android` and `filament-utils-android` AARs (utils
  includes the Kotlin `ModelViewer`, KTX1/KTX2 loading helpers, and
  `Utils.init()` which loads the JNI libs).

### Binary size delta

| Platform | Before | After | Delta |
|---|---|---|---|
| Android debug APK (arm64-v8a + armeabi-v7a + x86_64) | 77,553,781 B | TBD | TBD |
| iOS sim binary (arm64) | 7,982,664 B | TBD | TBD |
| iOS .app bundle | 8.3 MB | TBD | TBD |

Android AAR native payload for reference (uncompressed, per-ABI arm64):
libfilament-jni 3.15 MB + libgltfio-jni 2.84 MB + libfilament-utils-jni
1.44 MB ≈ 7.4 MB.

All three AARs' arm64 `.so`s have 16 KB-aligned PT_LOAD segments
(verified by ELF program-header inspection) — safe for Android 15+
16 KB-page devices; the CameraX-style alignment trap does not apply.

### Build-time delta

| Platform | Baseline `mob.deploy --native` | With Filament | Delta |
|---|---|---|---|
| Android (emulator, debug) | 3m14.6s | TBD | TBD |
| iOS sim | 3m29.6s | TBD | TBD |

### Integration landmines

1. **Maven Central lag** (above) — pin discipline must track Maven, not
   GitHub.
2. **`jvmTarget` bump required (Android).** `filament-utils-android` ships
   Java-17 bytecode (class-file major 61). The mob_new template pins
   `kotlinOptions { jvmTarget = '1.8' }`; Kotlin refuses to inline across
   that boundary. Fix: `jvmTarget = '17'` + matching `compileOptions`.
   Worked under the template's AGP 8.2.0 / Kotlin 1.9.22 / compileSdk 35.
3. **No `.xcodeproj` — Filament links through `ios/build.zig` edits**:
   - a new ObjC++ compile step (`xcrun -sdk iphonesimulator cc -std=gnu++17
     -fobjc-arc` + `-I<vendor>/include`) for the renderer `.mm`. Apple
     clang, not zig's bundled clang, same rationale as mob's ObjC steps
     (framework modulemaps). Filament headers compiled fine with `-Os` and
     ARC on the first attempt; no `-fno-rtti`/exceptions flags needed.
   - link step: add the static archives from each xcframework's simulator
     slice via `addFileArg` (so the zig cache tracks archive contents) +
     `-framework Metal -framework CoreVideo`. `-lc++` was already present
     (the BEAM needs it), which removes the usual C++-runtime linking
     hazard entirely.
   - the Swift registration shim rides the existing, supported
     `mob.exs config :mob_dev, project_swift_sources:` hook — no build.zig
     change needed for Swift.
   - bridging: swapped `-import-objc-header` to a project header that
     `#import`s mob's `MobDemo-Bridging-Header.h` (resolved via
     `-Xcc -I<mob_dir>/ios`) plus the spike view's ObjC interface.
4. **zstd double-link**: the OTP runtime already links `libzstd.a`;
   Filament also ships one. Listing Filament's after OTP's makes it inert
   (archive members load on demand) — no duplicate-symbol failures. TBD:
   confirmed by successful link.
5. **Gradle TLS + sandboxed agents**: Gradle's JVM does not trust the
   Claude-sandbox MITM proxy cert; first Filament fetch needs an
   unsandboxed build (or a pre-warmed `~/.gradle` cache). Not a mob issue,
   an agent-workflow issue — noting because it *will* recur for other
   agents adding the deps.
6. **Plugin packaging gap (future, iOS)**: there is no plugin-manifest key
   for shipping prebuilt static libs (`ios.frameworks` is system-framework
   names only; `cpp_archive` compiles *sources*). The real mob_scene3d
   plugin will need either a new manifest capability (vendored prebuilt
   .a paths) or a host-side fetch step à la `scripts/fetch_filament_ios.sh`.
   This is the single biggest open item for productionizing.

### Threading model observed

- **Filament's public API is single-threaded by contract**: every call
  must come from the thread that created the `Engine`. Filament internally
  spawns its own backend/driver thread (Metal/GLES command submission);
  `Renderer.beginFrame/render/endFrame` just enqueue to it.
- Spike shape on both platforms: Engine created on the **main/UI thread**;
  frames driven by the platform vsync callback on that same thread
  (`Choreographer.FrameCallback` / `CADisplayLink`), 60 fps sustained with
  a rotating transform updated per frame.
- **Implication for the future NIF applier (bead mob_scene3d-nhf)**: BEAM
  scheduler threads must NOT call Filament directly. The applier NIF
  should enqueue IR patches into a thread-safe queue consumed on the
  render thread (the vsync callback), or run a dedicated Filament thread
  and marshal everything onto it. This mirrors how the spike already
  crosses the boundary: BEAM → (props via set_root JSON / component
  update) → main thread → Filament. Events flow back through
  `mob_send_component_event` / `nativeDeliverComponentEvent`, which are
  safe from the render thread (the spike bounces to the main executor
  first on Android).

### README assumptions checked

- "Filament … shipped as prebuilt AAR and xcframework" — **confirmed**,
  including gltfio/KTX2 (the README's asset-pipeline plan needs no extra
  native builds).
- "adds a few MB per platform" — see size table. TBD verdict.
- "prebuilt-binary link step … new territory for mob's zig/Gradle
  toolchain" — Gradle side is trivial (Maven coords); zig side is ~40
  lines of build.zig template additions. The *plugin distribution* of the
  iOS static libs is the open problem (landmine 6), not the linking
  itself.
- The `<Scene3d>` tag design in the README will emit a compile warning per
  call site until the tag joins mob's `priv/tags/*.txt` (known tier-2
  wart, MOB_PLUGINS.md) — the spike used `Mob.UI.native_view/2` directly.

## Evidence

- `evidence/` — screenshots (+ motion evidence) from both platforms. TBD
- Device verification: TBD

## What the spike deliberately did not do

- No IBL/environment (directional light only — IBL needs `cmgen` output,
  which is bead mob_scene3d-392's asset-pipeline territory; `libibl` is
  linked and `libktxreader` is present for it).
- No touch input, no picking, no lifecycle (background/resize) handling
  beyond view attach/detach.
- No device (arm64) iOS build — pool sim only; `build_device.zig` needs
  the same ~40-line treatment with the `ios-arm64` slices.
- In-app registration rather than a real plugin package (the tier-2
  scaffold from `mix mob.new_plugin --tier 2` was inspected and matches
  what the spike hand-wired; see landmine 6 for the gap).
