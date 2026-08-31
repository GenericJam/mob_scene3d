# Asset pipeline

How 3D assets get from a DCC tool into a Mob app, and the rules
`mix scene3d.assets` enforces on the way. The format decisions themselves
are in the README (→ Asset formats); coordinate conventions live in
`decisions/2026-08-30-scene-ir.md` (right-handed, +Y up, −Z forward, meters).

## The one rule: `.glb`, embedded, one file per asset

glTF 2.0 **binary** (`.glb`, embedded buffers) is the only model / scene /
animation format the pipeline accepts. It is Filament's native ingestion
path (gltfio), its PBR material model matches Filament's exactly, and it
exports cleanly from Blender et al.

Everything else is rejected with the converter named in the error:

| You have | Do this at authoring time |
|---|---|
| loose `.gltf` (+ `.bin`/textures) | `npx @gltf-transform/cli cp model.gltf model.glb` — repacks embedded |
| FBX | Blender: File → Import → FBX, then export glTF Binary; or FBX2glTF |
| OBJ | Blender: File → Import → Wavefront, then export glTF Binary; or obj2gltf |
| USDZ | re-export the source scene as `.glb` (Blender 4.x imports USD). USDZ is an Apple-only pipeline dead end for a cross-platform renderer |

A `.glb` that references *external* URIs (sidecar `.bin` or image files)
fails the same rule: a device asset is exactly one file.

Assets live in `priv/scene3d_assets/` and are referenced by name
(scene-IR decision record, post-review ruling 3).

## `mix scene3d.assets`

```
mix scene3d.assets                       # validate everything under priv/scene3d_assets
mix scene3d.assets path/to/model.glb     # validate specific files/dirs
mix scene3d.assets --config budgets.exs  # enforce budgets (default: .scene3d_assets.exs)
mix scene3d.assets model.glb --ktx2 etc1s   # compress textures to KTX2/Basis
mix scene3d.assets --ibl studio.hdr --out priv/scene3d_assets/env/studio
```

Every model file found is judged four ways:

1. **Format** — `.glb` only, embedded buffers only (above).
2. **Khronos validation** — the official glTF validator, run via
   `gltf-transform validate` (`npm install -g @gltf-transform/cli`).
   Validator errors fail the asset; this catches broken exporters before
   a device ever sees the file.
3. **Extension support** — `extensionsRequired` outside Filament gltfio's
   supported set (see `Mob.Scene3d.Assets.gltfio_supported_extensions/0`)
   is an error: the asset *cannot* render. Unsupported entries that are
   merely in `extensionsUsed` warn: the asset loads, the feature degrades.
   The list is a pipeline judgment pinned to the Filament release in
   `priv/filament-version` — revisit it on every Filament bump.
4. **Budgets** — optional, from an `.exs` file returning a map:

   ```elixir
   # .scene3d_assets.exs — picked up automatically when present
   %{
     max_file_bytes: 5_000_000,
     max_triangles: 150_000,
     require_ktx2: true      # PNG/JPEG textures fail; see KTX2 below
   }
   ```

   Budgets exist because a `.glb` is GPU state: a 40 MB model that
   "works" in review is a multi-second load and a memory spike on a
   mid-range phone. Set budgets per project; the pipeline has no defaults.

## Blender export settings

Blender's glTF exporter (File → Export → glTF 2.0) with:

- **Format: glTF Binary (.glb)** — never "glTF Separate".
- **+Y Up: on** (default). Blender is +Z-up internally; the exporter
  converts to glTF's right-handed +Y-up, which is also Filament's and the
  scene IR's. Do not "fix" orientation in-app — fix the export.
- **Units: meters, scale 1.0.** Filament's photometric lighting (lux/lumens)
  only means anything at metric scale. Apply scale before export
  (Ctrl+A → All Transforms) so TRS stays shear-free.
- **Materials: Principled BSDF only.** The exporter maps Principled BSDF
  1:1 onto glTF metallic-roughness, which is exactly Filament's model.
  Anything else (node soups, Eevee-only tricks) silently drops.
- **Textures:** keep source images power-of-two. PNG/JPEG is fine for
  iteration (gltfio transcodes at load); run `--ktx2` before shipping.
- **Animations: on**, with named actions — clip names are the animation
  API surface (`%Animation{name: "tumble_4"}`), so name actions like the
  API will call them.
- **Compression: off** in Blender. If you want Draco, apply it as a
  pipeline step (`npx @gltf-transform/cli draco model.glb model.draco.glb`)
  where it's reproducible, not baked into the export.

## Textures: KTX2 / Basis Universal

PNG/JPEG inside a `.glb` decodes on the CPU and lives uncompressed in GPU
memory. KTX2 with Basis supercompression stays GPU-compressed on both
Metal and GLES/Vulkan — smaller downloads, ~4-8× less GPU memory, faster
uploads. gltfio transcodes KTX2 natively (`KHR_texture_basisu`; the
`libktxreader`/`libbasis_transcoder` static libs are already linked, per
the Filament spike).

```
mix scene3d.assets model.glb --ktx2 etc1s    # small, lossier — albedo, AO
mix scene3d.assets model.glb --ktx2 uastc    # high fidelity — normal maps
```

(Backed by `gltf-transform etc1s|uastc`, which shells out to KTX-Software's
`ktx` encoder. If the task reports it missing, install a release from
[KhronosGroup/KTX-Software](https://github.com/KhronosGroup/KTX-Software/releases) —
on macOS the Darwin `.pkg` puts `ktx` on `$PATH`; there is no homebrew
formula.)

Prototype with PNG, ship KTX2 — enforce with `require_ktx2: true` in the
budget config.

## Image-based lighting (cmgen)

The `<Environment ibl="env/studio" />` entry in a scene wants precomputed
IBL: a prefiltered specular cubemap plus spherical-harmonics irradiance.
Filament's `cmgen` tool computes both from an equirectangular panorama
(`.hdr`/`.exr`/`.png`, 2:1 aspect):

```
scripts/fetch_cmgen.sh                                    # one-time vendor (or have cmgen on $PATH)
mix scene3d.assets --ibl studio.hdr --out priv/scene3d_assets/env/studio
```

This writes `studio_ibl.ktx` (prefiltered specular + SH), `studio_skybox.ktx`
and `sh.txt` under the output directory — cmgen names files after the
deploy *directory*, so the directory name is the environment name scenes
reference. Outputs are KTX1 (cmgen's format for Filament's `ktxreader`);
that is expected, not a bug — the KTX2 rule above is for *model textures*.

`cmgen` ships in Filament's per-OS release archives; `scripts/fetch_cmgen.sh`
downloads the release pinned in `priv/filament-version` (the same pin the
renderer's AAR/xcframework uses — keep them in lockstep) and vendors the
binary at `vendor/filament-tools/cmgen` (gitignored). Without it, `--ibl`
fails with exactly that guidance — never a silent skip.

## Khronos conformance sweep

`scripts/fetch_gltf_samples.sh` pulls a curated subset of
[KhronosGroup/glTF-Sample-Assets](https://github.com/KhronosGroup/glTF-Sample-Assets)
(~20 models covering meshes, PBR materials, animation, skinning, morph
targets, KTX2/Basis textures, Draco, vertex colors, sparse accessors) into
`vendor/gltf-samples/` (gitignored — pulled by script, never committed) and
runs each through `mix scene3d.assets`. It validates **this pipeline's
judgments against the world's assets** — not our Blender exports alone, and
*not* gltfio runtime loading: whether Filament actually renders each model
correctly is the plugin core's territory (needs the native applier +
`Mob.Test.scene/1` readback) and is tracked there.

Results at Filament pin `v1.75.1`, gltf-transform 4.4.2 (2026-08-30):

**22 / 22 pass** (`mix scene3d.assets vendor/gltf-samples/models`):

| Model | Covers | Result |
|---|---|---|
| Box | minimal mesh | pass |
| BoxTextured | PNG texture | pass |
| BoxVertexColors | vertex colors | pass |
| Duck | classic textured mesh | pass |
| Duck.draco (derived) | Draco — requires `KHR_draco_mesh_compression` | pass |
| Avocado | PBR texture set | pass |
| DamagedHelmet | PBR showcase, JPEG textures | pass |
| BoomBox | PBR metal-rough | pass |
| MetalRoughSpheres | PBR factor matrix, 500k tris | pass |
| NormalTangentMirrorTest | normal maps / tangent space | pass |
| EmissiveStrengthTest | `KHR_materials_emissive_strength` | pass |
| SpecGlossVsMetalRough | legacy `KHR_materials_pbrSpecularGlossiness` (required) | pass |
| MosquitoInAmber | `KHR_materials_transmission` / `_ior` / `_volume` | pass |
| BoxAnimated | node TRS animation | pass |
| InterpolationTest | 9 clips, all interpolation modes | pass |
| AnimatedMorphCube | morph targets + animation | pass |
| MorphStressTest | 16 morph targets, 3 clips | pass |
| RiggedSimple | skinning | pass |
| CesiumMan | skinning + animation | pass |
| BrainStem | heavy skinning, 59 materials, 61k tris | pass |
| Fox | 3 named animation clips | pass |
| StainedGlassLamp.ktx2 (derived) | `KHR_texture_basisu` (required), clearcoat, variants | pass |

Known-unsupported, verified rejected (not silently accepted):

| Input | Judgment |
|---|---|
| `EXT_meshopt_compression` in `extensionsRequired` (e.g. `gltf-transform meshopt` output) | **error** — gltfio does not load meshopt; the message names the extension |
| loose `.gltf` (e.g. the corpus' FlightHelmet, which has no `.glb` variant) | **error** — `.glb`-only rule, message gives the repack command |
| any FBX / OBJ / USDZ | **error** — converter guidance per format |
| extensions merely *used* outside gltfio's set (e.g. `KHR_materials_iridescence`) | **warning** — loads, feature degrades |

Re-run the sweep after bumping the Filament pin or the supported-extension
list, and update this table in the same commit (AGENTS.md parity rule:
divergences are documented the moment they ship).
