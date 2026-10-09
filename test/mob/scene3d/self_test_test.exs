defmodule Mob.Scene3d.SelfTestTest do
  use ExUnit.Case, async: true

  alias Mob.Plugin.SelfTest, as: Contract
  alias Mob.Scene3d.{NativeMock, SelfTest, Wire}
  alias MobDev.Plugin.{Manifest, Validator}

  @plugin_dir Path.expand("../../..", __DIR__)
  @ghost "mob_scene3d_selftest_ghost"
  @rejection ~s({"error":["unknown_entity","#{@ghost}"]})

  defp run, do: SelfTest.run(%{platform: :android, device: :emulator})

  test "the manifest declares the self-test, and the validator accepts it" do
    {:ok, m} = Manifest.load(@plugin_dir)
    assert m.selftest == Mob.Scene3d.SelfTest
    assert %{warnings: warnings} = Validator.validate_plugin(m, @plugin_dir)
    refute Enum.any?(warnings, &(&1 =~ "selftest"))
  end

  test "passes when caps match the wire and the shadow registry rejects the ghost removal" do
    NativeMock.stub(:apply_patch, {:ok, @rejection})
    assert run() == :pass

    assert [
             {:caps},
             {:apply_patch, "mob_scene3d_selftest", patch},
             {:destroy, "mob_scene3d_selftest"}
           ] = NativeMock.calls()

    assert patch == SelfTest.ghost_patch()
    assert %{"ops" => [["remove_entity", @ghost]]} = Wire.decode!(patch)
  end

  test "a native side that accepts the ghost removal fails: it is not validating" do
    result = run()
    assert {:fail, reason} = result
    assert reason =~ "accepted removing the unknown entity"
    assert Contract.result?(result)
    refute Enum.any?(NativeMock.calls(), &match?({:destroy, _}, &1))
  end

  test "an unregistered Kotlin bridge fails at caps and names the bridge" do
    NativeMock.stub(:caps, {:ok, ~s({"error":["bridge_unregistered"]})})
    result = run()
    assert {:fail, reason} = result
    assert reason =~ "MobScene3dBridge not registered"
    assert Contract.result?(result)
    assert NativeMock.calls() == [{:caps}]
  end

  test "an unregistered bridge at apply also names the bridge" do
    result = SelfTest.check_reject({:ok, ~s({"error":["bridge_unregistered"]})})
    assert {:fail, reason} = result
    assert reason =~ "MobScene3dBridge not registered"
    assert Contract.result?(result)
  end

  test "no native half linked fails at caps and at apply" do
    for result <- [
          SelfTest.check_caps({:error, :nif_not_loaded}),
          SelfTest.check_reject({:error, :nif_not_loaded})
        ] do
      assert {:fail, "mob_scene3d_nif is not linked into this build" <> _} = result
      assert Contract.result?(result)
    end
  end

  test "caps from a different wire schema, without remove_entity, or with unknown ops fail" do
    schema = Wire.schema()

    for {json, expected} <- [
          {~s({"schema":#{schema + 1},"ops":["remove_entity"]}), "wire schema #{schema + 1}"},
          {~s({"schema":#{schema},"ops":["add_entity"]}), "does not list remove_entity"},
          {~s({"schema":#{schema},"ops":["remove_entity","teleport"]}), ~s(["teleport"])},
          {"not json", "expected the caps JSON"}
        ] do
      result = SelfTest.check_caps({:ok, json})
      assert {:fail, reason} = result
      assert reason =~ expected
      assert Contract.result?(result)
    end
  end

  test "a rejection for the wrong reason fails" do
    result = SelfTest.check_reject({:ok, ~s({"error":["bad_patch","schema"]})})
    assert {:fail, reason} = result
    assert reason =~ ~s(expected {"error":["unknown_entity")
    assert Contract.result?(result)
  end

  test "a failed destroy fails" do
    NativeMock.stub(:apply_patch, {:ok, @rejection})
    NativeMock.stub(:destroy, {:ok, ~s({"error":["no_viewport"]})})
    result = run()
    assert {:fail, "scene3d_destroy/1 answered" <> _} = result
    assert Contract.result?(result)
  end
end
