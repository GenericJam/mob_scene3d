# PLAN — what to wrap next, and what not to

- Date: 2026-09-03
- Status: proposed
- Beads: `mob_scene3d-qxb` (texture override), `mob_scene3d-eih`
  (primitive assets), `mob_scene3d-962` (procedural geometry, deferred —
  blocked by `-eih`)
- Scope: the shape-and-texture question — how far to take the Filament
  binding, and in what order

This answers a specific question: *how much work is it to wrap all of
Filament, is that practical, and what makes sense to wrap to get the basics
of shape and texture?* The short answers are: a lot, no, and much less than
you would expect — because the current design already avoids needing to.

## Where things actually stand

Measured against the tree at the time of writing, not from the README
(which was stale — see the note at the end):

| | |
|---|---|
| NIF surface | 8 functions (`scene3d_apply`, `_scene`, `_pick`, `_sample`, `_frame_stats`, `_caps`, `_destroy`, `_viewports`) |
| Wire op vocabulary | 12 ops, schema v1 (`Mob.Scene3d.Wire`) |
| Entity kinds | `Model` \| `Camera` \| `Light` \| `Environment` \| `nil` (group) |
| Geometry sources | glTF/`.glb` only — no procedural mesh path |
| Material overrides | `base_color`, `metallic`, `roughness`, `emissive`, optional `scope` |
| iOS applier | `priv/native/ios/MobScene3dView.mm`, ~1450 lines ObjC++ against Filament's C++ API |
| Android applier | `priv/native/android/MobScene3dBridge.kt`, ~1841 lines Kotlin against Filament's Java bindings |

Chopaat — the driving consumer — ships board, pawns and cowrie shells as
`.glb` and drives them with `Transform` and `Animation`. That is the
workflow the design intends, and it works.

## The framing: do not wrap Filament

Filament v1.75.1's app-facing surface is roughly **1,100 public method
declarations** across 39 core headers plus gltfio's 10 — and that excludes
the 50 `filament/backend` headers, which are driver-level and were never
candidates.

Size is the least of it. A 1:1 wrap is the wrong *shape* for three reasons:

1. **Filament is stateful, thread-affine and resource-owning.** `Engine`,
   `SwapChain`, `MaterialInstance`, `VertexBuffer` have explicit lifetimes
   and must be touched on the render thread. Exposing them as NIF handles
   puts GPU resource lifetime under BEAM process and GC semantics. The
   shadow-registry-plus-patch-queue design exists precisely to prevent
   that, and it should not be given up.
2. **Most of that surface is builder and lifecycle plumbing** with no
   meaning to a scene description. Wrapping it means exporting
   `Builder::build(Engine&)` chains across a JSON boundary.
3. **Every op costs twice.** The two appliers are independent
   implementations in different languages against different Filament
   bindings — ~3,300 lines between them for 12 ops. Add the repo's rule
   that no rendering feature merges without its introspection counterpart,
   and the marginal op is three pieces of work, not one.

The scene IR is the right call and this plan does not revisit it.

## What is actually missing for shape and texture

Three gaps, ranked by value per unit of work:

1. **Runtime textures.** Texture providers are wired only for *asset
   decoding* (`image/png`, `image/jpeg`, `image/ktx2` at load).
   Runtime material overrides reach exactly four parameters —
   `baseColorFactor`, `metallicFactor`, `roughnessFactor`, `emissive`.
   You can tint a surface; you cannot put an image on it from Elixir.
   No texture swap, no decal, no dynamic label.
2. **Procedural geometry.** No `VertexBuffer` / `IndexBuffer` /
   `RenderableManager` on either side — all geometry is gltfio. Fine for
   authored content; blocking for anything generated at runtime.
3. **Custom materials.** Ubershader only (`uberarchive` on iOS,
   `UbershaderProvider` on Android); no `filamat`, so no runtime material
   compilation and no custom shaders.

## Recommendations

### 1. Add a texture reference to the material override — do this one

`mob_scene3d-qxb` (P1)

Extend `IR.Material` with a texture ref (`base_color_texture:
"assets/wood.ktx2"`), resolved through the existing `TextureProvider`s and
applied with `setParameter` on the `MaterialInstance`.

Highest value per line available. It reuses the loader, the KTX2 pipeline
and the scoped-override mechanism that already exist, and it unlocks the
whole "same mesh, different skin" class — piece colours, team variants,
board themes — that authored-only textures cannot express.

One new op field, both appliers, plus `scene` readback so the applied
texture is visible to introspection.

### 2. Ship primitive `.glb` assets instead of a primitive op

`mob_scene3d-eih` (P2)

For cube / sphere / plane / cylinder, ship a handful of authored `.glb`
files in `priv/` rather than adding geometry ops. Zero native work, zero
new wire surface, and they flow through the asset pipeline that is already
validated (22/22 conformance sweep).

This is the cheap 80% of "basic shapes". Take it before considering item 3.

### 3. Defer procedural geometry until something needs it

`mob_scene3d-962` (P3, blocked by `mob_scene3d-eih`)

`add_mesh` taking packed vertex/index binaries is a contained addition, but
it introduces a new *resource lifetime* to manage on the render thread —
materially more work than a texture parameter, and a new class of leak.
Worth doing when a real consumer needs generated geometry (a data plot, a
runtime-sized board); not worth doing speculatively.

### 4. Do not add custom materials

No bead — deliberately unscheduled.

`filamat` on-device is a large lift and the ubershader covers PBR. Revisit
only if a specific effect forces it, and record the forcing case.

## Non-goals

- A general Filament binding.
- FBX / OBJ / USDZ ingestion (settled in
  `decisions/2026-08-30-asset-pipeline.md`).
- Anything that puts a native GPU resource handle in BEAM-owned state.

## Importing these beads

The Dolt database is gitignored and did not come with a fresh clone, so
these three were created in a local database and exported to
`.beads/plan-2026-09-03.jsonl` — a **partial** export containing only this
plan's issues, not the project backlog. To land them in the canonical
tracker:

```
bd import .beads/plan-2026-09-03.jsonl
```

## Note on documentation drift

The README described the repo as "design/scaffold, no code yet" and showed
an illustrative `~MOB` sigil API, while glTF animation, scoped material
overrides and embedded-texture decoding had all shipped and the real API is
`Mob.Scene3d.viewport/1` taking an `:ir` prop. Corrected in the same change
that added this file; the lesson is the one already in AGENTS.md — the
artifact is the handoff, so stale docs are a defect, not cosmetics.
