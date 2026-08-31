defmodule Mob.Scene3d.WireTest do
  use ExUnit.Case, async: true

  alias Mob.Scene3d.IR
  alias Mob.Scene3d.IR.{Animation, Camera, Entity, Environment, Light, Material, Model, Transform}
  alias Mob.Scene3d.IR.Patch
  alias Mob.Scene3d.Wire

  doctest Mob.Scene3d.Wire

  defp full_scene do
    IR.new([
      %Entity{id: "rig"},
      %Entity{
        id: "cam",
        parent: "rig",
        transform: %Transform{position: {0.0, 1.8, 4.8}},
        data: %Camera{fov_y: 35.0, near: 0.05, far: 100.0}
      },
      %Entity{
        id: "sun",
        data: %Light{
          type: :directional,
          intensity: 110_000.0,
          color: {1.0, 0.98, 0.92},
          cast_shadows: true
        }
      },
      %Entity{id: "env", data: %Environment{ibl: "env/studio", intensity: 30_000.0}},
      %Entity{
        id: "probe",
        parent: "rig",
        pickable: true,
        data: %Model{
          asset: "probe.glb",
          material: %Material{base_color: {1.0, 0.0, 0.0, 1.0}, metallic: 0.5},
          animation: %Animation{name: "spin", play_id: "p1", loop: true}
        }
      }
    ])
  end

  describe "encode_patch/1" do
    test "bootstrap patch encodes as a versioned envelope of op arrays" do
      ops = Patch.diff(IR.empty(), full_scene())
      decoded = ops |> Wire.encode_patch() |> Wire.decode!()

      assert %{"schema" => 1, "ops" => wire_ops} = decoded
      assert length(wire_ops) == length(ops)

      # Canonical order preserved: op names on the wire match diff order.
      assert Enum.map(wire_ops, &hd/1) == Enum.map(ops, &Wire.op_name/1)
    end

    test "entity payload carries id, parent, transform, flags, and kinded data" do
      [["add_entity", entity]] =
        [{:add_entity, hd(Map.values(full_scene().entities |> Map.take(["probe"])))}]
        |> Wire.encode_patch()
        |> Wire.decode!()
        |> Map.fetch!("ops")

      assert entity["id"] == "probe"
      assert entity["parent"] == "rig"
      assert entity["visible"] == true
      assert entity["pickable"] == true

      assert %{"position" => [+0.0, +0.0, +0.0], "rotation" => [_, _, _, w], "scale" => scale} =
               entity["transform"]

      assert w == 1.0
      assert scale == [1.0, 1.0, 1.0]

      assert %{"kind" => "model", "asset" => "probe.glb"} = entity["data"]

      assert %{"base_color" => [1.0, +0.0, +0.0, 1.0], "metallic" => 0.5} =
               entity["data"]["material"]

      assert %{"name" => "spin", "play_id" => "p1", "loop" => true} = entity["data"]["animation"]
    end

    test "group entities encode data as null" do
      [["add_entity", entity]] =
        [{:add_entity, %Entity{id: "g"}}]
        |> Wire.encode_patch()
        |> Wire.decode!()
        |> Map.fetch!("ops")

      assert entity["data"] == nil
    end

    test "light and environment data carry their kind tags" do
      ops = Patch.diff(IR.empty(), full_scene())
      wire_ops = ops |> Wire.encode_patch() |> Wire.decode!() |> Map.fetch!("ops")

      kinds =
        for ["add_entity", %{"data" => data}] <- wire_ops, data != nil, do: data["kind"]

      assert Enum.sort(kinds) == ["camera", "environment", "light", "model"]

      [light] = for ["add_entity", %{"data" => %{"kind" => "light"} = d}] <- wire_ops, do: d
      assert light["type"] == "directional"
      assert light["intensity"] == 110_000.0
      assert light["cast_shadows"] == true

      [env] = for ["add_entity", %{"data" => %{"kind" => "environment"} = d}] <- wire_ops, do: d
      assert env["ibl"] == "env/studio"
      assert env["skybox"] == nil
    end

    test "per-frame setters encode ids and whole values" do
      transform = %Transform{position: {1, 2, 3}}

      ops = [
        {:set_transform, "probe", transform},
        {:set_visible, "probe", false},
        {:set_material, "probe", nil},
        {:set_parent, "probe", nil},
        {:remove_entity, "probe"}
      ]

      assert %{"ops" => wire_ops} = ops |> Wire.encode_patch() |> Wire.decode!()

      assert [
               ["set_transform", "probe", %{"position" => [1.0, 2.0, 3.0]}],
               ["set_visible", "probe", false],
               ["set_material", "probe", nil],
               ["set_parent", "probe", nil],
               ["remove_entity", "probe"]
             ] = wire_ops
    end

    test "integer components encode as floats on the wire" do
      [[_, _, transform]] =
        [{:set_transform, "x", %Transform{position: {1, 0, -4}}}]
        |> Wire.encode_patch()
        |> Wire.decode!()
        |> Map.fetch!("ops")

      assert transform["position"] == [1.0, 0.0, -4.0]
    end
  end

  describe "decode_result/1" do
    test "ok" do
      assert Wire.decode_result(~s({"ok":true})) == :ok
    end

    test "taxonomy errors decode to the decision-record tuples" do
      cases = [
        {~s(["duplicate_entity","a"]), {:duplicate_entity, "a"}},
        {~s(["unknown_entity","ghost"]), {:unknown_entity, "ghost"}},
        {~s(["unknown_parent","a","ghost"]), {:unknown_parent, "a", "ghost"}},
        {~s(["has_children","a"]), {:has_children, "a"}},
        {~s(["kind_mismatch","a","model"]), {:kind_mismatch, "a", :model}},
        {~s(["structural_field","a","light_type"]), {:structural_field, "a", :light_type}},
        {~s(["bad_asset","x.glb","enoent"]), {:bad_asset, "x.glb", "enoent"}},
        {~s(["unknown_animation","a","spin"]), {:unknown_animation, "a", "spin"}},
        {~s(["unsupported","animation"]), {:unsupported, :animation}},
        {~s(["no_viewport","scene"]), {:no_viewport, "scene"}}
      ]

      for {wire, expected} <- cases do
        assert Wire.decode_result(~s({"error":#{wire}})) == {:error, expected}
      end
    end

    test "unknown tags do not mint atoms" do
      assert Wire.decode_result(~s({"error":["brand_new_failure","x"]})) ==
               {:error, {:unknown_error, ["brand_new_failure", "x"]}}
    end

    test "garbage replies are honest errors" do
      assert {:error, {:bad_native_reply, _}} = Wire.decode_result("not json")
      assert {:error, {:bad_native_reply, _}} = Wire.decode_result(~s({"what":1}))
    end
  end

  describe "decode_caps/1" do
    test "valid caps" do
      assert {:ok, %{schema: 1, ops: ops}} =
               Wire.decode_caps(~s({"schema":1,"ops":["add_entity","remove_entity"]}))

      assert MapSet.member?(ops, "add_entity")
      refute MapSet.member?(ops, "set_light")
    end

    test "malformed caps are honest errors" do
      assert {:error, {:bad_caps, _}} = Wire.decode_caps(~s({"schema":"one"}))
      assert {:error, {:bad_caps, _}} = Wire.decode_caps("junk")
    end
  end
end
