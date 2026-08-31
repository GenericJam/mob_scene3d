defmodule Mob.Scene3dTest do
  use ExUnit.Case, async: true

  alias Mob.Scene3d
  alias Mob.Scene3d.IR
  alias Mob.Scene3d.IR.{Camera, Entity, Light, Model, Transform}
  alias Mob.Scene3d.NativeMock
  alias Mob.Scene3d.Wire

  defp probe_scene do
    IR.new([
      %Entity{id: "cam", transform: %Transform{position: {0.0, 1.8, 4.8}}, data: %Camera{}},
      %Entity{id: "sun", data: %Light{type: :directional, intensity: 110_000.0}},
      %Entity{id: "probe", data: %Model{asset: "probe.glb"}}
    ])
  end

  describe "commit/3 — patch shipping" do
    test "bootstrap commit ships the full diff and returns the new committed IR" do
      next = probe_scene()
      assert {:ok, ^next} = Scene3d.commit("vp", IR.empty(), next)

      ops = NativeMock.shipped_ops()
      assert [_first, _second, _third] = ops
      assert Enum.all?(ops, &(hd(&1) == "add_entity"))
    end

    test "an unchanged scene ships nothing" do
      scene = probe_scene()
      assert {:ok, ^scene} = Scene3d.commit("vp", scene, scene)
      refute Enum.any?(NativeMock.calls(), &match?({:apply_patch, _, _}, &1))
    end

    test "incremental commit ships only the delta, diffed against committed" do
      committed = probe_scene()

      moved =
        update_in(committed.entities["probe"], fn %Entity{} = probe ->
          %Entity{probe | transform: %Transform{position: {1.0, 0.0, 0.0}}}
        end)

      assert {:ok, _next} = Scene3d.commit("vp", committed, moved)

      assert [["set_transform", "probe", %{"position" => [1.0, +0.0, +0.0]}]] =
               NativeMock.shipped_ops()
    end

    test "the native rejection propagates decoded and committed does not advance" do
      NativeMock.stub(:apply_patch, {:ok, ~s({"error":["unknown_entity","probe"]})})

      assert {:error, {:unknown_entity, "probe"}} =
               Scene3d.commit("vp", IR.empty(), probe_scene())
    end

    test "an invalid scene is rejected before anything reaches the wire" do
      invalid = IR.new([%Entity{id: "a", parent: "ghost"}])

      assert {:error, {:invalid_scene, {:unknown_parent, "a", "ghost"}}} =
               Scene3d.commit("vp", IR.empty(), invalid)

      assert NativeMock.calls() == []
    end

    test "relative model assets resolve against the configured root at the wire boundary" do
      Application.put_env(:mob_scene3d, :asset_root, "/data/app/priv/scene3d_assets")
      on_exit(fn -> Application.delete_env(:mob_scene3d, :asset_root) end)

      assert {:ok, committed} = Scene3d.commit("vp", IR.empty(), probe_scene())

      [["add_entity", %{"data" => data}]] =
        Enum.filter(
          NativeMock.shipped_ops(),
          &match?(["add_entity", %{"data" => %{"kind" => "model"}}], &1)
        )

      assert data["asset"] == "/data/app/priv/scene3d_assets/probe.glb"
      # The committed IR keeps the logical ref — diffs compare intent.
      assert committed.entities["probe"].data.asset == "probe.glb"
    end
  end

  describe "commit/3 — version-skew guards" do
    test "an op the native caps do not declare is refused loudly" do
      partial_caps =
        %{"schema" => Wire.schema(), "ops" => ["add_entity", "remove_entity"]}
        |> :json.encode()
        |> IO.iodata_to_binary()

      NativeMock.stub(:caps, {:ok, partial_caps})

      # probe_scene bootstrap needs set-free adds only — those pass:
      assert {:ok, committed} = Scene3d.commit("vp", IR.empty(), probe_scene())
      # ...but a transform poke needs set_transform, which this applier lacks:
      moved =
        update_in(committed.entities["probe"], fn %Entity{} = probe ->
          %Entity{probe | transform: %Transform{position: {1.0, 0.0, 0.0}}}
        end)

      assert {:error, {:unsupported, :set_transform}} = Scene3d.commit("vp", committed, moved)
      # Nothing shipped for the refused patch.
      assert [{_caps1}, {:apply_patch, _, _}, {_caps2}] =
               Enum.filter(NativeMock.calls(), &(elem(&1, 0) in [:caps, :apply_patch]))
    end

    test "a schema mismatch is refused loudly" do
      alien = %{"schema" => 99, "ops" => Wire.v1_op_names()}
      NativeMock.stub(:caps, {:ok, alien |> :json.encode() |> IO.iodata_to_binary()})

      assert {:error, {:schema_mismatch, 99, 1}} = Scene3d.commit("vp", IR.empty(), probe_scene())
    end

    test "a missing native half degrades honestly" do
      NativeMock.stub(:caps, {:error, :nif_not_loaded})
      assert {:error, :nif_not_loaded} = Scene3d.commit("vp", IR.empty(), probe_scene())
    end

    test "garbage caps are an error, not a guess" do
      NativeMock.stub(:caps, {:ok, "junk"})
      assert {:error, {:bad_caps, _}} = Scene3d.commit("vp", IR.empty(), probe_scene())
    end
  end

  describe "scene/2" do
    test "returns the decoded native readback" do
      scene_json = ~s({"entities":{"probe":{"kind":"model","status":"ready"}}})

      NativeMock.stub(:request_scene, fn viewport_id, request_id ->
        send(self(), {:scene3d_scene, viewport_id, request_id, scene_json})
        {:ok, ~s({"ok":true})}
      end)

      assert {:ok, scene} = Scene3d.scene("vp", 200)
      assert scene["entities"]["probe"]["status"] == "ready"
    end

    test "a reply for a different viewport or request is not consumed" do
      NativeMock.stub(:request_scene, fn _viewport_id, _request_id ->
        send(self(), {:scene3d_scene, "other_vp", "other_req", "{}"})
        {:ok, ~s({"ok":true})}
      end)

      assert {:error, :timeout} = Scene3d.scene("vp", 50)
      assert_received {:scene3d_scene, "other_vp", "other_req", "{}"}
    end

    test "a no-viewport reply surfaces as the taxonomy error" do
      NativeMock.stub(:request_scene, {:ok, ~s({"error":["no_viewport","vp"]})})
      assert {:error, {:no_viewport, "vp"}} = Scene3d.scene("vp", 10)
    end
  end

  describe "destroy/1" do
    test "decodes the native reply" do
      assert :ok = Scene3d.destroy("vp")
      assert [{:destroy, "vp"}] = NativeMock.calls()
    end
  end

  describe "Native.NIF without a native half" do
    test "every entry point degrades to {:error, :nif_not_loaded}" do
      assert {:error, :nif_not_loaded} = Mob.Scene3d.Native.NIF.caps()
      assert {:error, :nif_not_loaded} = Mob.Scene3d.Native.NIF.apply_patch("vp", "{}")
      assert {:error, :nif_not_loaded} = Mob.Scene3d.Native.NIF.request_scene("vp", "r")
      assert {:error, :nif_not_loaded} = Mob.Scene3d.Native.NIF.destroy("vp")
    end
  end
end
