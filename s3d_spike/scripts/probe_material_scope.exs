# Host-side verification battery for bead mob_scene3d-bqc (name-scoped
# material overrides): the Chopaat two-tone pawn contract.
#
# Usage:
#   S3D_NODE=s3d_spike_android_buildpool1@127.0.0.1 \
#     mise exec -- elixir --name probe_s3d@127.0.0.1 --cookie mob_secret \
#     -S mix run scripts/probe_material_scope.exs
#
# Prints labelled readback values — the values ARE the evidence.

alias Mob.Scene3d.IR.Material

node = String.to_atom(System.fetch_env!("S3D_NODE"))
vp = "pawn_vp"

ok = fn label -> IO.puts("OK   #{label}") end
fail = fn label -> IO.puts("FAIL #{label}") end
check = fn cond?, label -> if cond?, do: ok.(label), else: fail.(label) end

channels = fn argb ->
  {Bitwise.band(Bitwise.bsr(argb, 16), 0xFF), Bitwise.band(Bitwise.bsr(argb, 8), 0xFF),
   Bitwise.band(argb, 0xFF)}
end

IO.inspect(Node.connect(node), label: "connect")
IO.inspect(Mob.Test.screen(node), label: "screen")

if Mob.Test.screen(node) != S3dSpike.PawnScreen do
  if Mob.Test.screen(node) != S3dSpike.HomeScreen do
    Mob.Test.send_message(node, {:tap, :back})
    Mob.Test.settle(node)
  end

  Mob.Test.tap(node, :open_pawn)
  Mob.Test.settle(node)
  IO.inspect(Mob.Test.screen(node), label: "screen after nav")
end

# Give the surface a beat to attach, load pawn.glb, render first frames.
Process.sleep(2_000)

IO.inspect(Mob.Scene3d.viewports(node), label: "viewports")

# ── caps declare the feature ────────────────────────────────────────────────
{:ok, caps} = :rpc.call(node, Mob.Scene3d, :caps, [])
IO.inspect(caps.features, label: "caps features")
check.(MapSet.member?(caps.features, "material_scope"), "caps declare material_scope")

# ── readback: applied override truth ────────────────────────────────────────
{:ok, scene} = Mob.Scene3d.scene(node, vp)
pawn = scene["entities"]["pawn"]
IO.inspect(pawn["status"], label: "pawn status")
IO.inspect(pawn["material_state"], label: "pawn material_state (scoped tint)")

check.(pawn["status"] == "ready", "pawn asset loaded")

check.(
  match?(
    [%{"scope" => "pawn_body", "instances" => ["pawn_body"]}],
    pawn["material_state"]
  ),
  "material_state: tint applied to pawn_body ONLY"
)

# ── pixel truth: tinted body vs authored-ivory accent ───────────────────────
# Geometry (PawnScreen): pawn scaled 8x at origin, camera (0, 0.16, 0.6)
# fov_y 40 over 340x420dp. Body fills the lower half; the ivory accent cap
# sits around y = 25..50 dp at center-x.
strip =
  for y <- [30, 45, 90, 150, 210, 270, 320] do
    {:ok, %{average: avg}} = Mob.Scene3d.sample_region(node, vp, {162, y, 16, 16})
    {y, channels.(avg)}
  end

IO.inspect(strip, label: "vertical strip (y, {r,g,b}) at x=162..178")

{:ok, body} = Mob.Scene3d.sample_region(node, vp, {150, 280, 40, 30})
{:ok, accent} = Mob.Scene3d.sample_region(node, vp, {158, 30, 24, 16})
{:ok, background} = Mob.Scene3d.sample_region(node, vp, {10, 395, 20, 20})

{br, bg, bb} = channels.(body.average)
{ar, ag, ab} = channels.(accent.average)
IO.inspect({br, bg, bb}, label: "body avg rgb (expect vermilion tint)")
IO.inspect({ar, ag, ab}, label: "accent avg rgb (expect authored ivory)")
IO.inspect(channels.(background.average), label: "background avg rgb")

check.(br > 140 and br / max(bg, 1) > 1.8, "body region shows the scoped tint (red-dominant)")

check.(
  ag > 120 and ar / max(ag, 1) < 1.4 and ag / max(ab, 1) > 1.1,
  "accent region stays ivory (warm neutral, NOT tinted)"
)

# ── multiple simultaneous overrides: tint body + emissive accent ────────────
materials = [
  %Material{base_color: {0.8, 0.15, 0.02, 1.0}, scope: "pawn_body"},
  %Material{emissive: {0.0, 0.25, 0.0}, scope: "pawn_accent"}
]

Mob.Test.send_message(node, {:s3d_mat, :set, materials})
Process.sleep(800)

{:ok, scene2} = Mob.Scene3d.scene(node, vp)
state2 = scene2["entities"]["pawn"]["material_state"]
IO.inspect(state2, label: "material_state (body tint + accent emissive)")

check.(
  Enum.any?(state2, &match?(%{"scope" => "pawn_body", "instances" => ["pawn_body"]}, &1)) and
    Enum.any?(
      state2,
      &match?(%{"scope" => "pawn_accent", "instances" => ["pawn_accent"]}, &1)
    ),
  "two simultaneous scoped overrides applied to their own instances"
)

{:ok, accent_glow} = Mob.Scene3d.sample_region(node, vp, {158, 30, 24, 16})
{gr, gg, gb} = channels.(accent_glow.average)
IO.inspect({gr, gg, gb}, label: "accent avg rgb with green emissive")
check.(gg > ag, "accent emissive raised the green channel")

# ── shrink back to body-only (rebuild path restores authored accent) ────────
Mob.Test.send_message(
  node,
  {:s3d_mat, :set, %Material{base_color: {0.8, 0.15, 0.02, 1.0}, scope: "pawn_body"}}
)

Process.sleep(800)
{:ok, accent_back} = Mob.Scene3d.sample_region(node, vp, {158, 30, 24, 16})
{rr, rg, rb} = channels.(accent_back.average)
IO.inspect({rr, rg, rb}, label: "accent avg rgb after emissive removed (rebuild)")

check.(
  abs(rr - ar) < 24 and abs(rg - ag) < 24 and abs(rb - ab) < 24,
  "removing the accent override rebuilt back to authored ivory"
)

{:ok, body_back} = Mob.Scene3d.sample_region(node, vp, {150, 280, 40, 30})
{br2, bg2, _bb2} = channels.(body_back.average)
check.(br2 > 140 and br2 / max(bg2, 1) > 1.8, "body tint survived the rebuild")

# ── honest errors ───────────────────────────────────────────────────────────
# Synchronous unknown_material: pawn.glb is loaded, so its material names
# are registered — the shadow rejects a bogus scope before the wire.
me = self()

bad = [
  {:set_material, "pawn",
   [%Material{base_color: {0.0, 0.0, 1.0, 1.0}, scope: "pawn_bogus"}]}
]

Mob.Test.send_message(node, {:s3d_mat, :commit_raw, bad, me})

receive do
  {:s3d_mat_raw_result, result} ->
    IO.inspect(result, label: "raw set_material with bogus scope")
    check.(result == {:error, {:unknown_material, "pawn", "pawn_bogus"}},
      "unknown scope rejects SYNCHRONOUSLY once the asset is loaded"
    )
after
  4_000 -> fail.("no reply for the bogus-scope raw commit")
end

# The scene must be untouched by the rejected patch (atomic reject-all).
{:ok, scene3} = Mob.Scene3d.scene(node, vp)
check.(
  match?(
    [%{"scope" => "pawn_body"}],
    scene3["entities"]["pawn"]["material_state"]
  ),
  "rejected patch left the applied overrides untouched"
)

# Async unknown_material: a fresh asset (probe.glb — never loaded in THIS
# viewport) with a bogus scope. Its material names are unregistered, so the
# shadow passes; the render thread loads it, finds no matching instance,
# and delivers {:scene3d_error, ...} (accumulated in the :errors assign)
# plus an error marker in material_state.
probe_path = :rpc.call(node, Mob.Scene3d, :resolve_asset, ["probe.glb"])

async_ops = [
  {:add_entity,
   %Mob.Scene3d.IR.Entity{
     id: "late_probe",
     transform: %Mob.Scene3d.IR.Transform{position: {5.0, 0.0, 0.0}},
     data: %Mob.Scene3d.IR.Model{
       asset: probe_path,
       material: [%Material{base_color: {0.0, 1.0, 0.0, 1.0}, scope: "no_such_material"}]
     }
   }}
]

Mob.Test.send_message(node, {:s3d_mat, :commit_raw, async_ops, me})

receive do
  {:s3d_mat_raw_result, result} ->
    IO.inspect(result, label: "raw add_entity with bogus scope on unloaded asset")
    check.(result == :ok, "shadow tolerates the unloaded asset (async-tolerant)")
after
  4_000 -> fail.("no reply for the async-probe raw commit")
end

Process.sleep(1_200)
errors = Mob.Test.assigns(node).errors
IO.inspect(errors, label: "screen :errors assign (async scene errors)")

check.(
  Enum.any?(errors, fn {_vp, error} ->
    is_binary(error) and error =~ "unknown_material" and error =~ "no_such_material"
  end),
  "async unknown_material error reached the owning screen"
)

{:ok, scene4} = Mob.Scene3d.scene(node, vp)
late_state = scene4["entities"]["late_probe"]["material_state"]
IO.inspect(late_state, label: "late_probe material_state (error marker)")

check.(
  Enum.any?(
    late_state || [],
    &match?(%{"scope" => "no_such_material", "error" => "unknown_material"}, &1)
  ),
  "readback marks the unmatched scope as unknown_material"
)

# Skew defense in depth: an op name this applier does not speak rejects the
# whole patch (the {:unsupported, :material_scope} guard itself is
# Elixir-side and host-tested; on-device we exercise the native fallback).
Mob.Test.send_message(node, {:s3d_mat, :commit_raw, [{:remove_entity, "late_probe"}], me})

receive do
  {:s3d_mat_raw_result, result} -> IO.inspect(result, label: "cleanup remove late_probe")
after
  4_000 -> fail.("no reply for cleanup")
end

raw_unknown_op = ~s({"schema":1,"ops":[["set_material_v9","pawn",null]]})

{:ok, unknown_op_reply} =
  :rpc.call(node, Mob.Scene3d.Native.NIF, :apply_patch, [vp, raw_unknown_op])

unknown_op_result = Mob.Scene3d.Wire.decode_result(unknown_op_reply)
IO.inspect(unknown_op_result, label: "unknown op straight at the NIF")
check.(unknown_op_result == {:error, {:unknown_op, "set_material_v9"}},
  "unknown op rejects the whole patch (skew defense in depth)"
)

IO.puts("battery complete")
