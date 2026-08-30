defmodule Mob.Scene3d.IR.Patch do
  @moduledoc """
  The patch grammar: pure diff/apply between two scene IRs.

  `diff/2` computes the canonical op list turning scene `a` into scene `b`;
  `apply/2` is the reference applier the native (Filament) applier must agree
  with. The grammar is locked by the property `apply(a, diff(a, b)) == {:ok,
  b}` over generated scenes — testable with zero native code.

  ## Ops

  Structural (native resource lifecycle):

    * `{:add_entity, entity}` — create id and its native resources
    * `{:replace_entity, entity}` — same id, structural field changed
      (kind, model asset, light type, environment refs): destroy + recreate
    * `{:remove_entity, id}` — destroy (children must go first)

  Per-frame (cheap state pokes):

    * `{:set_parent, id, parent | nil}`
    * `{:set_transform, id, transform}` — whole TRS, replace not merge
    * `{:set_visible, id, boolean}` / `{:set_pickable, id, boolean}`
    * `{:set_material, id, material | nil}` — whole override, replace not merge
    * `{:set_animation, id, animation | nil}`
    * `{:set_camera, id, camera}` / `{:set_light, id, light}` /
      `{:set_environment, id, environment}`

  ## Canonical order

  One patch = one frame, applied atomically. Within a patch, `diff/2` emits
  (and `apply/2` enforces, by erroring on dangling references):

  1. adds, parents-first
  2. replaces, parents-first
  3. reparents
  4. removals, children-first
  5. per-frame ops, by id

  Adds precede reparents so a survivor can move under a new entity; reparents
  precede removals so a survivor can leave a dying parent before it goes.

  ## Honest errors

  `apply/2` never silently no-ops: an op against a missing id, a duplicate
  add, a per-frame op against the wrong kind, or a per-frame op smuggling a
  structural change all return `{:error, reason}` — the same taxonomy the
  native applier must report back over the wire.
  """

  alias Mob.Scene3d.IR
  alias Mob.Scene3d.IR.{Animation, Camera, Entity, Environment, Light, Material, Model, Transform}

  @type op ::
          {:add_entity, Entity.t()}
          | {:replace_entity, Entity.t()}
          | {:remove_entity, IR.id()}
          | {:set_parent, IR.id(), IR.id() | nil}
          | {:set_transform, IR.id(), Transform.t()}
          | {:set_visible, IR.id(), boolean()}
          | {:set_pickable, IR.id(), boolean()}
          | {:set_material, IR.id(), Material.t() | nil}
          | {:set_animation, IR.id(), Animation.t() | nil}
          | {:set_camera, IR.id(), Camera.t()}
          | {:set_light, IR.id(), Light.t()}
          | {:set_environment, IR.id(), Environment.t()}

  @type error ::
          {:duplicate_entity, IR.id()}
          | {:unknown_entity, IR.id()}
          | {:unknown_parent, IR.id(), IR.id()}
          | {:has_children, IR.id()}
          | {:kind_mismatch, IR.id(), atom()}
          | {:structural_field, IR.id(), atom()}
          | {:unknown_op, term()}
          | {:invalid_result, IR.error()}

  @doc """
  Compute the canonical patch turning `a` into `b`. Both scenes are assumed
  valid (`IR.validate/1`); diffing garbage yields garbage.

      iex> alias Mob.Scene3d.IR
      iex> alias Mob.Scene3d.IR.{Entity, Model, Patch}
      iex> a = IR.new([%Entity{id: "board", data: %Model{asset: "board.glb"}}])
      iex> b =
      ...>   IR.new([
      ...>     %Entity{id: "board", data: %Model{asset: "board.glb"}},
      ...>     %Entity{id: "p1", parent: "board", data: %Model{asset: "piece.glb"}}
      ...>   ])
      iex> [{:add_entity, %Entity{id: "p1"}}] = Patch.diff(a, b)
      iex> Patch.diff(a, a)
      []
  """
  @spec diff(IR.t(), IR.t()) :: [op()]
  def diff(%IR{} = a, %IR{} = b) do
    ids_a = a.entities |> Map.keys() |> MapSet.new()
    ids_b = b.entities |> Map.keys() |> MapSet.new()

    added = MapSet.difference(ids_b, ids_a)
    removed = MapSet.difference(ids_a, ids_b)
    common = MapSet.intersection(ids_a, ids_b)

    {replaced, kept} =
      Enum.split_with(common, fn id ->
        structural_change?(a.entities[id], b.entities[id])
      end)

    parents_first = fn id -> {IR.depth(b, id), id} end

    adds =
      added
      |> Enum.sort_by(parents_first)
      |> Enum.map(&{:add_entity, b.entities[&1]})

    replaces =
      replaced
      |> Enum.sort_by(parents_first)
      |> Enum.map(&{:replace_entity, b.entities[&1]})

    reparents =
      kept
      |> Enum.filter(fn id -> a.entities[id].parent != b.entities[id].parent end)
      |> Enum.sort()
      |> Enum.map(&{:set_parent, &1, b.entities[&1].parent})

    removes =
      removed
      |> Enum.sort_by(fn id -> {-IR.depth(a, id), id} end)
      |> Enum.map(&{:remove_entity, &1})

    frame =
      kept
      |> Enum.sort()
      |> Enum.flat_map(fn id -> frame_ops(id, a.entities[id], b.entities[id]) end)

    adds ++ replaces ++ reparents ++ removes ++ frame
  end

  @doc """
  Apply a patch to a scene — the pure reference for the native applier.

  Ops are applied in order; the first failure aborts the whole patch (native
  applies a patch atomically: reject-all, never partial). The result is
  re-validated, so a grammar-legal op sequence that produces an invalid scene
  (a parent cycle, a second camera) is also an error.

      iex> alias Mob.Scene3d.IR
      iex> alias Mob.Scene3d.IR.Patch
      iex> Patch.apply(IR.empty(), [{:remove_entity, "ghost"}])
      {:error, {:unknown_entity, "ghost"}}
  """
  @spec apply(IR.t(), [op()]) :: {:ok, IR.t()} | {:error, error()}
  def apply(%IR{} = ir, ops) when is_list(ops) do
    with {:ok, applied} <- apply_ops(ir, ops) do
      case IR.validate(applied) do
        :ok -> {:ok, applied}
        {:error, reason} -> {:error, {:invalid_result, reason}}
      end
    end
  end

  # ── op application ──────────────────────────────────────────────────────────

  defp apply_ops(ir, ops) do
    Enum.reduce_while(ops, {:ok, ir}, fn op, {:ok, acc} ->
      case apply_op(acc, op) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp apply_op(%IR{} = ir, {:add_entity, %Entity{id: id} = entity}) do
    cond do
      Map.has_key?(ir.entities, id) -> {:error, {:duplicate_entity, id}}
      not parent_present?(ir, entity.parent) -> {:error, {:unknown_parent, id, entity.parent}}
      true -> {:ok, put(ir, entity)}
    end
  end

  defp apply_op(%IR{} = ir, {:replace_entity, %Entity{id: id} = entity}) do
    cond do
      not Map.has_key?(ir.entities, id) -> {:error, {:unknown_entity, id}}
      not parent_present?(ir, entity.parent) -> {:error, {:unknown_parent, id, entity.parent}}
      true -> {:ok, put(ir, entity)}
    end
  end

  defp apply_op(%IR{} = ir, {:remove_entity, id}) do
    cond do
      not Map.has_key?(ir.entities, id) ->
        {:error, {:unknown_entity, id}}

      Enum.any?(ir.entities, fn {_key, entity} -> entity.parent == id end) ->
        {:error, {:has_children, id}}

      true ->
        {:ok, %IR{ir | entities: Map.delete(ir.entities, id)}}
    end
  end

  defp apply_op(%IR{} = ir, {:set_parent, id, parent}) do
    with {:ok, %Entity{} = entity} <- IR.fetch(ir, id) do
      case parent_present?(ir, parent) do
        true -> {:ok, put(ir, %Entity{entity | parent: parent})}
        false -> {:error, {:unknown_parent, id, parent}}
      end
    end
  end

  defp apply_op(%IR{} = ir, {:set_transform, id, %Transform{} = transform}) do
    with {:ok, %Entity{} = entity} <- IR.fetch(ir, id) do
      {:ok, put(ir, %Entity{entity | transform: transform})}
    end
  end

  defp apply_op(%IR{} = ir, {:set_visible, id, visible}) when is_boolean(visible) do
    with {:ok, %Entity{} = entity} <- IR.fetch(ir, id) do
      {:ok, put(ir, %Entity{entity | visible: visible})}
    end
  end

  defp apply_op(%IR{} = ir, {:set_pickable, id, pickable}) when is_boolean(pickable) do
    with {:ok, %Entity{} = entity} <- IR.fetch(ir, id) do
      {:ok, put(ir, %Entity{entity | pickable: pickable})}
    end
  end

  defp apply_op(%IR{} = ir, {:set_material, id, material}) do
    update_data(ir, id, :model, fn %Model{} = model -> %Model{model | material: material} end)
  end

  defp apply_op(%IR{} = ir, {:set_animation, id, animation}) do
    update_data(ir, id, :model, fn %Model{} = model -> %Model{model | animation: animation} end)
  end

  defp apply_op(%IR{} = ir, {:set_camera, id, %Camera{} = camera}) do
    update_data(ir, id, :camera, fn %Camera{} -> camera end)
  end

  defp apply_op(%IR{} = ir, {:set_light, id, %Light{} = light}) do
    update_data(ir, id, :light, fn %Light{type: type} = current ->
      case type == light.type do
        true -> light
        false -> {:structural_field, :light_type, current}
      end
    end)
  end

  defp apply_op(%IR{} = ir, {:set_environment, id, %Environment{} = environment}) do
    update_data(ir, id, :environment, fn %Environment{} = current ->
      case current.ibl == environment.ibl and current.skybox == environment.skybox do
        true -> environment
        false -> {:structural_field, :environment_assets, current}
      end
    end)
  end

  defp apply_op(_ir, op), do: {:error, {:unknown_op, op}}

  defp put(%IR{} = ir, %Entity{id: id} = entity),
    do: %IR{ir | entities: Map.put(ir.entities, id, entity)}

  defp parent_present?(_ir, nil), do: true
  defp parent_present?(ir, parent), do: Map.has_key?(ir.entities, parent)

  # Applies `fun` to the entity's data when its kind matches; a kind mismatch
  # or a smuggled structural change is an error, never a silent no-op.
  defp update_data(ir, id, expected_kind, fun) do
    with {:ok, %Entity{} = entity} <- IR.fetch(ir, id) do
      case IR.kind(entity) do
        ^expected_kind ->
          case fun.(entity.data) do
            {:structural_field, field, _current} -> {:error, {:structural_field, id, field}}
            data -> {:ok, put(ir, %Entity{entity | data: data})}
          end

        _other_kind ->
          {:error, {:kind_mismatch, id, expected_kind}}
      end
    end
  end

  # ── diff internals ──────────────────────────────────────────────────────────

  # Structural = the native applier must destroy and recreate resources:
  # a kind change, a model's asset, a light's type, an environment's KTX refs.
  defp structural_change?(%Entity{data: a}, %Entity{data: b}) do
    case {a, b} do
      {%Model{asset: asset_a}, %Model{asset: asset_b}} -> asset_a != asset_b
      {%Light{type: type_a}, %Light{type: type_b}} -> type_a != type_b
      {%Environment{} = env_a, %Environment{} = env_b} -> environment_refs_changed?(env_a, env_b)
      {same, same} -> false
      {left, right} -> kind_module(left) != kind_module(right)
    end
  end

  defp environment_refs_changed?(env_a, env_b),
    do: env_a.ibl != env_b.ibl or env_a.skybox != env_b.skybox

  defp kind_module(nil), do: nil
  defp kind_module(%module{}), do: module

  defp frame_ops(id, a, b) do
    base =
      []
      |> maybe_op(a.transform != b.transform, {:set_transform, id, b.transform})
      |> maybe_op(a.visible != b.visible, {:set_visible, id, b.visible})
      |> maybe_op(a.pickable != b.pickable, {:set_pickable, id, b.pickable})

    base ++ data_ops(id, a.data, b.data)
  end

  defp maybe_op(ops, false, _op), do: ops
  defp maybe_op(ops, true, op), do: ops ++ [op]

  defp data_ops(id, %Model{} = a, %Model{} = b) do
    []
    |> maybe_op(a.material != b.material, {:set_material, id, b.material})
    |> maybe_op(a.animation != b.animation, {:set_animation, id, b.animation})
  end

  defp data_ops(id, %Camera{} = a, %Camera{} = b),
    do: maybe_op([], a != b, {:set_camera, id, b})

  defp data_ops(id, %Light{} = a, %Light{} = b),
    do: maybe_op([], a != b, {:set_light, id, b})

  defp data_ops(id, %Environment{} = a, %Environment{} = b),
    do: maybe_op([], a != b, {:set_environment, id, b})

  defp data_ops(_id, nil, nil), do: []
end
