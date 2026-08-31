defmodule Mob.Scene3d.IRTest do
  use ExUnit.Case, async: true

  alias Mob.Scene3d.IR
  alias Mob.Scene3d.IR.{Camera, Entity, Environment, Light, Material, Model, Transform}

  doctest Mob.Scene3d.IR
  doctest Mob.Scene3d.IR.Transform
  doctest Mob.Scene3d.IR.Patch

  describe "new/1" do
    test "raises on duplicate ids" do
      assert_raise ArgumentError, ~r/duplicate entity id/, fn ->
        IR.new([%Entity{id: "a"}, %Entity{id: "a"}])
      end
    end
  end

  describe "validate/1" do
    test "rejects a non-binary id" do
      ir = %IR{entities: %{atom_id: %Entity{id: :atom_id}}}
      assert IR.validate(ir) == {:error, {:invalid_id, :atom_id}}
    end

    test "rejects a key that disagrees with the entity id" do
      ir = %IR{entities: %{"a" => %Entity{id: "b"}}}
      assert IR.validate(ir) == {:error, {:id_mismatch, "a", "b"}}
    end

    test "rejects a self-parented entity" do
      ir = %IR{entities: %{"a" => %Entity{id: "a", parent: "a"}}}
      assert IR.validate(ir) == {:error, {:parent_cycle, ["a"]}}
    end

    test "rejects two cameras" do
      ir =
        IR.new([
          %Entity{id: "cam1", data: %Camera{}},
          %Entity{id: "cam2", data: %Camera{}}
        ])

      assert IR.validate(ir) == {:error, {:multiple_cameras, ["cam1", "cam2"]}}
    end

    test "rejects two environments" do
      ir =
        IR.new([
          %Entity{id: "env1", data: %Environment{ibl: "env/studio"}},
          %Entity{id: "env2", data: %Environment{ibl: "env/sunset"}}
        ])

      assert IR.validate(ir) == {:error, {:multiple_environments, ["env1", "env2"]}}
    end

    test "rejects pickable on anything that is not a model" do
      ir = IR.new([%Entity{id: "grp", pickable: true}])
      assert IR.validate(ir) == {:error, {:invalid_entity, "grp", :pickable_requires_model}}
    end

    test "rejects a spot cone on a directional light" do
      light = %Light{type: :directional, intensity: 100_000.0, spot_inner: 10.0, spot_outer: 20.0}
      ir = IR.new([%Entity{id: "sun", data: light}])

      assert IR.validate(ir) ==
               {:error, {:invalid_entity, "sun", {:invalid_spot_cone, {10.0, 20.0}}}}
    end

    test "rejects an environment with neither ibl nor skybox" do
      ir = IR.new([%Entity{id: "env", data: %Environment{}}])
      assert IR.validate(ir) == {:error, {:invalid_entity, "env", :empty_environment}}
    end

    test "rejects a camera whose far plane is not beyond its near plane" do
      ir = IR.new([%Entity{id: "cam", data: %Camera{near: 5.0, far: 1.0}}])
      assert IR.validate(ir) == {:error, {:invalid_entity, "cam", {:invalid_far, 1.0}}}
    end

    test "accepts a full valid scene" do
      ir =
        IR.new([
          %Entity{id: "cam", data: %Camera{}, transform: %Transform{position: {0.0, 8.0, 6.0}}},
          %Entity{id: "sun", data: %Light{type: :directional, intensity: 100_000.0}},
          %Entity{id: "env", data: %Environment{ibl: "env/studio"}},
          %Entity{id: "board", data: %Model{asset: "board.glb"}},
          %Entity{id: "p1", parent: "board", pickable: true, data: %Model{asset: "piece.glb"}}
        ])

      assert IR.validate(ir) == :ok
    end
  end

  defp pawn(material) do
    IR.new([%Entity{id: "pawn", data: %Model{asset: "pawn.glb", material: material}}])
  end

  describe "validate/1 — scoped material overrides" do
    test "accepts a single scoped override" do
      material = %Material{base_color: {0.9, 0.3, 0.1, 1.0}, scope: "pawn_body"}
      assert IR.validate(pawn(material)) == :ok
    end

    test "accepts a list of distinct scoped overrides" do
      materials = [
        %Material{base_color: {0.9, 0.3, 0.1, 1.0}, scope: "pawn_body"},
        %Material{emissive: {0.2, 0.2, 0.0}, scope: "pawn_accent"}
      ]

      assert IR.validate(pawn(materials)) == :ok
    end

    test "rejects an empty scope name" do
      material = %Material{base_color: {1.0, 1.0, 1.0, 1.0}, scope: ""}

      assert IR.validate(pawn(material)) ==
               {:error, {:invalid_entity, "pawn", {:invalid_scope, ""}}}
    end

    test "rejects a non-binary scope" do
      material = %Material{scope: :pawn_body}

      assert IR.validate(pawn(material)) ==
               {:error, {:invalid_entity, "pawn", {:invalid_scope, :pawn_body}}}
    end

    test "rejects an empty override list" do
      assert IR.validate(pawn([])) ==
               {:error, {:invalid_entity, "pawn", :empty_material_list}}
    end

    test "rejects an unscoped override inside a list" do
      materials = [
        %Material{base_color: {0.9, 0.3, 0.1, 1.0}, scope: "pawn_body"},
        %Material{roughness: 0.5}
      ]

      assert IR.validate(pawn(materials)) ==
               {:error, {:invalid_entity, "pawn", :unscoped_material_in_list}}
    end

    test "rejects duplicate scopes in a list" do
      materials = [
        %Material{base_color: {0.9, 0.3, 0.1, 1.0}, scope: "pawn_body"},
        %Material{roughness: 0.5, scope: "pawn_body"}
      ]

      assert IR.validate(pawn(materials)) ==
               {:error, {:invalid_entity, "pawn", {:duplicate_material_scope, "pawn_body"}}}
    end

    test "rejects an invalid entry inside a list, first problem wins" do
      materials = [%Material{metallic: 2.0, scope: "pawn_body"}]

      assert IR.validate(pawn(materials)) ==
               {:error, {:invalid_entity, "pawn", {:metallic_out_of_range, 2.0}}}
    end

    test "rejects a non-material inside a list" do
      assert IR.validate(pawn([:not_a_material])) ==
               {:error, {:invalid_entity, "pawn", {:invalid_material, :not_a_material}}}
    end
  end

  describe "depth/2" do
    test "counts hops to the root" do
      ir =
        IR.new([
          %Entity{id: "root"},
          %Entity{id: "mid", parent: "root"},
          %Entity{id: "leaf", parent: "mid"}
        ])

      assert IR.depth(ir, "root") == 0
      assert IR.depth(ir, "leaf") == 2
    end
  end
end
