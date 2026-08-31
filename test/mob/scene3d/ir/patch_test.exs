defmodule Mob.Scene3d.IR.PatchTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Mob.Scene3d.IR

  alias Mob.Scene3d.IR.{
    Animation,
    Camera,
    Entity,
    Environment,
    Light,
    Material,
    Model,
    Patch,
    Transform
  }

  # ── properties: these lock the grammar ─────────────────────────────────────

  property "diff of a scene against itself is empty" do
    check all ir <- gen_ir() do
      assert Patch.diff(ir, ir) == []
    end
  end

  property "apply(a, diff(a, b)) round-trips to b" do
    check all a <- gen_ir(), b <- gen_ir() do
      assert Patch.apply(a, Patch.diff(a, b)) == {:ok, b}
    end
  end

  property "generated scenes are valid (the generators earn the round-trip)" do
    check all ir <- gen_ir() do
      assert IR.validate(ir) == :ok
    end
  end

  # ── honest errors ───────────────────────────────────────────────────────────

  describe "apply/2 errors" do
    test "duplicate add" do
      {:ok, ir} = Patch.apply(IR.empty(), [{:add_entity, %Entity{id: "a"}}])

      assert Patch.apply(ir, [{:add_entity, %Entity{id: "a"}}]) ==
               {:error, {:duplicate_entity, "a"}}
    end

    test "add referencing a missing parent" do
      ops = [{:add_entity, %Entity{id: "a", parent: "ghost"}}]
      assert Patch.apply(IR.empty(), ops) == {:error, {:unknown_parent, "a", "ghost"}}
    end

    test "per-frame op against a missing entity" do
      ops = [{:set_visible, "ghost", false}]
      assert Patch.apply(IR.empty(), ops) == {:error, {:unknown_entity, "ghost"}}
    end

    test "removing a parent before its children" do
      ir = IR.new([%Entity{id: "a"}, %Entity{id: "b", parent: "a"}])
      assert Patch.apply(ir, [{:remove_entity, "a"}]) == {:error, {:has_children, "a"}}
    end

    test "material op against a non-model" do
      ir = IR.new([%Entity{id: "cam", data: %Camera{}}])
      ops = [{:set_material, "cam", %Material{metallic: 0.5}}]
      assert Patch.apply(ir, ops) == {:error, {:kind_mismatch, "cam", :model}}
    end

    test "light type smuggled through a per-frame op" do
      ir = IR.new([%Entity{id: "sun", data: %Light{type: :directional, intensity: 1.0}}])
      ops = [{:set_light, "sun", %Light{type: :point, intensity: 1.0}}]
      assert Patch.apply(ir, ops) == {:error, {:structural_field, "sun", :light_type}}
    end

    test "environment refs smuggled through a per-frame op" do
      ir = IR.new([%Entity{id: "env", data: %Environment{ibl: "env/studio"}}])
      ops = [{:set_environment, "env", %Environment{ibl: "env/sunset"}}]
      assert Patch.apply(ir, ops) == {:error, {:structural_field, "env", :environment_assets}}
    end

    test "an op the grammar does not know" do
      assert Patch.apply(IR.empty(), [{:teleport, "a"}]) ==
               {:error, {:unknown_op, {:teleport, "a"}}}
    end

    test "a grammar-legal sequence producing an invalid scene" do
      ir = IR.new([%Entity{id: "cam1", data: %Camera{}}])
      ops = [{:add_entity, %Entity{id: "cam2", data: %Camera{}}}]

      assert Patch.apply(ir, ops) ==
               {:error, {:invalid_result, {:multiple_cameras, ["cam1", "cam2"]}}}
    end
  end

  describe "diff/2 canonical shape" do
    test "asset change is a replace, not a per-frame op" do
      a = IR.new([%Entity{id: "m", data: %Model{asset: "old.glb"}}])
      b = IR.new([%Entity{id: "m", data: %Model{asset: "new.glb"}}])
      assert [{:replace_entity, %Entity{id: "m"}}] = Patch.diff(a, b)
    end

    test "kind change is a replace" do
      a = IR.new([%Entity{id: "x"}])
      b = IR.new([%Entity{id: "x", data: %Camera{}}])
      assert [{:replace_entity, %Entity{id: "x", data: %Camera{}}}] = Patch.diff(a, b)
    end

    test "removals come out children-first, adds parents-first" do
      a = IR.new([%Entity{id: "p"}, %Entity{id: "c", parent: "p"}])
      b = IR.new([%Entity{id: "q"}, %Entity{id: "r", parent: "q"}])

      assert Patch.diff(a, b) == [
               {:add_entity, %Entity{id: "q"}},
               {:add_entity, %Entity{id: "r", parent: "q"}},
               {:remove_entity, "c"},
               {:remove_entity, "p"}
             ]
    end

    test "a play_id change alone re-emits the animation op" do
      throw1 = %Animation{name: "tumble_3", play_id: "throw-1"}
      throw2 = %Animation{name: "tumble_3", play_id: "throw-2"}
      a = IR.new([%Entity{id: "cowrie", data: %Model{asset: "cowrie.glb", animation: throw1}}])
      b = IR.new([%Entity{id: "cowrie", data: %Model{asset: "cowrie.glb", animation: throw2}}])

      assert Patch.diff(a, b) == [{:set_animation, "cowrie", throw2}]
    end

    test "a scoped override list is per-frame: one whole-value set_material" do
      body = %Material{base_color: {0.9, 0.3, 0.1, 1.0}, scope: "pawn_body"}
      accent = %Material{emissive: {0.2, 0.2, 0.0}, scope: "pawn_accent"}
      a = IR.new([%Entity{id: "pawn", data: %Model{asset: "pawn.glb", material: [body]}}])
      b = IR.new([%Entity{id: "pawn", data: %Model{asset: "pawn.glb", material: [body, accent]}}])

      assert Patch.diff(a, b) == [{:set_material, "pawn", [body, accent]}]
      assert Patch.apply(a, Patch.diff(a, b)) == {:ok, b}
    end

    test "single-override back-compat: scope nil diffs and applies as before" do
      tint = %Material{base_color: {1.0, 0.0, 0.0, 1.0}}
      a = IR.new([%Entity{id: "m", data: %Model{asset: "m.glb"}}])
      b = IR.new([%Entity{id: "m", data: %Model{asset: "m.glb", material: tint}}])

      assert Patch.diff(a, b) == [{:set_material, "m", tint}]
      assert Patch.apply(a, Patch.diff(a, b)) == {:ok, b}
    end
  end

  # ── generators ──────────────────────────────────────────────────────────────
  #
  # Scenes are drawn from a small shared id pool so two independent draws
  # overlap: the round-trip then exercises adds, removals, replaces (same id,
  # different kind or asset), reparents, and every per-frame op.

  @id_pool ~w(e0 e1 e2 e3 e4 e5)
  @assets ~w(board.glb piece.glb cowrie.glb)
  @env_refs ~w(env/studio env/sunset)

  defp gen_ir do
    gen all count <- integer(0..length(@id_pool)),
            entities <- gen_entities(Enum.take(@id_pool, count)) do
      IR.new(enforce_singletons(entities))
    end
  end

  # Parents are drawn from earlier ids only, so every generated scene is a
  # forest by construction — no rejection sampling.
  defp gen_entities(ids) do
    ids
    |> Enum.with_index()
    |> Enum.reduce(constant([]), fn {id, index}, acc ->
      bind(acc, fn entities ->
        bind(gen_entity(id, Enum.take(@id_pool, index)), fn entity ->
          constant(entities ++ [entity])
        end)
      end)
    end)
  end

  defp gen_entity(id, candidate_parents) do
    gen all parent <- one_of([constant(nil) | Enum.map(candidate_parents, &constant/1)]),
            transform <- gen_transform(),
            visible <- boolean(),
            data <- gen_data(),
            pickable <- gen_pickable(data) do
      %Entity{
        id: id,
        parent: parent,
        transform: transform,
        visible: visible,
        pickable: pickable,
        data: data
      }
    end
  end

  defp gen_pickable(%Model{}), do: boolean()
  defp gen_pickable(_data), do: constant(false)

  defp gen_data do
    frequency([
      {3, constant(nil)},
      {4, gen_model()},
      {1, gen_camera()},
      {2, gen_light()},
      {1, gen_environment()}
    ])
  end

  # Scoped-override scopes draw from a tiny pool (the two-tone pawn's
  # material names) so list draws overlap and the round-trip exercises
  # same-scope value changes, not just add/remove.
  @scopes ~w(pawn_body pawn_accent)

  defp gen_model do
    gen all asset <- member_of(@assets),
            material <-
              one_of([
                constant(nil),
                gen_material(one_of([constant(nil) | Enum.map(@scopes, &constant/1)])),
                gen_material_list()
              ]),
            animation <- one_of([constant(nil), gen_animation()]) do
      %Model{asset: asset, material: material, animation: animation}
    end
  end

  defp gen_material(scope_gen) do
    gen all scope <- scope_gen,
            base_color <- one_of([constant(nil), gen_rgba()]),
            metallic <- one_of([constant(nil), unit_float()]),
            roughness <- one_of([constant(nil), unit_float()]),
            emissive <- one_of([constant(nil), gen_rgb()]) do
      %Material{
        base_color: base_color,
        metallic: metallic,
        roughness: roughness,
        emissive: emissive,
        scope: scope
      }
    end
  end

  # List form: distinct non-nil scopes by construction (a prefix of the
  # pool), per the IR validation rules.
  defp gen_material_list do
    gen all count <- integer(1..length(@scopes)),
            materials <-
              @scopes
              |> Enum.take(count)
              |> Enum.map(&gen_material(constant(&1)))
              |> fixed_list() do
      materials
    end
  end

  defp gen_animation do
    gen all name <- member_of(~w(tumble_1 tumble_2 spin)),
            play_id <- member_of(~w(throw-1 throw-2 throw-3)),
            loop <- boolean(),
            speed <- float(min: 0.25, max: 3.0),
            paused <- boolean(),
            seek <- one_of([constant(nil), float(min: 0.0, max: 10.0)]) do
      %Animation{
        name: name,
        play_id: play_id,
        loop: loop,
        speed: speed,
        paused: paused,
        seek: seek
      }
    end
  end

  defp gen_camera do
    gen all fov_y <- float(min: 10.0, max: 120.0),
            near <- float(min: 0.01, max: 1.0),
            far <- float(min: 2.0, max: 500.0) do
      %Camera{fov_y: fov_y, near: near, far: far}
    end
  end

  defp gen_light do
    gen all type <- member_of([:directional, :point, :spot]),
            intensity <- float(min: 0.0, max: 200_000.0),
            color <- gen_rgb(),
            cast_shadows <- boolean(),
            falloff <- gen_falloff(type),
            cone <- gen_cone(type) do
      {spot_inner, spot_outer} = cone

      %Light{
        type: type,
        intensity: intensity,
        color: color,
        cast_shadows: cast_shadows,
        falloff: falloff,
        spot_inner: spot_inner,
        spot_outer: spot_outer
      }
    end
  end

  defp gen_falloff(:directional), do: constant(nil)
  defp gen_falloff(_type), do: one_of([constant(nil), float(min: 0.5, max: 50.0)])

  defp gen_cone(:spot) do
    inner_outer =
      gen all inner <- float(min: 1.0, max: 45.0),
              spread <- float(min: 0.0, max: 90.0) do
        {inner, inner + spread}
      end

    one_of([constant({nil, nil}), inner_outer])
  end

  defp gen_cone(_type), do: constant({nil, nil})

  defp gen_environment do
    gen all ibl <- member_of(@env_refs),
            skybox <- one_of([constant(nil), member_of(@env_refs)]),
            intensity <- float(min: 0.0, max: 100_000.0) do
      %Environment{ibl: ibl, skybox: skybox, intensity: intensity}
    end
  end

  defp gen_transform do
    gen all position <- gen_vec3(),
            rotation <- gen_quat(),
            scale <- gen_vec3() do
      %Transform{position: position, rotation: rotation, scale: scale}
    end
  end

  defp gen_vec3 do
    gen(all x <- coord(), y <- coord(), z <- coord(), do: {x, y, z})
  end

  defp gen_quat do
    gen(all x <- coord(), y <- coord(), z <- coord(), w <- coord(), do: {x, y, z, w})
  end

  defp coord, do: float(min: -10.0, max: 10.0)

  defp unit_float, do: float(min: 0.0, max: 1.0)

  defp gen_rgb do
    gen(all r <- unit_float(), g <- unit_float(), b <- unit_float(), do: {r, g, b})
  end

  defp gen_rgba do
    gen(
      all r <- unit_float(),
          g <- unit_float(),
          b <- unit_float(),
          a <- unit_float(),
          do: {r, g, b, a}
    )
  end

  # At most one camera and one environment per scene: keep the first of each,
  # demote the rest to groups (pickable is already false for non-models).
  defp enforce_singletons(entities) do
    {result, _seen} =
      Enum.map_reduce(entities, MapSet.new(), fn %Entity{} = entity, seen ->
        case singleton_kind(entity.data) do
          nil ->
            {entity, seen}

          kind ->
            case MapSet.member?(seen, kind) do
              true -> {%Entity{entity | data: nil}, seen}
              false -> {entity, MapSet.put(seen, kind)}
            end
        end
      end)

    result
  end

  defp singleton_kind(%Camera{}), do: :camera
  defp singleton_kind(%Environment{}), do: :environment
  defp singleton_kind(_data), do: nil
end
