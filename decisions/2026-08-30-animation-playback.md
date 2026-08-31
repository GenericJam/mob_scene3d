# Animation playback: declarative clips, completion events, settle readback

- Date: 2026-08-30
- Status: accepted
- Bead: `mob_scene3d-al6`
- Code: `lib/mob/scene3d/viewport.ex` (`on_animation_done` tag),
  both native appliers (`priv/native/android/MobScene3dBridge.kt`,
  `priv/native/ios/{mob_scene3d_nif.m,MobScene3dView.mm}`),
  `priv/native/jni/mob_scene3d_nif.zig` (`anim_done` delivery)

## Context

The scene-IR record fixed the animation control surface in prose
(`%Animation{name, play_id, loop, speed, paused, seek}`, replay = `play_id`
change, `{:animation_done, play_id}` on completion). This record fixes what
shipped when the honest stub became the real thing: the event tag grammar,
the version-skew posture, the unknown-clip validation split, the clip-clock
semantics the appliers implement, and the readback shape the Chopaat
cowrie-throw contract asserts against.

## Decisions

### 1. Completion events follow the pick precedent: `on_animation_done` tag

The `Scene3d` viewport takes `on_animation_done: tag` (atom, default
`:animation_done`) and a non-looping clip reaching its end delivers
`{tag, play_id}` to the owning screen's `handle_info/2`. The default makes
the out-of-box message exactly the scene-IR record's `{:animation_done,
play_id}` tuple as-is; scenes with several animated concerns can namespace
(`on_animation_done: :throw_settled`). Mechanics mirror picks: native
delivers `{:scene3d_animation_done, viewport, play_id}` to the viewport
component (the NIF caller), which re-tags and forwards to the screen pid
captured at `viewport/1` call time.

**Delivered at most once per `play_id`.** `play_id` is the correlation
token; a completed clip that is later `seek`-ed does not re-fire (the pose
repositions, the clock stays stopped). Running the clip again is a replay —
a new `play_id` — which fires its own completion.

### 2. Version skew: additive caps op, wire schema stays 1

`set_animation` was in the v1 op grammar from day one (the Elixir side
always emitted it; the applier declared it unsupported). Enabling it is
**additive**: the native `scene3d_caps` op list gains `"set_animation"`,
and the schema integer stays 1 — per the scene-IR versioning rule, a schema
bump is reserved for changes to the *meaning* of existing ops, and bumping
here would make an old Elixir library refuse a newer native applier that
speaks the full v1 grammar it needs. The skew matrix:

- new Elixir + old native: the caps guard refuses the patch with
  `{:error, {:unsupported, :set_animation}}` before the wire (host-tested);
  defense in depth, an old shadow receiving animation anyway rejects
  `[unsupported, animation]` — both loud.
- old Elixir + new native: never emits `set_animation`; the extra caps op
  and the new readback keys are ignored additively.

### 3. Unknown clip names: synchronous when knowable, async otherwise

The BEAM-thread shadow cannot know an asset's clip names before the render
thread has loaded the asset. Two-tier honesty (the same split `bad_asset`
has):

- After a load, the render thread registers the asset's clip names with the
  runtime (keyed by resolved asset path). From then on, a patch carrying an
  unknown name — `set_animation` or add/replace with `animation` set —
  rejects **synchronously** with `{:unknown_animation, id, name}`, whole
  patch, atomic reject-all.
- A patch that races the load (add_entity carrying an animation for a
  not-yet-loaded asset) validates render-side instead: the applier delivers
  an async `{:scene3d_error, viewport, [unknown_animation, id, name]}` to
  the owner AND records an error-shaped `animation_state` in the readback
  (`%{"name", "play_id", "error" => "unknown_animation"}`). Never a
  silently idle model.

### 4. Clip-clock semantics (both appliers, identical)

- The applier holds one clip clock per model (`clock`, seconds); the
  Animator is looked up from the gltfio instance per frame, so a
  material-clear instance rebuild keeps the clock (same `play_id`), while
  structural replace/remove resets it (the clip identity dies with the data
  payload).
- Per vsync tick: `clock += dt * speed` unless `paused` or done; the
  applied clip time is `clock % duration` when looping, `min(clock,
  duration)` otherwise (a finished `:once` clip holds its final frame —
  which is what "post-settle readback" reads). `applyAnimation` +
  `updateBoneMatrices` every tick.
- `dt` is clamped to 100 ms: a backgrounded app's clock freezes with the
  vsync loop instead of fast-forwarding clips to their end on resume.
- Completion needs a **running** clock: a paused clip seeked to (or past)
  the end holds the final pose without completing; unpausing fires the
  completion on the next tick.
- `seek` (absolute seconds) repositions the clock **without restarting**
  when it *changes* to a non-nil value under the same `play_id`; on a fresh
  `play_id` it is the starting offset. Seeking a done clip repositions the
  pose only (decision 1). Frame-exact scrubbing remains out of scope; the
  readback exposes the actual applied time so tests assert truth.
- Setting `animation: nil` stops driving the clip and leaves the pose where
  the clock left it (declaratively "no animation state" — resources
  untouched, no snap back to rest). A scene that wants the rest pose seeks
  to 0 paused.
- Surface re-attach (nav transition) rebuilds from the shadow: clips
  restart from `seek || 0` — the shadow holds intent, not native clocks.

### 5. Readback: native truth per model, plus named-node transforms

`scene/1` entities gain:

- `"animation_state"` — the applier's own clock, not the intent echoed
  back (`data.animation` remains the mirrored intent): `%{"name",
  "play_id", "time" (applied clip seconds), "done", "paused", "loop"}`, or
  the error shape from decision 3.
- `"nodes"` — `%{node_name => [16 floats, column-major world transform]}`
  for the model instance's *named* glTF nodes. Animation retargets nodes
  inside an asset (Chopaat's 32 tumble clips all retarget `shell_0..6`), so
  entity-level world transforms cannot answer "how did the shells land" —
  the named-node map is the settle-readback surface the manifest contract
  asserts against (local +Y in world = matrix column 1; aperture-up ⇔ its
  world-Y component ≤ −0.7, `tumble.py`'s classifier). Unnamed nodes are
  omitted; iOS wires an explicit `NameComponentManager` (the Android AAR
  creates one implicitly).

## Consequences

- "Play" remains a pure assign update end to end: no imperative NIF exists,
  coalescing is safe (three re-renders before a sender flush still diff to
  one `set_animation`), and a dropped frame cannot lose a completion — the
  clip clock lives render-side.
- The per-frame `applyAnimation` on paused/done clips is deliberate (cheap,
  and keeps the pose applied across seeks and instance rebuilds).
- The asset-clip-name registry never evicts (asset paths are stable per
  install; a few strings per asset). Registered names make the *common*
  Chopaat flow — model added first, animation set on a later roll — fail
  synchronously at `commit/3`, which is the assertable shape the bead's
  acceptance names.
- Cross-instance sharing caveat: two IR entities sharing one asset get
  independent clocks but gltfio node transforms are per-instance, so this
  is sound; the Chopaat scene uses one instance.
