# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
SemVer. `mix.exs` is the single source of truth for the version.

Release flow: bump `version:` in `mix.exs`, land the changelog entry in the
same commit, push to master — `release.yml` tags, creates the GitHub Release
with this file's section as the body, and publishes to Hex. See
[mob's RELEASE.md](https://github.com/GenericJam/mob/blob/master/RELEASE.md)
for the canonical process.

## [Unreleased]

### Added

- Name-scoped material overrides (bead `mob_scene3d-bqc`;
  `decisions/2026-08-31-scoped-material-overrides.md`): tint one named glTF
  material instead of the whole model — the Chopaat two-tone pawn contract
  (`pawn_body` takes the player color, `pawn_accent` stays authored ivory).
  - `%Mob.Scene3d.IR.Material{}` gains `scope: nil | "material_name"`
    (`nil` = every material instance, the previous behaviour and still the
    default); `Model.material` also accepts a list of `%Material{}` with
    distinct non-nil scopes for multiple simultaneous overrides.
  - Native appliers (both platforms) filter `materialInstances` by glTF
    material name; unknown scope names are honest errors —
    `{:unknown_material, id, name}` synchronously once the asset's material
    names are registered, async via `{:scene3d_error, ...}` when the check
    races the asset load (the unknown-animation two-tier honesty).
  - `scene/1` readback gains per-model `"material_state"`: applied truth
    per override (scope, applied params, matched instance names, or an
    `unknown_material` error marker).
  - Version skew: native caps gain an additive `"features"` list declaring
    `"material_scope"`; committing a scoped override against an applier
    without it degrades loudly with `{:unsupported, :material_scope}`
    (wire schema stays 1; unscoped overrides still ship to old appliers).
  - Whole-value replace semantics now hold for parameter removal: an
    override that stops touching a previously overridden parameter rebuilds
    the instance from the shared asset instead of silently keeping the old
    factor.

### Fixed

- iOS: embedded glTF textures now decode. The iOS applier's gltfio
  `ResourceLoader` had no `TextureProvider`s (the Android AAR wires stb/KTX2
  internally; the C++ path does not), so any textured material rendered
  black. Found by the two-tone pawn — the first textured asset through the
  applier; the earlier factor-only assets never exercised decoding. Both
  platforms now render embedded PNG/JPEG/KTX2 textures identically.

- glTF animation playback (bead `mob_scene3d-al6`;
  `decisions/2026-08-30-animation-playback.md`): the honest stub is now the
  real thing on both platforms.
  - `%Mob.Scene3d.IR.Animation{}` state drives gltfio's `Animator` on the
    render thread: named-clip selection within one `.glb`, replay via
    `play_id` change, `loop`, `speed`, `paused`, and absolute `seek`
    (repositions without restarting).
  - `on_animation_done: tag` on the viewport (default `:animation_done`) —
    a non-looping clip reaching its end delivers `{tag, play_id}` to the
    owning screen, at most once per `play_id` (the pick-event grammar,
    applied to completions).
  - `scene/1` readback gains native truth per model: `"animation_state"`
    (name, play_id, clip clock, done/paused/loop — or an
    `unknown_animation` error marker) and `"nodes"` (world transforms of
    the instance's named glTF nodes), so post-settle orientations of
    animation-retargeted nodes are assertable (the Chopaat cowrie-throw
    contract).
  - `set_animation` joins the native caps op list (additive; wire schema
    stays 1 per the versioning rules). Unknown clip names reject
    synchronously (`{:unknown_animation, id, name}`) once the asset's clip
    list is registered, and error asynchronously via `{:scene3d_error, ...}`
    when the name check races the asset load.

- Picking + agent introspection (beads `mob_scene3d-na8`, `mob_scene3d-0n7`;
  `decisions/2026-08-30-pick-introspection.md`):
  - `on_pick: tag` on the viewport — taps on `pickable: true` models ride
    Filament `View::pick` on the render thread and deliver
    `{tag, entity_id}` to the owning screen's `handle_info/2` (default
    `:pick`). Honest miss semantics: a tap that resolves to nothing
    pickable delivers no event (documented as a scene-IR addendum).
  - `Mob.Scene3d.pick/3` — synchronous-feel ray pick over the same native
    path; misses answer `{:error, {:no_entity_at_point, x, y}}`.
  - `Mob.Scene3d.scene/1`, `sample_region/2` (pixel truth via Filament
    `readPixels` GPU readback — window capture cannot see the surface;
    reduces through `Mob.Test.reduce_rgba/3`), `frame_stats/1` (rolling
    avg/p95 frame ms, dropped/frame counts since last query,
    entity/renderable counts), and `viewports/0,1` — all node-first like
    `Mob.Test`, with device-local viewport-id forms.
  - `Mob.Scene3d.Test` aliases (`Mob.Test`-side aliases await a mob-core
    plugin-extension seam; gap filed on bead `mob_scene3d-0n7`).
  - New NIFs `scene3d_pick/2`, `scene3d_sample/2`, `scene3d_frame_stats/2`,
    `scene3d_viewports/0` on both platforms; absent native halves degrade
    as `{:error, :nif_not_loaded}`.

- Plugin core (beads `mob_scene3d-t05`, `mob_scene3d-nhf`): the
  `Mob.Scene3d` surface (scene IR in assigns, diff against last committed
  IR, versioned JSON wire with caps-based version-skew guards), the
  `Mob.Scene3d.Viewport` component (teardown rides mob #111 component
  reclamation), and the native NIF wire + Filament scene appliers on both
  platforms — shadow-registry patch validation on the BEAM thread
  (atomic reject-all, honest error taxonomy), ops applied between frames
  on the render thread (Choreographer / CADisplayLink), renderer fully
  rebuildable from the shadow on view re-attach. Filament pinned at
  1.75.1 on both platforms (newest version published to Maven Central).
  Animation ops are honestly unsupported (`{:error, {:unsupported,
  :set_animation}}` via the caps guard); Environment is accepted but
  IBL/skybox KTX loading awaits the asset pipeline (`mob_scene3d-392`).
- `mix scene3d.assets` (bead `mob_scene3d-392`) — asset validation and
  preparation: `.glb`-only ingestion (loose `.gltf`/FBX/OBJ/USDZ rejected
  with actionable converter guidance), Khronos glTF validation via
  `gltf-transform validate`, optional budget checks, KTX2/Basis texture
  compression (`--ktx2 etc1s|uastc`), and IBL environment precomputation
  via Filament's `cmgen` (`--ibl env.hdr`, vendored by
  `scripts/fetch_cmgen.sh` against the `priv/filament-version` pin).
  Authoring workflow + the 22/22 Khronos sample-asset conformance sweep
  documented in `guides/assets.md`.
- Repo scaffold mirroring the mob repos (bead `mob_scene3d-l81`): CI
  (`test.yml`), release automation (`release.yml` — mix.exs version on
  master → tag → GitHub Release → Hex publish, each step idempotent),
  two-tier `.githooks/pre-push`, Hex package metadata, and the
  packed-artifact regression test (`mix hex.build --unpack` + isolated
  compile + compile-time-resource probe — the mob_new 0.4.27 /
  mob_dev 0.6.29 packaging lesson, permanent).
