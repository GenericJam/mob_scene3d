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
