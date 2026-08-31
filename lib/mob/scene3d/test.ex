defmodule Mob.Scene3d.Test do
  @moduledoc """
  Agent/test-facing aliases for the 3D introspection surface, named and
  shaped like `Mob.Test` (node-first args) so 2D and 3D drive alike.

  The scene-IR decision record's post-review ruling asked for these to live
  on `Mob.Test` itself (`Mob.Test.scene/1`, `Mob.Test.pick/3`) — but mob
  core has no plugin-extension mechanism for `Mob.Test` today (it is a
  closed module in the `mob` dep; nothing to register into). Rather than
  monkey-patching, the aliases live here and the gap is filed against mob
  (see bead `mob_scene3d-0n7` notes). When mob grows the mechanism these
  delegate unchanged.

  All functions take the device's Erlang node first and return honest
  results — see `Mob.Scene3d` for full docs:

    * `scene/1,2` — the **applied** scene read back from the native applier
    * `pick/3,4` — synchronous-feel ray pick, `{:ok, id}` or
      `{:error, {:no_entity_at_point, x, y}}`
    * `sample_region/2,3` — GPU-readback pixel truth over the 3D viewport
      (window capture cannot see the surface), `Mob.Test.sample_color/2`'s
      stats shape
    * `frame_stats/1,2` — rolling frame timing + entity/renderable counts
  """

  defdelegate scene(node), to: Mob.Scene3d
  defdelegate scene(node, viewport_id), to: Mob.Scene3d
  defdelegate pick(node, x, y), to: Mob.Scene3d
  defdelegate pick(node, viewport_id, x, y), to: Mob.Scene3d
  defdelegate sample_region(node, rect), to: Mob.Scene3d
  defdelegate sample_region(node, viewport_id, rect), to: Mob.Scene3d
  defdelegate frame_stats(node), to: Mob.Scene3d
  defdelegate frame_stats(node, viewport_id), to: Mob.Scene3d
  defdelegate viewports(node), to: Mob.Scene3d
end
