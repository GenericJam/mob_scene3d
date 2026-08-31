# Picking + agent introspection: touch → ray pick, scene/pixel/perf readback

- Date: 2026-08-30
- Status: accepted
- Beads: `mob_scene3d-na8` (input + picking), `mob_scene3d-0n7`
  (introspection + Mob.Test integration)
- Code: `lib/mob/scene3d.ex` (`pick/3,4`, `scene/1,2`, `sample_region/2,3`,
  `frame_stats/1,2`, `viewports/0,1`), `lib/mob/scene3d/test.ex`,
  `lib/mob/scene3d/viewport.ex` (`on_pick` tag), both native appliers

## Context

The scene-IR record fixed the introspection contract in prose; this record
fixes what shipped: the pick event grammar, the miss semantics (addendum in
the scene-IR record), the coordinate conventions, the pixel-truth path, and
the perf readback added to bead 0n7's scope. Per AGENTS.md these are feature
gates: rendering without introspection does not merge.

## Decisions

### Pick events: `on_pick` tag, configurable, delivered to the screen

Per the scene-IR post-review ruling: the `Scene3d` viewport takes
`on_pick: tag` (atom, default `:pick`) and a tap on a `pickable: true`
model delivers `{tag, entity_id}` to the owning screen's `handle_info/2`.
Mechanics: the platform shim captures the tap (GestureDetector /
UITapGestureRecognizer), issues the same render-thread `View::pick` the
query path uses, and native delivers `{:scene3d_pick_event, viewport,
entity}` to the `Mob.Scene3d.Viewport` component process (the NIF caller),
which re-tags and forwards to the screen pid captured at `viewport/1` call
time (`render/1` runs in the screen server process — `self()` there is the
screen).

Filament's pick is GPU-async: the callback resolves a frame or two after
the tap. Events are delivered when resolved — fine for tap semantics, and
`pick/3` awaits the same resolution.

**Miss semantics** are ruled in the scene-IR record's addendum: miss = no
event; non-pickable hit = miss; `pick/3` answers misses with
`{:error, {:no_entity_at_point, x, y}}`.

### Coordinates: viewport-local dp/pt, origin top-left

All Elixir-surface coordinates (`pick/3` x/y, `sample_region/2` rects) are
**viewport-local logical units** (Android dp / iOS pt), origin top-left —
the same units the viewport's `width`/`height` props use, so tests compute
probe points from the IR + viewport geometry without knowing device scale.
The shims scale by density/contentScaleFactor and flip to Filament's
bottom-left GL convention internally. Nothing at the API surface speaks
window coordinates: the 3D scene doesn't know where the viewport sits in
the 2D tree (compose `Mob.Test.element_frames/1` when window-space matters).

### Introspection surface: node-first, `Mob.Test`-shaped

`Mob.Scene3d` exposes both calling shapes:

- **Host-side (agents/tests)**: `scene(node)`, `pick(node, x, y)`,
  `sample_region(node, rect)`, `frame_stats(node)` — node-first like
  `Mob.Test`, `:rpc` into the device where the local form runs. With no
  viewport id the single attached viewport is resolved
  (`{:error, {:multiple_viewports, ids}}` otherwise); explicit-id arities
  exist for multi-viewport screens.
- **Device-local**: same functions, viewport-id-first (binary), awaiting
  the async native reply with an honest `:timeout`.

**`Mob.Test.scene/1` / `Mob.Test.pick/3` aliases (post-review ruling 2)
could not land on `Mob.Test`**: mob core has no plugin-extension mechanism
for `Mob.Test` (closed module in the dep — nothing to register into, and
a plugin cannot define functions in mob's namespace without monkey-patching
the beam file). The aliases live on **`Mob.Scene3d.Test`** with identical
shapes; the gap is filed on bead `mob_scene3d-0n7` as a candidate mob
issue. When mob grows the mechanism, these delegate unchanged.

### Pixel truth: GPU readback, not window capture

The spike proved `Mob.Test.screenshot/1` (window capture) returns
byte-identical PNGs while the 3D surface animates — SurfaceView /
CAMetalLayer content is composited outside the window's render tree, so
**window capture is structurally blind to the 3D viewport**, and
`Mob.Test.sample_color/2` (which samples the window render) inherits the
blindspot. `Mob.Scene3d.sample_region/2` therefore reads pixels with
Filament `Renderer::readPixels` on the render thread, between `render()`
and `endFrame()` — the framebuffer itself, the strongest possible evidence.

- Raw RGBA crosses the wire (base64 over the existing JSON deliver path)
  and reduces **on the Elixir side through `Mob.Test.reduce_rgba/3`** — one
  reducer for 2D and 3D pixel truth, so the stats shape (`0xAARRGGBB`
  `:average` / `:dominant` / `:dominant_share` / `:distinct` / `:pixels`)
  is identical by construction, and the two native appliers cannot drift
  in stats arithmetic (they ship bytes, not conclusions).
- Payload is `w × h × scale² × 4` bytes: probe-sized rects, not
  full-viewport captures (same discipline as mob's `sample_color/2`).

**Tolerance posture — assert dominance, compare with tolerance, never
bit-exact against IR colors.** The readback is the *displayed* image:
base colors pass through lighting, physical exposure, ACES tone mapping
and sRGB encoding before hitting the framebuffer, so an IR
`base_color: {0.8, 0.1, 0.1}` does not sample as `0xFFCC1A1A` anywhere.
What IS assertable:

- **flatness**: a solid-color region (the empty-scene skybox) samples with
  `dominant_share` ≈ 1.0;
- **channel ordering**: a red-tinted probe's dominant has R ≫ G,B; the
  skybox background is dark and blue-leaning;
- **change detection**: the same rect before/after a material or
  visibility patch moves by an unmistakable margin;
- **cross-platform**: iOS and Android agree on the above *qualitatively*;
  exact bytes differ (backend dithering, tone-mapping precision) — the
  parity harness (bead `mob_scene3d-zn8`) consumes this primitive with
  tolerance bands, not equality. Measured device values are recorded in
  the bead evidence notes.

### Perf readback: numbers, not vibes (0n7 scope note)

`Mob.Scene3d.frame_stats/1` reads a ring buffer the render thread fills at
vsync (120 deltas ≈ 2 s @ 60 Hz — one subtraction and a store per frame,
nothing allocated):

- `avg_ms` / `p95_ms` — frame-to-frame delta over the window (vsync-paced,
  so a healthy idle viewport reads ≈ the refresh period, not 0);
- `dropped` — deltas > 1.5× the display refresh period since the last
  query (query-to-query counters, so agents diff without bookkeeping);
- `frames` — frames actually rendered since the last query;
- `entities` (applier registry size) and `renderables` (Filament
  `Scene::getRenderableCount()`).

Draw-call counts are not exposed: Filament aggregates them per-View
internally and the stable public counter is renderables; if a real need
appears, `Renderer::getFrameInfoHistory` is the extension point.

### Wire additions

New NIFs (absent halves degrade as `{:error, :nif_not_loaded}`, the mob
#111 posture — an old native build predating this lane refuses loudly):

| NIF | reply | async delivery |
|---|---|---|
| `scene3d_pick(vid, query_json)` | ok / `no_viewport` | `{:scene3d_pick, vid, req, json}` — `{"entity":id}` or `{"miss":true}` |
| `scene3d_sample(vid, query_json)` | ok / `no_viewport` | `{:scene3d_sample, vid, req, json}` — `{"width","height","rgba"}` or `{"error":["offscreen"]}` |
| `scene3d_frame_stats(vid, req)` | ok / `no_viewport` | `{:scene3d_frame_stats, vid, req, json}` |
| `scene3d_viewports()` | `{"viewports":[ids]}` sync | — |

Touch picks deliver `{:scene3d_pick_event, vid, entity_id}` to the
viewport owner. Queries carry the requesting pid, captured at NIF-call
time, so `pick/3` from any process (rpc-spawned included) gets its own
reply — the owner pid is only for events.

## Consequences

- Picking participation is decided at resolution time from the applier
  registry (the shims re-check `pickable` when the GPU answers), so a
  `set_pickable` landing between tap and resolution uses the newest truth.
- The iOS pick callback runs off the captured snapshot (renderable → id
  map built at issue time) and never touches Filament or UIKit — safe on
  whatever thread Filament dispatches it. Android resolves on the main
  thread via the pick handler. Both deliver through `enif_send`
  (thread-safe).
- `sample_region` waits for a rendered frame; a covered/backgrounded
  viewport times out honestly instead of returning stale pixels.
- `Mob.Scene3d.Test` is a naming shim; its existence is a signpost for the
  mob-core `Mob.Test` extension gap, not an architecture.
