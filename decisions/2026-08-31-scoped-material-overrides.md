# Name-scoped material overrides: tint one glTF material, not the model

- Date: 2026-08-31
- Status: accepted
- Bead: `mob_scene3d-bqc`
- Code: `lib/mob/scene3d/ir.ex` (`%Material{scope: ...}`, `Model.material`
  list form), `lib/mob/scene3d/wire.ex` (wire shape, caps `features`),
  `lib/mob/scene3d.ex` (skew guard), both native appliers
  (`priv/native/android/MobScene3dBridge.kt`,
  `priv/native/ios/MobScene3dView.mm` + `mob_scene3d_nif.m`)

## Context

Chopaat's asset round 3 (chopaat-xix) ships a two-material pawn:
`pawn_body` (player-tintable, near-white) and `pawn_accent` (authored
ivory that must NOT take the tint). The v1 `%Material{}` override applied
to **every** material instance of a model's gltfio instance, so the
runtime player tint repainted the ivory accent too. The scene-IR decision
record foresaw this ("per-primitive targeting … is a foreseen extension:
same mechanism"); this record ships it as **name** scoping, which is the
form the driving consumer needs — glTF material names are the authored,
stable identity, and gltfio carries them onto each `MaterialInstance` on
both platforms.

## Decision

### IR (additive)

- `%Material{}` gains `scope: nil | "material_name"`. `nil` (default)
  keeps today's semantics: the override hits every material instance.
  A name hits only instances whose glTF material name matches.
- `Model.material` now also accepts a **list** of `%Material{}` for
  multiple simultaneous overrides (tint `pawn_body` + emissive on
  `pawn_accent`). In list form every scope must be a distinct, non-nil
  name — an unscoped entry inside a list would make apply order
  load-bearing, which whole-value replace semantics forbid. `validate/1`
  errors: `{:invalid_scope, v}`, `:empty_material_list`,
  `:unscoped_material_in_list`, `{:duplicate_material_scope, name}`.
- Single-override back-compat is total: a bare `%Material{}` (scope nil)
  validates, diffs, encodes, and applies exactly as before.

### Wire + version skew

- The material JSON object gains `"scope"` (null | string); a list
  encodes as a JSON array of those objects. `{:set_material, id, value}`
  stays the op — no new op name, the payload is extended.
- **Caps gain `"features"`** — an additive capability list for grammar
  extensions that ride existing ops, decoded to a MapSet (absent key =
  empty set, i.e. an older native half). This applier declares
  `"material_scope"`.
- The commit guard refuses any patch using a scoped override (non-nil
  scope anywhere, or list form anywhere — including inside
  add/replace-entity payloads) against caps not declaring
  `"material_scope"`: `{:error, {:unsupported, :material_scope}}`.
  Rationale: an old applier would parse the object form, ignore the
  unknown `"scope"` key, and tint every instance — the exact bug scoping
  exists to fix, in silent form. Degraded loudly instead (mob #111
  posture). Unscoped overrides still ship to old appliers unguarded —
  their wire shape and semantics are unchanged.
- Known race (same one animation-name checks accept): caps are consulted
  per commit, so a native half swapped between check and apply could see
  a scoped payload. Object-with-scope degrades to whole-model tint on an
  old Android/iOS applier; list form degrades to "no override applied" —
  both bounded by the caps guard's window, as elsewhere in the protocol.

### Native applier mechanics (both platforms, mirrored)

- On asset load the applier registers the asset's glTF material names
  with the shadow runtime (the animation-clip-name registry's twin).
- **Two-tier unknown-name honesty**: once names are registered, a scoped
  override naming a material the asset doesn't have rejects
  **synchronously** at patch validation —
  `{:unknown_material, entity_id, name}`, whole patch rejected. Before
  the asset loads (the async race), the render thread applies, finds no
  matching instance, and delivers the same error via
  `{:scene3d_error, ...}` plus an error marker in the readback. Never a
  silently mis-tinted or unstyled model.
- Application: overrides normalize to a list; each entry filters
  `materialInstances` by name (scope nil = all) and pokes the standard
  gltfio factors, exactly as before.
- **In-place vs rebuild**: overridden instances' authored factors are
  unrecoverable (no gltfio readback), so a new override that stops
  touching a previously overridden (scope, parameter) pair triggers an
  instance rebuild from the shared asset before re-applying — whole-value
  replace semantics now hold for parameter *removal* too (previously an
  un-set parameter silently kept its old override). In-place application
  is kept for the hot paths (same-scope value changes, parameter
  supersets) via a conservative coverage check; clearing (`material:
  nil`) rebuilds as before.

### Readback

`scene/1` entities gain `"material_state"` (models with an applied
override): one entry per override —
`%{"scope" => name | nil, "applied" => [param names], "instances" =>
[matched glTF material names]}`, or
`%{"scope" => name, "error" => "unknown_material"}`. Applied truth from
the applier, not intent echoed back (`data.material` remains the mirrored
intent) — an agent asserts the pawn tint touched `pawn_body` and left
`pawn_accent` untouched without sampling a pixel; `sample_region`
remains the pixel-truth acceptance.

## Consequences

- Chopaat's follow-up is consumer-side only: scope the pawn tint (and
  selection emissive / target markers) to `"pawn_body"` in
  `Chopaat.Scene.pawn_entities` — tracked on chopaat-xix's notes.
- The caps `features` list is the extension mechanism for future
  payload-level grammar growth (per-primitive index targeting would be
  `"material_target_index"`, etc.) — op list for new ops, features for
  new payload shapes, schema for changed meanings.
- The rebuild-on-shrink rule means high-frequency override *removal*
  churns instances (abandoned until asset teardown, per the existing
  policy); high-frequency value changes stay in-place and cheap.
