# The whole suite runs against the mocked NIF boundary; the mock scripts and
# records per-process, so tests stay async. Mob.Scene3d.Native.NIF's own
# not-loaded degradation is tested directly against the real module.
Application.put_env(:mob_scene3d, :native, Mob.Scene3d.NativeMock)

# Tool-gated tests: the Khronos validator (gltf-transform) and Filament's
# cmgen are external binaries. When one is missing, the tests that shell out
# to it are excluded — loudly, so the skip is never a silent surprise
# (AGENTS.md → verify effects, not exit codes). CI installs both.
tool_gates = [
  {:requires_gltf_transform, match?({:ok, _}, Mob.Scene3d.Assets.Tools.gltf_transform_command()),
   "npm install -g @gltf-transform/cli"},
  {:requires_cmgen, match?({:ok, _}, Mob.Scene3d.Assets.Tools.cmgen_path()),
   "scripts/fetch_cmgen.sh"}
]

excluded =
  for {tag, available?, install_hint} <- tool_gates, not available? do
    IO.puts(:stderr, "WARNING: excluding #{tag} tests — install the tool with: #{install_hint}")
    tag
  end

ExUnit.start(exclude: excluded)
