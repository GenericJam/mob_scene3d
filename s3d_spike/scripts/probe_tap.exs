# Tap → {tag, entity_id} event verification (bead na8). Finds the native
# surface's window frame from the platform view tree, taps the probe, the
# decoy, and the background, and reads the :picks assign after each.
node = String.to_atom(System.fetch_env!("S3D_NODE"))
true = Node.connect(node)

if Mob.Test.screen(node) != S3dSpike.SceneIrScreen do
  Mob.Test.tap(node, :open_scene_ir)
  Mob.Test.settle(node)
end

Process.sleep(1_000)

flat = Mob.Test.view_tree_flat(node)

surface =
  Enum.find(flat, fn view ->
    type = view["type"] || ""
    String.contains?(type, "Scene3dView") or String.contains?(type, "MobScene3d")
  end)

IO.inspect(surface && Map.take(surface, ["type", "frame"]), label: "surface view")

%{"frame" => %{"x" => vx, "y" => vy, "w" => vw, "h" => vh}} = surface
IO.inspect({vx, vy, vw, vh}, label: "viewport window frame (dp)")

read_picks = fn -> Mob.Test.assigns(node).picks end

IO.inspect(read_picks.(), label: "picks initially")

# Probe center in viewport-local dp ≈ (62, 228); decoy ≈ (278, 228).
Mob.Test.tap_xy(node, vx + 62, vy + 228)
Process.sleep(1_200)
after_probe = read_picks.()
IO.inspect(after_probe, label: "picks after probe tap (expect [\"probe\" | _])")

Mob.Test.tap_xy(node, vx + 278, vy + 228)
Process.sleep(1_200)
after_decoy = read_picks.()
IO.inspect(after_decoy, label: "picks after decoy tap (expect unchanged)")

Mob.Test.tap_xy(node, vx + 170, vy + 30)
Process.sleep(1_200)
after_background = read_picks.()
IO.inspect(after_background, label: "picks after background tap (expect unchanged)")

IO.puts(
  "VERDICT: probe_hit=#{List.first(after_probe) == "probe"} " <>
    "decoy_silent=#{after_decoy == after_probe} background_silent=#{after_background == after_probe}"
)
