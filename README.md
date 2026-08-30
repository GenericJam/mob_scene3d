# mob_scene3d

Declarative 3D scenes for [Mob](https://mobframework.com) apps. One scene
description, rendered identically on iOS and Android through a shared
renderer — [Filament](https://github.com/google/filament) — with thin
per-platform shims for surface, vsync, and input.

**Status: design/scaffold.** No code yet. The plan lives in this README and
the bead tracker (`bd list`); conventions live in [AGENTS.md](AGENTS.md).

## Why this shape

The tempting design — wrap SceneKit on iOS and Filament/SceneView on
Android behind one API — fails on semantics: scene-graph shape, material
and lighting models, coordinate handedness, and animation systems all
diverge, and SceneKit is a sunset API. Separate per-platform plugins just
relocate that problem to every app author.

Instead the compat layer is *bought, not built*: Filament runs natively on
both platforms (Metal backend on iOS, GLES/Vulkan on Android, shipped as
prebuilt AAR and xcframework). Embedding it on both sides gives one
scene-graph semantics, one PBR material model, one asset pipeline, one
animation story — identical output on both platforms. Per-platform code
shrinks to plumbing:

| Shared (the plugin)                | Per-platform shims                     |
|------------------------------------|----------------------------------------|
| Scene IR (Elixir data)              | Surface: CAMetalLayer / SurfaceView    |
| IR → Filament applier (C++/NIF)     | Vsync: CADisplayLink / Choreographer   |
| glTF asset loading (gltfio)         | Touch input capture                    |
| Materials, lights, camera, anim     | Plugin/driver-tab registration         |
| Picking + introspection             | Lifecycle (background/resize)          |

## Architecture sketch

The BEAM holds the scene as **data** — a scene tree in assigns, like Mob's
UI trees — and diffs/patches it over the NIF wire. The Elixir side never
talks to Metal or GLES; it talks to one scene IR, and Filament makes that
IR mean the same thing everywhere.

```elixir
def render(assigns) do
  ~MOB"""
  <Scene3d id="board" on_pick={:piece_picked}>
    <Camera position={{0.0, 8.0, 6.0}} look_at={{0.0, 0.0, 0.0}} />
    <Light type="directional" intensity={100_000} direction={{0.5, -1.0, -0.5}} />
    <Environment ibl="env/studio" />
    <Model id="board" asset="board.glb" />
    <Model :for={p <- @pieces} id={p.id} asset="piece.glb"
           position={p.pos} rotation={p.rot} material_tint={p.color} />
  </Scene3d>
  """
end
```

(API shape illustrative — the scene IR design is bead `mob_scene3d-qh4`.)

## Agent-first, from day one

Every rendering feature ships with introspection, or it doesn't ship. The
3D equivalents of `Mob.Test.element_frames/1`:

- `Mob.Scene3d.pick(node, x, y)` → the entity under a point (ray pick)
- `Mob.Scene3d.scene(node)` → the applied scene graph as data
- Honest errors — `{:error, :no_entity_at_point}`, never a phantom `:ok`
- Region pixel sampling reuses Mob's existing `sample_region`

This is a hard requirement, not a nice-to-have: an agent that can query the
scene instead of squinting at screenshots is the whole reason to build 3D
on Mob rather than a game engine with an MCP bolted on.

## Asset formats

**glTF 2.0, binary flavor (`.glb`) — the only model/scene/animation format.**
It is Filament's native ingestion path (`gltfio`) and its PBR material
model matches Filament's exactly; it exports cleanly from Blender et al.
Do not accept FBX, OBJ, or USDZ into the pipeline — convert to glTF at
authoring time (USDZ in particular is an Apple-only pipeline dead end here).

- **Models / scenes / animations:** `.glb` (embedded buffers; single file
  per asset — no loose `.gltf` + sidecar files on device)
- **Textures:** KTX2 with Basis Universal supercompression (GPU-friendly on
  both Metal and GLES/Vulkan; PNG/JPEG inside a `.glb` work but transcode
  at load — fine for prototypes, KTX2 for anything shipping)
- **Image-based lighting:** environments precomputed with Filament's
  `cmgen` into KTX (a prefiltered specular cubemap + spherical-harmonics
  irradiance), shipped in `priv/` and referenced by name
- Asset prep is tooling, not app code: a `mix scene3d.assets` task wraps
  the conversions (bead `mob_scene3d-392`)

## Roadmap

Tracked in beads (`bd list`), roughly: Filament embedding spike on both
platforms → scene IR design → NIF wire + applier → surface/lifecycle shims
→ asset pipeline → picking/input → Mob.Test integration → camera helpers,
animation, docs + example app. Earlier estimate for the core: 2–3 weeks
single-human, 3–5 days for an agent fleet with device verification.

## Known costs, accepted deliberately

- Filament adds a few MB per platform and a **prebuilt-binary link step**
  (AAR / xcframework) to builds that are otherwise source-built — new
  territory for mob's zig/Gradle toolchain; de-risked first by bead `mob_scene3d-b9g`.
- Filament's release cadence is its own; pin exact versions in the build
  and record upgrades in the changelog.
