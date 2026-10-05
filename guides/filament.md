# Filament, the renderer under mob_scene3d

`mob_scene3d` embeds [Google's Filament renderer][filament-repo] on
both platforms — Metal on iOS, GLES/Vulkan on Android. Every visual
concept a scene exposes (materials, lights, IBL, glTF, animation,
picking) maps directly to Filament's model. If a knob surprises you,
the fastest path to understanding is Filament's own docs at the
matching section; this guide is a link map, not a re-explanation.

[filament-repo]: https://github.com/google/filament

## Reference

- [Filament home page][filament-home] — landing page and demos
- [Filament repo (google/filament)][filament-repo] — source, releases,
  issue tracker
- [Filament core documentation][core-docs] — the "big PDF" — the
  authoritative explanation of the PBR material model, image-based
  lighting, and the rendering pipeline
- [Materials guide][materials-guide] — the material definition
  language and per-material parameters
- [Android bindings source][android-src] — the Java / Kotlin surface
  `mob_scene3d` binds against on Android (there is no published Javadoc
  site; the source is the reference)
- [gltfio component][gltfio] — glTF asset loading, the ingestion path
  we use for every `.glb`

[filament-home]: https://google.github.io/filament/
[core-docs]: https://google.github.io/filament/Filament.md.html
[materials-guide]: https://google.github.io/filament/Materials.md.html
[android-src]: https://github.com/google/filament/tree/main/android
[gltfio]: https://github.com/google/filament/tree/main/libs/gltfio

## Version pinning

Filament ships prebuilt binaries (`.aar` for Android, `.xcframework`
for iOS) — cross-platform parity depends on both sides linking against
the *same* Filament release. Pin exact versions in both build files
and record every upgrade in the changelog. See the top of
`android/build.gradle` and the corresponding iOS build fragments for
the version currently linked.

## The scene IR maps to Filament, one-to-one

| Scene IR              | Filament concept                                  |
| --------------------- | ------------------------------------------------- |
| `Entity`              | Filament `Entity` (+ components)                  |
| `Transform`           | `TransformManager` component                      |
| `Model` (asset `.glb`)| `gltfio` asset instance + `RenderableManager`     |
| `Material` override   | Per-instance `MaterialInstance` parameter set     |
| `Light`               | `LightManager` component (directional, point, …)  |
| `Environment` (IBL)   | `IndirectLight` + `Skybox` — **not wired yet**: commits are refused with `{:unsupported, :environment}` |
| `Camera`              | Filament `Camera`                                 |
| Animation channel     | `gltfio` `Animator` channel                       |
| Pick                  | `View::pick` ray query                            |
| `sample_region`       | `Renderer::readPixels` GPU readback               |

The IR does not model Filament's ownership rules (thread-affine,
resource-owning objects); that is the job of the C++ applier reading
the IR — see [decisions/2026-08-30-filament-spike.md][spike-decision]
for why the seam is where it is and what it costs.

[spike-decision]: https://github.com/GenericJam/mob_scene3d/blob/master/decisions/2026-08-30-filament-spike.md

## When to read Filament docs

- **Material feels wrong** — Materials.md.html is the authoritative
  reference for base color, metallic, roughness, clear coat, sheen,
  anisotropy, transmission, refraction; not every parameter is
  exposed via the IR yet — see PLAN.md for the ordering — and the
  Filament page tells you what each one does before it gets exposed.
- **Lighting looks off** — Filament.md.html has the PBR + IBL model.
  A specular highlight that reads as chalky is almost always an IBL
  mismatch (wrong prefilter, missing spherical harmonics).
- **New glTF asset does not load or misbehaves** — gltfio's readme
  explains which glTF 2.0 extensions are supported, and the Filament
  changelog records new extension support per release.
- **Performance question** — Filament.md.html has a "Rendering" section
  on culling, batching, LODs, and the frame graph.

## What mob_scene3d owns vs what Filament owns

Filament owns everything below the scene IR — GPU state, threading,
resource lifetimes, driver quirks. `mob_scene3d` owns the IR shape,
the diff/patch protocol, the NIF wire, agent readback, asset packaging,
and the per-platform surface / lifecycle shims. Bugs in the rendered
output almost always live on Filament's side of that line; bugs in
"my scene changed and the picture did not" almost always live on
mob_scene3d's side.
