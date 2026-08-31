defmodule Mob.Scene3d.Wire do
  @moduledoc """
  The NIF wire encoding for scene patches: a versioned JSON envelope
  carrying an array of op arrays, one per `Mob.Scene3d.IR.Patch` op, in the
  canonical order `Patch.diff/2` emitted them.

  The Elixir-side patch grammar is canonical (see
  `decisions/2026-08-30-scene-ir.md`); this module fixes the byte-level
  layout the native appliers parse. Both directions live here so encode and
  decode cannot drift apart:

    * `encode_patch/1` — ops → `{"schema": 1, "ops": [[...], ...]}` iodata
    * `decode_result/1` — native reply JSON → `:ok | {:error, reason}` with
      the reason mapped back into the decision record's error taxonomy as
      tuples of atoms/strings (atoms come from fixed whitelists, never
      `String.to_atom/1` on wire data)
    * `decode_caps/1` — native `scene3d_caps` JSON → `%{schema: n, ops:
      MapSet}` for the version-skew guard in `Mob.Scene3d`

  Layout notes:

    * vectors/quaternions/colors are JSON arrays of numbers
    * `nil` is JSON `null` everywhere (a `null` material override means
      "clear the override", matching `{:set_material, id, nil}`)
    * entity `data` carries an explicit `"kind"` so the applier never
      guesses; the Elixir side derives it from the struct module
  """

  alias Mob.Scene3d.IR
  alias Mob.Scene3d.IR.{Animation, Camera, Entity, Environment, Light, Material, Model, Transform}

  @schema 1

  @doc "The wire schema version this library emits."
  @spec schema() :: pos_integer()
  def schema, do: @schema

  @v1_ops ~w(add_entity replace_entity remove_entity set_parent set_transform
             set_visible set_pickable set_material set_animation set_camera
             set_light set_environment)

  @doc "Every op name in the v1 grammar, as wire strings."
  @spec v1_op_names() :: [String.t()]
  def v1_op_names, do: @v1_ops

  @doc """
  Wire name of one op tuple, for the caps guard.

      iex> Mob.Scene3d.Wire.op_name({:remove_entity, "x"})
      "remove_entity"
  """
  @spec op_name(IR.Patch.op()) :: String.t()
  def op_name(op) when is_tuple(op), do: op |> elem(0) |> Atom.to_string()

  # ── encode ──────────────────────────────────────────────────────────────────

  @doc """
  Encode a patch (a list of `Patch.diff/2` ops, canonical order preserved)
  into the versioned JSON envelope as a binary.
  """
  @spec encode_patch([IR.Patch.op()]) :: binary()
  def encode_patch(ops) when is_list(ops) do
    %{"schema" => @schema, "ops" => Enum.map(ops, &encode_op/1)}
    |> :json.encode(&json_value/2)
    |> IO.iodata_to_binary()
  end

  # Erlang's :json encodes the atom `nil` as the string "nil"; the wire wants
  # JSON null (its meaning — "clear this override" — is load-bearing).
  defp json_value(nil, _encoder), do: "null"
  defp json_value(other, encoder), do: :json.encode_value(other, encoder)

  @doc false
  @spec encode_op(IR.Patch.op()) :: list()
  def encode_op({:add_entity, %Entity{} = entity}), do: ["add_entity", entity_json(entity)]

  def encode_op({:replace_entity, %Entity{} = entity}),
    do: ["replace_entity", entity_json(entity)]

  def encode_op({:remove_entity, id}), do: ["remove_entity", id]
  def encode_op({:set_parent, id, parent}), do: ["set_parent", id, parent]

  def encode_op({:set_transform, id, %Transform{} = transform}),
    do: ["set_transform", id, transform_json(transform)]

  def encode_op({:set_visible, id, visible}), do: ["set_visible", id, visible]
  def encode_op({:set_pickable, id, pickable}), do: ["set_pickable", id, pickable]
  def encode_op({:set_material, id, material}), do: ["set_material", id, material_json(material)]

  def encode_op({:set_animation, id, animation}),
    do: ["set_animation", id, animation_json(animation)]

  def encode_op({:set_camera, id, %Camera{} = camera}),
    do: ["set_camera", id, camera_json(camera)]

  def encode_op({:set_light, id, %Light{} = light}), do: ["set_light", id, light_json(light)]

  def encode_op({:set_environment, id, %Environment{} = environment}),
    do: ["set_environment", id, environment_json(environment)]

  defp entity_json(%Entity{} = entity) do
    %{
      "id" => entity.id,
      "parent" => entity.parent,
      "transform" => transform_json(entity.transform),
      "visible" => entity.visible,
      "pickable" => entity.pickable,
      "data" => data_json(entity.data)
    }
  end

  defp data_json(nil), do: nil

  defp data_json(%Model{} = model) do
    %{
      "kind" => "model",
      "asset" => model.asset,
      "material" => material_json(model.material),
      "animation" => animation_json(model.animation)
    }
  end

  defp data_json(%Camera{} = camera), do: Map.put(camera_json(camera), "kind", "camera")
  defp data_json(%Light{} = light), do: Map.put(light_json(light), "kind", "light")

  defp data_json(%Environment{} = environment),
    do: Map.put(environment_json(environment), "kind", "environment")

  defp transform_json(%Transform{position: p, rotation: r, scale: s}) do
    %{"position" => tuple_json(p), "rotation" => tuple_json(r), "scale" => tuple_json(s)}
  end

  defp material_json(nil), do: nil

  defp material_json(%Material{} = material) do
    %{
      "base_color" => maybe_tuple_json(material.base_color),
      "metallic" => material.metallic,
      "roughness" => material.roughness,
      "emissive" => maybe_tuple_json(material.emissive)
    }
  end

  defp animation_json(nil), do: nil

  defp animation_json(%Animation{} = animation) do
    %{
      "name" => animation.name,
      "play_id" => animation.play_id,
      "loop" => animation.loop,
      "speed" => animation.speed,
      "paused" => animation.paused,
      "seek" => animation.seek
    }
  end

  defp camera_json(%Camera{fov_y: fov_y, near: near, far: far}),
    do: %{"fov_y" => fov_y, "near" => near, "far" => far}

  defp light_json(%Light{} = light) do
    %{
      "type" => Atom.to_string(light.type),
      "intensity" => light.intensity,
      "color" => tuple_json(light.color),
      "cast_shadows" => light.cast_shadows,
      "falloff" => light.falloff,
      "spot_inner" => light.spot_inner,
      "spot_outer" => light.spot_outer
    }
  end

  defp environment_json(%Environment{ibl: ibl, skybox: skybox, intensity: intensity}),
    do: %{"ibl" => ibl, "skybox" => skybox, "intensity" => intensity}

  defp tuple_json(tuple), do: tuple |> Tuple.to_list() |> Enum.map(&to_float/1)

  defp maybe_tuple_json(nil), do: nil
  defp maybe_tuple_json(tuple), do: tuple_json(tuple)

  # Uniform floats on the wire: appliers parse one number shape, and 1 vs 1.0
  # never becomes a cross-platform JSON-parser divergence.
  defp to_float(n) when is_integer(n), do: n * 1.0
  defp to_float(n) when is_float(n), do: n

  # ── decode: apply results ──────────────────────────────────────────────────

  # The error taxonomy from the decision record, as wire strings. Fixed
  # whitelist — reasons outside it decode as {:unknown_error, raw} rather
  # than minting atoms from wire data.
  @error_atoms %{
    "duplicate_entity" => :duplicate_entity,
    "unknown_entity" => :unknown_entity,
    "unknown_parent" => :unknown_parent,
    "has_children" => :has_children,
    "kind_mismatch" => :kind_mismatch,
    "structural_field" => :structural_field,
    "unknown_op" => :unknown_op,
    "invalid_result" => :invalid_result,
    "bad_asset" => :bad_asset,
    "unknown_animation" => :unknown_animation,
    "no_entity_at_point" => :no_entity_at_point,
    "unsupported" => :unsupported,
    "no_viewport" => :no_viewport,
    "bad_patch" => :bad_patch
  }

  @kind_atoms %{
    "model" => :model,
    "camera" => :camera,
    "light" => :light,
    "environment" => :environment,
    "group" => :group,
    "animation" => :animation
  }

  @doc """
  Decode a native apply/query reply.

  Native replies `{"ok": true}` or `{"error": [tag, ...args]}`; args stay
  strings/numbers except the small atom positions the taxonomy fixes
  (kinds, field names), which decode through whitelists.

      iex> Mob.Scene3d.Wire.decode_result(~s({"ok":true}))
      :ok
      iex> Mob.Scene3d.Wire.decode_result(~s({"error":["unknown_entity","ghost"]}))
      {:error, {:unknown_entity, "ghost"}}
  """
  @spec decode_result(binary()) :: :ok | {:error, term()}
  def decode_result(json) when is_binary(json) do
    case safe_decode(json) do
      {:ok, %{"ok" => true}} -> :ok
      {:ok, %{"error" => reason}} -> {:error, decode_error(reason)}
      {:ok, other} -> {:error, {:bad_native_reply, other}}
      :error -> {:error, {:bad_native_reply, json}}
    end
  end

  @doc false
  @spec decode_error(term()) :: term()
  def decode_error([tag | args]) when is_binary(tag) do
    case @error_atoms do
      %{^tag => atom} -> decode_tagged(atom, args)
      _map -> {:unknown_error, [tag | args]}
    end
  end

  def decode_error(other), do: {:unknown_error, other}

  defp decode_tagged(:kind_mismatch, [id, kind]),
    do: {:kind_mismatch, id, Map.get(@kind_atoms, kind, kind)}

  defp decode_tagged(:structural_field, [id, field]),
    do: {:structural_field, id, decode_field(field)}

  defp decode_tagged(:unsupported, [feature]),
    do: {:unsupported, Map.get(@kind_atoms, feature, feature)}

  defp decode_tagged(atom, []), do: atom
  defp decode_tagged(atom, args), do: List.to_tuple([atom | args])

  @structural_fields %{
    "light_type" => :light_type,
    "environment_assets" => :environment_assets,
    "asset" => :asset,
    "kind" => :kind
  }

  defp decode_field(field), do: Map.get(@structural_fields, field, field)

  # ── decode: caps ────────────────────────────────────────────────────────────

  @doc """
  Decode the native `scene3d_caps` reply for the version-skew guard.

      iex> Mob.Scene3d.Wire.decode_caps(~s({"schema":1,"ops":["add_entity"]}))
      {:ok, %{schema: 1, ops: MapSet.new(["add_entity"])}}
  """
  @spec decode_caps(binary()) ::
          {:ok, %{schema: pos_integer(), ops: MapSet.t(String.t())}} | {:error, term()}
  def decode_caps(json) when is_binary(json) do
    case safe_decode(json) do
      {:ok, %{"schema" => schema, "ops" => ops}} when is_integer(schema) and is_list(ops) ->
        {:ok, %{schema: schema, ops: MapSet.new(ops)}}

      {:ok, other} ->
        {:error, {:bad_caps, other}}

      :error ->
        {:error, {:bad_caps, json}}
    end
  end

  @doc """
  Decode wire JSON to Elixir terms, mapping JSON `null` to `nil` (Erlang's
  `:json.decode/1` yields the atom `:null`, which nothing on the Elixir side
  speaks). Raises on malformed JSON — internal callers go through
  `safe_decode/1`.
  """
  @spec decode!(binary()) :: term()
  def decode!(json) when is_binary(json), do: json |> :json.decode() |> nullify()

  defp nullify(:null), do: nil
  defp nullify(list) when is_list(list), do: Enum.map(list, &nullify/1)

  defp nullify(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {key, nullify(value)} end)

  defp nullify(other), do: other

  defp safe_decode(json) do
    {:ok, decode!(json)}
  rescue
    _error -> :error
  end
end
