# Agent Readback

The three primitives an agent needs to verify a 3D scene from the outside,
without a screenshot:

1. **`pick/N`** — "what entity is at pixel `(x, y)`?"
2. **`project/N`** — "where in the viewport is entity `X` right now?"
3. **`sample_region/N`** — "what colour is actually rendered at pixel
   `(x, y, w, h)`?"

Each is authoritative — they read from the same render-thread state
Filament uses to draw the frame — and each returns a small, exact answer.
Together they close the loop: an agent projects the entity it expects to
see, samples the region around the projection, and asserts the pixels
match. No image diffing, no pixel-by-pixel comparison, no vibes.

## `pick` — screen → entity

Ray-picks the scene at a viewport-local pixel coordinate (dp/pt, origin
top-left). Returns the entity id under the pixel or the honest miss
`{:error, {:no_entity_at_point, x, y}}`. Only models with `pickable:
true` participate; a hit on a non-pickable model reads as a miss so the
API doesn't leak the pickable set.

```elixir
{:ok, "shell_4"} = Mob.Scene3d.pick(node, "shells_cup", 186, 250)
```

Runs on the render thread (`View::pick`), so the answer is what the app
actually shows — a touch at those pixels would deliver
`{:pick, "shell_4"}` to the owning screen.

## `project` — entity → screen

Returns viewport-local pixel coordinates for an entity's origin under
the currently-applied camera. Pair it with `sample_region` around the
result to assert the entity is where you think it is.

```elixir
{:ok, %{x: px, y: py, depth: z, in_frame?: true}} =
  Mob.Scene3d.project(node, "shells_cup", "shell_4", {372, 500})
```

`viewport_size` is `{width, height}` in dp/pt — the same values the
screen declared with `Mob.Scene3d.viewport(id: ..., width: w, height:
h)`. The Elixir side needs them to convert NDC to pixels. `depth` is
NDC z ∈ [-1, 1] (near plane → -1, far plane → +1); `in_frame?` is
`true` when the entity is in the visible box AND in front of the camera
plane. An off-screen entity still returns coords so the agent can
reframe (move the camera, scroll into view) rather than guess.

Errors are shaped like the rest of the API:

- `{:error, {:no_entity, id}}` — no such entity in the applied scene
- `{:error, {:no_camera, viewport_id}}` — the scene has no camera
- `{:error, {:no_viewport, id}}` — nothing attached at that id
- `{:error, :singular_camera}` — the camera's world transform is not
  invertible (a degenerate scale — never happens for a mob-generated
  transform, kept as a distinct case so a corrupted patch surfaces
  loudly instead of guessing)

## `sample_region` — screen → pixels

Filament `readPixels` over a viewport-local pt rect. Returns
`{:ok, %{average, dominant, dominant_share, distinct, pixels}}` shaped
like `Mob.Test.sample_color/2`. Window capture cannot see the 3D
surface (the `SurfaceView` / `CAMetalLayer` blindspot) — this is the
pixel-truth path for 3D.

```elixir
{:ok, %{dominant: color, dominant_share: share}} =
  Mob.Scene3d.sample_region(node, "shells_cup", {px - 16, py - 16, 32, 32})

assert share > 0.6  # the shell dominates a 32×32 patch around its origin
```

Read pixels are post lighting, tone-mapping and exposure — assert on
`:dominant`/`:dominant_share` with tolerance, never bit-exact against
base colours.

## The triple in one flow

```elixir
# 1. Find where the entity should be.
{:ok, %{x: px, y: py, in_frame?: true}} =
  Mob.Scene3d.project(node, viewport_id, entity_id, {w, h})

# 2. Sample the pixels there.
{:ok, %{dominant_share: share}} =
  Mob.Scene3d.sample_region(node, viewport_id, {px - 16, py - 16, 32, 32})

# 3. Optional: pick to confirm the top-most entity is what you expect.
{:ok, ^entity_id} = Mob.Scene3d.pick(node, viewport_id, px, py)

# The entity is where the scene says it is, the pixels there are the
# colour we expect, and a touch at those pixels reaches the same entity.
assert share > 0.6
```

Any of the three failing is a bug worth writing up: a `pick` that
disagrees with the touch path, a `project` that lands somewhere
`sample_region` can't see, or a `sample_region` share below what the
mesh should dominate — those are the three failure modes the render
pipeline actually has, and this triple catches all of them.
