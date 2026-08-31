# Asset pipeline: .glb-only validation, KTX2, cmgen IBL, conformance sweep

- Date: 2026-08-30
- Status: accepted
- Beads: `mob_scene3d-392` (pipeline), `mob_scene3d-l81` (scaffold pieces it rides on)
- Code: `lib/mob/scene3d/assets{,.ex,/glb.ex,/tools.ex}`,
  `lib/mix/tasks/scene3d.assets.ex`, `scripts/fetch_cmgen.sh`,
  `scripts/fetch_gltf_samples.sh`, `guides/assets.md`

## Context

README fixes the formats (.glb-only, KTX2 textures, cmgen IBL); this bead
builds the tooling that enforces them. The non-obvious calls:

## Decision

1. **Own GLB reader (pure Elixir), Khronos validator for conformance.**
   `Assets.Glb` parses the container header + JSON chunk with zero native
   deps — enough for *this repo's* judgments (embedded-buffer rule,
   extensionsRequired vs gltfio's supported set, budget stats). Spec
   conformance stays the official validator's job, invoked as
   `gltf-transform validate` (`@gltf-transform/cli`, which wraps
   KhronosGroup/glTF-Validator; on `$PATH` or via `npx --no-install`).
   We do not re-implement a validator, and we do not skip one silently:
   a missing CLI is an error naming `npm install -g @gltf-transform/cli`;
   `--no-validate` is an explicit, reported opt-out.

2. **The gltfio supported-extension list is a pipeline judgment, pinned.**
   `extensionsRequired` outside the list = error (asset cannot render);
   merely `extensionsUsed` = warning (loads, degrades). The list is tied to
   the Filament release pin and must be revisited on bumps — it encodes
   what OUR renderer loads, not what glTF allows. `EXT_meshopt_compression`
   is the proven-rejected example.

3. **Filament pin lives in `priv/filament-version`** (compile-time read by
   `Assets.Tools`, `@external_resource`-tracked, exercised by the
   packed-artifact regression) — priv/, never a repo-root dotfile, per the
   0.4.27/0.6.29 packaging lesson. `scripts/fetch_cmgen.sh` reads the same
   file, so the vendored tool and the error guidance cannot drift; a
   lockstep test pins compile-time == on-disk.

4. **cmgen is fetched, not committed.** It ships only inside Filament's
   ~100 MB per-OS release tgz; the script extracts the one binary into
   gitignored `vendor/filament-tools/` (mac + linux). Missing cmgen is an
   actionable `{:tool_missing, guidance}` — honest degradation, never a
   silent IBL skip. Note `cmgen --deploy` names outputs after the deploy
   *directory*; the directory name is the environment name scenes reference.

5. **KTX2 via `gltf-transform etc1s|uastc`, which needs KTX-Software's
   `ktx` encoder.** We pre-check for `ktx` and error with the release-page
   guidance (no homebrew formula exists) instead of surfacing
   gltf-transform's cryptic `command -v ktx` failure. Verified end-to-end
   (BoxTextured.glb → etc1s → validator-clean glb with `KHR_texture_basisu`
   required + `image/ktx2` payload).

6. **Conformance sweep = curated corpus, by script, results in the guide.**
   20 Khronos glTF-Sample-Assets models (+2 derived: Draco via
   `gltf-transform draco`, KTX2 via repacking the KTX-BasisU variant —
   the corpus ships neither as .glb) fetched by sparse-checkout into
   gitignored `vendor/gltf-samples/`. 22/22 pass; the table lives in
   `guides/assets.md`. Boundary: the sweep validates the *pipeline's
   judgments* (parse, validate, extension calls). Whether gltfio actually
   renders each model correctly needs the native applier + `scene/1`
   readback — that acceptance belongs to the plugin-core/Mob.Test lanes.

## Consequences

- Two external-tool dependencies (node/gltf-transform, ktx) for authoring
  workflows only — nothing on-device, nothing at library runtime. Tests
  that shell out are tool-gated with loud test_helper exclusions; CI
  installs gltf-transform + vendors cmgen so the real paths run there.
- Budget checks are conservative (file bytes, triangle estimate from
  accessor counts, KTX2-only) and configured per project
  (`.scene3d_assets.exs`); no built-in defaults to argue with.
- The supported-extension list will produce false "cannot render" errors
  if Filament gains loaders we haven't recorded — the sweep re-run on every
  Filament bump is the guard (documented in the guide).
