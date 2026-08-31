# Host-side verification battery for beads mob_scene3d-na8 + mob_scene3d-0n7.
#
# Usage:
#   S3D_NODE=s3d_spike_android_buildpool1@127.0.0.1 \
#     mise exec -- elixir --name probe_s3d@127.0.0.1 --cookie mob_secret \
#     -S mix run scripts/probe_introspection.exs
#
# Prints labelled readback values — the values ARE the evidence.

node = String.to_atom(System.fetch_env!("S3D_NODE"))

IO.inspect(Node.connect(node), label: "connect")
IO.inspect(Mob.Test.screen(node), label: "screen")

if Mob.Test.screen(node) != S3dSpike.SceneIrScreen do
  Mob.Test.tap(node, :open_scene_ir)
  Mob.Test.settle(node)
  IO.inspect(Mob.Test.screen(node), label: "screen after nav")
end

# Give the surface a beat to attach + render first frames.
Process.sleep(1_500)

IO.inspect(Mob.Scene3d.viewports(node), label: "viewports")

{:ok, scene} = Mob.Scene3d.scene(node)

for {id, entity} <- scene["entities"] do
  world = entity["world_transform"]

  IO.inspect(
    %{
      kind: entity["kind"],
      status: entity["status"],
      pickable: entity["pickable"],
      world_translation: world && Enum.slice(world, 12, 3)
    },
    label: "scene[#{id}]"
  )
end

# ── pick/3: probe (pickable), decoy (not pickable), background ─────────────
# Geometry: camera (0, 0.25, 1.6) fov_y 40°, viewport 340x420dp → ≈361 dp/m
# at z=0. Probe center ≈ (62, 228)dp, decoy ≈ (278, 228)dp.
IO.inspect(Mob.Scene3d.pick(node, 62, 228), label: "pick probe (62,228)")
IO.inspect(Mob.Scene3d.pick(node, 278, 228), label: "pick decoy (278,228)")
IO.inspect(Mob.Scene3d.pick(node, 170, 30), label: "pick background (170,30)")

# ── sample_region: probe body vs background ────────────────────────────────
IO.inspect(Mob.Scene3d.sample_region(node, {52, 218, 20, 20}), label: "sample probe")
IO.inspect(Mob.Scene3d.sample_region(node, {160, 20, 20, 20}), label: "sample background")
IO.inspect(Mob.Scene3d.sample_region(node, {-500, -500, 20, 20}), label: "sample offscreen")

# ── frame_stats: at rest, then under a per-frame move loop ─────────────────
{:ok, _} = Mob.Scene3d.frame_stats(node)
Process.sleep(2_000)
IO.inspect(Mob.Scene3d.frame_stats(node), label: "frame_stats at rest (2s window)")

Mob.Test.send_message(node, {:s3d, :spin_loop, 120})
Process.sleep(2_500)
IO.inspect(Mob.Scene3d.frame_stats(node), label: "frame_stats after 120-frame spin loop")

# ── tap → {tag, id} event via real input injection ─────────────────────────
frames = Mob.Test.element_frames(node)
IO.inspect(Map.get(frames, "probe_vp"), label: "viewport frame")

case Map.get(frames, "probe_vp") do
  {vx, vy, _w, _h} ->
    IO.inspect(Mob.Test.assigns(node).picks, label: "picks before taps")
    Mob.Test.tap_xy(node, vx + 62, vy + 228)
    Process.sleep(1_000)
    picks_after_probe = Mob.Test.assigns(node).picks
    IO.inspect(picks_after_probe, label: "picks after probe tap")
    Mob.Test.tap_xy(node, vx + 278, vy + 228)
    Mob.Test.tap_xy(node, vx + 170, vy + 30)
    Process.sleep(1_000)
    IO.inspect(Mob.Test.assigns(node).picks, label: "picks after decoy+bg taps (miss = unchanged)")

  nil ->
    IO.puts("viewport frame not tracked — tap via absolute coords manually")
end

# ── honest errors ───────────────────────────────────────────────────────────
IO.inspect(Mob.Scene3d.scene(node, "ghost_vp"), label: "scene on unknown viewport")
IO.inspect(Mob.Scene3d.pick(node, "ghost_vp", 1, 1), label: "pick on unknown viewport")
