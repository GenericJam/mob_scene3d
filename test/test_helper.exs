# The whole suite runs against the mocked NIF boundary; the mock scripts and
# records per-process, so tests stay async. Mob.Scene3d.Native.NIF's own
# not-loaded degradation is tested directly against the real module.
Application.put_env(:mob_scene3d, :native, Mob.Scene3d.NativeMock)

ExUnit.start()
