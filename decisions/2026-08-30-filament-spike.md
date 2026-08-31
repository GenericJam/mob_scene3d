# 2026-08-30 — Filament embedding spike (bead mob_scene3d-b9g)

**Verdict: feasible-with-caveats.** Filament renders the same .glb,
visibly identical, inside a Mob-hosted native view on both platforms; the
link step is unremarkable on Android (Maven AARs) and ~40 lines of
build.zig on iOS. The two caveats that matter for the plugin plan:
(1) there is no plugin-manifest mechanism yet for shipping the iOS
prebuilt static libs (landmine 6); (2) shadows are broken under
Metal-on-simulator and must be feature-gated there (landmine 7).

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
| Android debug APK (arm64-v8a + armeabi-v7a + x86_64) | 77,553,781 B | 89,215,317 B | **+11,661,536 B (+11.1 MiB)** |
| iOS sim binary (arm64, -dead_strip) | 7,982,664 B | 11,342,024 B | **+3,359,360 B (+3.2 MiB)** |
| iOS .app bundle | 8,464 KiB | 11,748 KiB | +3,284 KiB |

The Android delta covers three ABIs (≈7.4 MB uncompressed native per
arm64, APK-compressed). An AAB/per-ABI split would deliver roughly a
third of that to a given device. The iOS static-lib + dead_strip path is
markedly cheaper than the AAR path — 3.2 MB for
filament+backend+gltfio+ktxreader+basis+draco+uberarchive.

Android AAR native payload for reference (uncompressed, per-ABI arm64):
libfilament-jni 3.15 MB + libgltfio-jni 2.84 MB + libfilament-utils-jni
1.44 MB ≈ 7.4 MB.

All three AARs' arm64 `.so`s have 16 KB-aligned PT_LOAD segments
(verified by ELF program-header inspection) — safe for Android 15+
16 KB-page devices; the CameraX-style alignment trap does not apply.

### Build-time delta

| Platform | Baseline `mob.deploy --native` | With Filament | Delta |
|---|---|---|---|
| Android (emulator, debug) | 3m14.6s (gradle portion 21s) | 2m28.2s (gradle portion 58s, incl. first AAR fetch) | gradle +37s first build; steady-state delta ≈ +10–20s (dex/merge of 3 AARs) |
| iOS sim | 3m29.6s (cold-ish first deploy) | 2m43.5s / 2m46.2s (warm zig cache) | added .mm compile ≈1s; the bigger static link adds single-digit seconds |

Caveat: `mob.deploy --native` times are dominated by OTP sync/BEAM push
and zig/gradle caching, so these are not clean-room A/B numbers; the
honest summary is **Filament adds negligible build time on iOS and tens
of seconds of Gradle work on Android** — the link step is not a
build-time hazard on either platform.

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
   (archive members load on demand) — confirmed, the link succeeds with
   both present and the app runs.
5. **Gradle TLS behind Cloudflare WARP**: this machine's traffic is
   MITM'd by a Cloudflare Gateway CA that curl/git/node trust via env
   vars (`SSL_CERT_FILE` etc.) but the JVM does not — Gradle's first
   fetch of the Filament POMs died with `PKIX path building failed`.
   Fix: import `/Library/Application Support/Cloudflare/installed_cert.pem`
   into a copy of the JDK cacerts and pass
   `GRADLE_OPTS="-Djavax.net.ssl.trustStore=... -DtrustStorePassword=changeit"`.
   Will recur for any new Maven dependency on this setup.
6. **Plugin packaging gap (future, iOS)**: there is no plugin-manifest key
   for shipping prebuilt static libs (`ios.frameworks` is system-framework
   names only; `cpp_archive` compiles *sources*). The real mob_scene3d
   plugin will need either a new manifest capability (vendored prebuilt
   .a paths) or a host-side fetch step à la `scripts/fetch_filament_ios.sh`.
   This is the single biggest open item for productionizing.
7. **Metal-on-simulator shadow pass blacks out the model.** With
   `castShadows(true)` + default `setShadowingEnabled(true)`, the model
   renders with a correct silhouette but a fully black surface on the iOS
   simulator (Metal FL2): the shadow pass zeroes the direct-light term.
   Disabling shadowing restores correct PBR shading. Android (GLES,
   emulator) renders shadows fine with identical scene parameters. The
   future applier should feature-gate shadows on `TARGET_OS_SIMULATOR`
   (and re-verify on physical iOS hardware — deliberately out of scope
   here).
8. **Transform-composition trap with ModelViewer (Android)**:
   `transformToUnitCube()` centers the model at (0,0,-4) — in front of
   ModelViewer's origin-based camera — not at the origin. A per-frame
   spin must compose `base * rotation` (rotate in model space), not
   `rotation * base`, or the model orbits the camera and leaves the
   frame. The C++ side (own camera, model centered at origin) does not
   have this trap.

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

All under `evidence/` on this branch. Verification followed the
"effects, not exit codes" rule: after each deploy — process present
(`pidof` / `launchctl list`), Erlang node connected from a host probe,
`Mob.Test.screen/1` answering, `Mob.Test.tap(node, :open_scene3d)`
navigating (screen module read back), then screenshots.

- `android_emu_fixed_t{1,2}.png` — Android (redroid13 x86_64 emulator,
  buildpool2): lit beveled cube on skybox, different rotation angles 1 s
  apart (motion).
- `android_emu_scene3d_t*.png` / `android_emu_screencap_t*.png` — the
  pre-fix orbit bug captures (landmine 8), kept as the record; also
  demonstrates that Mob's in-process `Mob.Test.screenshot/1` returns the
  view-hierarchy without the SurfaceView contents (byte-identical PNGs
  while the surface animated) — **3D evidence must come from compositor
  captures** (`adb screencap` / `simctl io screenshot`), which matters
  for the future Mob.Test integration bead.
- `ios_sim_final_t{0,2}.png` — iOS pool sim (pool-ios-0, iPhone,
  iOS 26 runtime): lit cube, two rotation angles.
- `ios_sim_scene3d_t*.png` — the pre-fix all-black shadow captures
  (landmine 7).
- `ios_sim_spin.mp4` — 5 s screen recording of the spin (motion proof).
- `android_moto_scene3d_t{0,1,2}.png` + `android_moto_spin.mp4` (5 s
  screenrecord) — **physical acceptance** on the Moto g power 2021
  (ZY22DP6HFL, leased via the clarity pool as `s3d-spike@build`,
  released after): lit spinning cube, self-shadowing visible —
  `castShadows(true)` works on real Android hardware, reinforcing that
  landmine 7 is simulator-specific.
- Same asset, same skybox color, same directional light on all three
  targets; output visually identical modulo the iOS shadow gate.

Deploy to the physical Moto (`mix mob.deploy --native --device
ZY22DP6HFL`, warm caches): 2m10.8s. App uninstalled from the Moto, the
pool emulator, and the pool sim after evidence capture; all three leases
released.

## What the spike deliberately did not do

- No IBL/environment (directional light only — IBL needs `cmgen` output,
  which is bead mob_scene3d-392's asset-pipeline territory; `libibl` is
  linked and `libktxreader` is present for it).
- No touch input, no picking, no lifecycle (background/resize) handling
  beyond view attach/detach.
- No device (arm64) iOS build — pool sim only; `build_device.zig` needs
  the same ~40-line treatment with the `ios-arm64` slices. Shadows on
  physical iOS Metal therefore remain unverified (landmine 7).
- In-app registration rather than a real plugin package (the tier-2
  scaffold from `mix mob.new_plugin --tier 2` was inspected and matches
  what the spike hand-wired; see landmine 6 for the gap).
