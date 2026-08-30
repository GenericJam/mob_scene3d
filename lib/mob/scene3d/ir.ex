defmodule Mob.Scene3d.IR.Transform do
  @moduledoc """
  Local transform, decomposed TRS — never a raw matrix.

  TRS diffs per component, interpolates, and matches glTF's node transform
  exactly; the native applier composes it into the `mat4f` Filament's
  `TransformManager` wants. Rotation is a unit quaternion `{x, y, z, w}` on
  the wire; `from_euler/2` is the degrees-facing sugar.

  Position in meters, right-handed +Y-up (the one documented convention).
  """

  defstruct position: {0.0, 0.0, 0.0}, rotation: {0.0, 0.0, 0.0, 1.0}, scale: {1.0, 1.0, 1.0}

  @type vec3 :: {number(), number(), number()}
  @type quat :: {number(), number(), number(), number()}
  @type t :: %__MODULE__{position: vec3(), rotation: quat(), scale: vec3()}

  @doc """
  Build a transform from XYZ Euler angles in degrees (applied X, then Y, then
  Z — glTF/Blender's default order), for callers that think in degrees.

      iex> %Mob.Scene3d.IR.Transform{rotation: {x, y, z, w}} =
      ...>   Mob.Scene3d.IR.Transform.from_euler({0.0, 90.0, 0.0})
      iex> Float.round(y, 4)
      0.7071
      iex> {Float.round(x, 4), Float.round(z, 4), Float.round(w, 4)}
      {0.0, 0.0, 0.7071}
  """
  @spec from_euler(vec3(), keyword()) :: t()
  def from_euler({x_deg, y_deg, z_deg}, opts \\ []) do
    {cx, sx} = half_trig(x_deg)
    {cy, sy} = half_trig(y_deg)
    {cz, sz} = half_trig(z_deg)

    rotation = {
      sx * cy * cz + cx * sy * sz,
      cx * sy * cz - sx * cy * sz,
      cx * cy * sz + sx * sy * cz,
      cx * cy * cz - sx * sy * sz
    }

    %__MODULE__{
      position: Keyword.get(opts, :position, {0.0, 0.0, 0.0}),
      rotation: rotation,
      scale: Keyword.get(opts, :scale, {1.0, 1.0, 1.0})
    }
  end

  defp half_trig(degrees) do
    radians = degrees * :math.pi() / 360.0
    {:math.cos(radians), :math.sin(radians)}
  end

  @doc false
  @spec validate(term()) :: :ok | {:error, term()}
  def validate(%__MODULE__{position: p, rotation: r, scale: s}) do
    cond do
      not vec3?(p) -> {:error, {:invalid_position, p}}
      not quat?(r) -> {:error, {:invalid_rotation, r}}
      not vec3?(s) -> {:error, {:invalid_scale, s}}
      true -> :ok
    end
  end

  def validate(other), do: {:error, {:invalid_transform, other}}

  defp vec3?({x, y, z}), do: is_number(x) and is_number(y) and is_number(z)
  defp vec3?(_other), do: false

  defp quat?({x, y, z, w}),
    do: is_number(x) and is_number(y) and is_number(z) and is_number(w)

  defp quat?(_other), do: false
end

defmodule Mob.Scene3d.IR.Material do
  @moduledoc """
  Per-entity overrides of glTF-authored PBR material factors.

  `nil` fields mean "keep what the asset authored" — an override is a sparse
  tint, not a full material. The v1 subset is exactly what Chopaat piece
  tinting needs: base color, metallic/roughness factors, emissive. New
  parameters are grammar extensions (new fields + a caps bump), never
  silently-ignored extra keys — see the decision record's version-skew
  section.

  All color components are linear floats `0.0..1.0` (glTF factor semantics).
  """

  defstruct base_color: nil, metallic: nil, roughness: nil, emissive: nil

  @type rgba :: {number(), number(), number(), number()}
  @type rgb :: {number(), number(), number()}
  @type t :: %__MODULE__{
          base_color: rgba() | nil,
          metallic: number() | nil,
          roughness: number() | nil,
          emissive: rgb() | nil
        }

  @doc false
  @spec validate(term()) :: :ok | {:error, term()}
  def validate(%__MODULE__{} = material) do
    cond do
      not (is_nil(material.base_color) or rgba?(material.base_color)) ->
        {:error, {:invalid_base_color, material.base_color}}

      not (is_nil(material.metallic) or unit?(material.metallic)) ->
        {:error, {:metallic_out_of_range, material.metallic}}

      not (is_nil(material.roughness) or unit?(material.roughness)) ->
        {:error, {:roughness_out_of_range, material.roughness}}

      not (is_nil(material.emissive) or rgb?(material.emissive)) ->
        {:error, {:invalid_emissive, material.emissive}}

      true ->
        :ok
    end
  end

  def validate(other), do: {:error, {:invalid_material, other}}

  defp unit?(value), do: is_number(value) and value >= 0 and value <= 1

  defp rgb?({r, g, b}), do: unit?(r) and unit?(g) and unit?(b)
  defp rgb?(_other), do: false

  defp rgba?({r, g, b, a}), do: unit?(r) and unit?(g) and unit?(b) and unit?(a)
  defp rgba?(_other), do: false
end

defmodule Mob.Scene3d.IR.Animation do
  @moduledoc """
  Declarative playback state for one named glTF animation on a model.

  Everything here is *state*, not commands — triggering is expressed by
  changing `play_id`: the diff sees a new `play_id` and the applier (re)starts
  the named clip, so "play it again" is `%{anim | play_id: unique}` in
  assigns, exactly the render-is-a-function-of-state model Mob screens use.

  When a non-looping clip completes, native delivers `{:animation_done,
  play_id}` to the owning screen process (the Chopaat cowrie-throw contract,
  bead `mob_scene3d-al6`).

  `seek` is an absolute clip time in seconds; a changed value seeks without
  restarting. `speed` is a rate multiplier; `paused` freezes the clock.
  """

  @enforce_keys [:name, :play_id]
  defstruct [:name, :play_id, loop: false, speed: 1.0, paused: false, seek: nil]

  @type t :: %__MODULE__{
          name: String.t(),
          play_id: String.t(),
          loop: boolean(),
          speed: number(),
          paused: boolean(),
          seek: number() | nil
        }

  @doc false
  @spec validate(term()) :: :ok | {:error, term()}
  def validate(%__MODULE__{} = animation) do
    cond do
      not (is_binary(animation.name) and animation.name != "") ->
        {:error, {:invalid_animation_name, animation.name}}

      not (is_binary(animation.play_id) and animation.play_id != "") ->
        {:error, {:invalid_play_id, animation.play_id}}

      not is_boolean(animation.loop) ->
        {:error, {:invalid_loop, animation.loop}}

      not (is_number(animation.speed) and animation.speed > 0) ->
        {:error, {:invalid_speed, animation.speed}}

      not is_boolean(animation.paused) ->
        {:error, {:invalid_paused, animation.paused}}

      not (is_nil(animation.seek) or (is_number(animation.seek) and animation.seek >= 0)) ->
        {:error, {:invalid_seek, animation.seek}}

      true ->
        :ok
    end
  end

  def validate(other), do: {:error, {:invalid_animation, other}}
end

defmodule Mob.Scene3d.IR.Model do
  @moduledoc """
  A glTF asset instance. `asset` is a logical ref resolved against the app's
  `priv/scene3d_assets` (`.glb` only — see README); it is **structural**:
  changing it is a remove-and-recreate on the native side, expressed as a
  `:replace_entity` in the patch grammar. `material` and `animation` are
  per-frame.
  """

  @enforce_keys [:asset]
  defstruct [:asset, material: nil, animation: nil]

  @type t :: %__MODULE__{
          asset: String.t(),
          material: Mob.Scene3d.IR.Material.t() | nil,
          animation: Mob.Scene3d.IR.Animation.t() | nil
        }

  @doc false
  @spec validate(term()) :: :ok | {:error, term()}
  def validate(%__MODULE__{} = model) do
    with :ok <- validate_asset(model.asset),
         :ok <- validate_material(model.material) do
      validate_animation(model.animation)
    end
  end

  def validate(other), do: {:error, {:invalid_model, other}}

  defp validate_asset(asset) when is_binary(asset) and asset != "", do: :ok
  defp validate_asset(asset), do: {:error, {:invalid_asset, asset}}

  defp validate_material(nil), do: :ok
  defp validate_material(material), do: Mob.Scene3d.IR.Material.validate(material)

  defp validate_animation(nil), do: :ok
  defp validate_animation(animation), do: Mob.Scene3d.IR.Animation.validate(animation)
end

defmodule Mob.Scene3d.IR.Camera do
  @moduledoc """
  Perspective camera. Pose comes from the owning entity's transform (the
  camera looks down its local -Z, glTF convention); `fov_y` is the vertical
  field of view in degrees; aspect comes from the viewport at apply time and
  is deliberately absent here. At most one camera per scene in v1.

  All fields are per-frame.
  """

  defstruct fov_y: 45.0, near: 0.1, far: 100.0

  @type t :: %__MODULE__{fov_y: number(), near: number(), far: number()}

  @doc false
  @spec validate(term()) :: :ok | {:error, term()}
  def validate(%__MODULE__{fov_y: fov_y, near: near, far: far}) do
    cond do
      not (is_number(fov_y) and fov_y > 0 and fov_y < 180) -> {:error, {:invalid_fov_y, fov_y}}
      not (is_number(near) and near > 0) -> {:error, {:invalid_near, near}}
      not (is_number(far) and far > near) -> {:error, {:invalid_far, far}}
      true -> :ok
    end
  end

  def validate(other), do: {:error, {:invalid_camera, other}}
end

defmodule Mob.Scene3d.IR.Light do
  @moduledoc """
  A punctual light. `type` is **structural** (Filament fixes it at build
  time); intensity, color, shadows, and the spot/point geometry are per-frame.

  Photometric units, matching Filament: lux for `:directional`, lumens for
  `:point` and `:spot`. Direction and position come from the owning entity's
  transform (a directional light shines down its local -Z).
  """

  @enforce_keys [:type, :intensity]
  defstruct [
    :type,
    :intensity,
    color: {1.0, 1.0, 1.0},
    cast_shadows: false,
    falloff: nil,
    spot_inner: nil,
    spot_outer: nil
  ]

  @type light_type :: :directional | :point | :spot
  @type t :: %__MODULE__{
          type: light_type(),
          intensity: number(),
          color: Mob.Scene3d.IR.Material.rgb(),
          cast_shadows: boolean(),
          falloff: number() | nil,
          spot_inner: number() | nil,
          spot_outer: number() | nil
        }

  @doc false
  @spec validate(term()) :: :ok | {:error, term()}
  def validate(%__MODULE__{} = light) do
    cond do
      light.type not in [:directional, :point, :spot] ->
        {:error, {:invalid_light_type, light.type}}

      not (is_number(light.intensity) and light.intensity >= 0) ->
        {:error, {:invalid_intensity, light.intensity}}

      not rgb?(light.color) ->
        {:error, {:invalid_light_color, light.color}}

      not is_boolean(light.cast_shadows) ->
        {:error, {:invalid_cast_shadows, light.cast_shadows}}

      not valid_falloff?(light) ->
        {:error, {:invalid_falloff, light.falloff}}

      not valid_cone?(light) ->
        {:error, {:invalid_spot_cone, {light.spot_inner, light.spot_outer}}}

      true ->
        :ok
    end
  end

  def validate(other), do: {:error, {:invalid_light, other}}

  defp rgb?({r, g, b}), do: is_number(r) and is_number(g) and is_number(b)
  defp rgb?(_other), do: false

  # Falloff radius (meters) applies to point/spot only.
  defp valid_falloff?(%{type: :directional, falloff: falloff}), do: is_nil(falloff)

  defp valid_falloff?(%{falloff: falloff}),
    do: is_nil(falloff) or (is_number(falloff) and falloff > 0)

  # Cone angles (degrees) apply to spot only; both or neither.
  defp valid_cone?(%{type: :spot, spot_inner: nil, spot_outer: nil}), do: true

  defp valid_cone?(%{type: :spot, spot_inner: inner, spot_outer: outer}) do
    is_number(inner) and is_number(outer) and inner > 0 and outer >= inner and outer <= 180
  end

  defp valid_cone?(%{spot_inner: inner, spot_outer: outer}), do: is_nil(inner) and is_nil(outer)
end

defmodule Mob.Scene3d.IR.Environment do
  @moduledoc """
  Image-based lighting and skybox. `ibl` and `skybox` are logical refs to
  `cmgen`-precomputed KTX bundles under `priv/scene3d_assets/env/`; both are
  **structural**. `intensity` (lux) is per-frame. At most one environment per
  scene (Filament binds one `IndirectLight` and one `Skybox` per scene).
  """

  defstruct ibl: nil, skybox: nil, intensity: 30_000.0

  @type t :: %__MODULE__{
          ibl: String.t() | nil,
          skybox: String.t() | nil,
          intensity: number()
        }

  @doc false
  @spec validate(term()) :: :ok | {:error, term()}
  def validate(%__MODULE__{} = environment) do
    cond do
      not ref?(environment.ibl) ->
        {:error, {:invalid_ibl, environment.ibl}}

      not ref?(environment.skybox) ->
        {:error, {:invalid_skybox, environment.skybox}}

      is_nil(environment.ibl) and is_nil(environment.skybox) ->
        {:error, :empty_environment}

      not intensity?(environment.intensity) ->
        {:error, {:invalid_intensity, environment.intensity}}

      true ->
        :ok
    end
  end

  def validate(other), do: {:error, {:invalid_environment, other}}

  defp ref?(ref), do: is_nil(ref) or (is_binary(ref) and ref != "")
  defp intensity?(intensity), do: is_number(intensity) and intensity >= 0
end

defmodule Mob.Scene3d.IR.Entity do
  @moduledoc """
  One node in the scene forest. `data` decides the kind (`nil` = group);
  `parent` is an id reference (`nil` = root). `pickable` opts a model into ray
  picking; `visible` toggles rendering without destroying native resources.
  """

  alias Mob.Scene3d.IR.{Camera, Environment, Light, Model, Transform}

  @enforce_keys [:id]
  defstruct [
    :id,
    parent: nil,
    transform: %Transform{},
    visible: true,
    pickable: false,
    data: nil
  ]

  @type data :: Model.t() | Camera.t() | Light.t() | Environment.t() | nil

  @type t :: %__MODULE__{
          id: Mob.Scene3d.IR.id(),
          parent: Mob.Scene3d.IR.id() | nil,
          transform: Transform.t(),
          visible: boolean(),
          pickable: boolean(),
          data: data()
        }

  @doc false
  @spec validate(term()) :: :ok | {:error, term()}
  def validate(%__MODULE__{} = entity) do
    cond do
      not (is_binary(entity.id) and entity.id != "") ->
        {:error, {:invalid_id, entity.id}}

      not (is_nil(entity.parent) or (is_binary(entity.parent) and entity.parent != "")) ->
        {:error, {:invalid_parent, entity.parent}}

      not is_boolean(entity.visible) ->
        {:error, {:invalid_visible, entity.visible}}

      not is_boolean(entity.pickable) ->
        {:error, {:invalid_pickable, entity.pickable}}

      entity.pickable and not match?(%Model{}, entity.data) ->
        {:error, :pickable_requires_model}

      true ->
        validate_parts(entity)
    end
  end

  def validate(other), do: {:error, {:invalid_entity, other}}

  defp validate_parts(entity) do
    case Transform.validate(entity.transform) do
      :ok -> validate_data(entity.data)
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_data(nil), do: :ok
  defp validate_data(%Model{} = model), do: Model.validate(model)
  defp validate_data(%Camera{} = camera), do: Camera.validate(camera)
  defp validate_data(%Light{} = light), do: Light.validate(light)
  defp validate_data(%Environment{} = environment), do: Environment.validate(environment)
  defp validate_data(other), do: {:error, {:invalid_data, other}}
end

defmodule Mob.Scene3d.IR do
  @moduledoc """
  The scene intermediate representation: a Mob 3D scene as pure data.

  A scene is a flat map of entities keyed by id, with parenting expressed as
  `parent` references — a forest, not a nested tree. Flat maps diff cheaply
  (the patch grammar in `Mob.Scene3d.IR.Patch` is keyed by id) and make the
  applied-scene readback (`scene/1`) directly comparable to the intent.

  Conventions — decided once, per the parity rule (see
  `decisions/2026-08-30-scene-ir.md`):

    * **Coordinates:** right-handed, +Y up, -Z forward. Matches glTF 2.0 and
      Filament exactly; nothing is converted anywhere.
    * **Units:** meters. Angles in the IR are degrees at the API surface
      (`Transform.from_euler/2`), quaternions on the wire.
    * **Ids:** non-empty binaries. Component-layer sugar may accept atoms but
      must normalize before the IR boundary; `validate/1` rejects anything
      else so intent and readback can never disagree about identity.
    * **Colors:** linear floats `0.0..1.0`, matching glTF material factors.

  `validate/1` is pure and total over terms: it never raises, and it returns
  the *first* structural problem as an honest `{:error, reason}` — never a
  silent fixup.

  ## Example

      iex> alias Mob.Scene3d.IR
      iex> alias Mob.Scene3d.IR.{Entity, Model, Transform}
      iex> ir =
      ...>   IR.new([
      ...>     %Entity{id: "board", data: %Model{asset: "board.glb"}},
      ...>     %Entity{
      ...>       id: "piece_1",
      ...>       parent: "board",
      ...>       data: %Model{asset: "piece.glb"},
      ...>       transform: %Transform{position: {0.5, 0.0, -0.5}}
      ...>     }
      ...>   ])
      iex> IR.validate(ir)
      :ok
  """

  alias Mob.Scene3d.IR.{Camera, Entity, Environment, Light, Model}

  defstruct entities: %{}

  @typedoc "Entity identity: a non-empty binary, stable across frames."
  @type id :: String.t()

  @typedoc "A validation failure. The first problem found, never a fixup."
  @type error ::
          {:invalid_id, term()}
          | {:id_mismatch, id(), term()}
          | {:invalid_entity, id(), term()}
          | {:unknown_parent, id(), id()}
          | {:parent_cycle, [id()]}
          | {:multiple_cameras, [id()]}
          | {:multiple_environments, [id()]}

  @type t :: %__MODULE__{entities: %{id() => Entity.t()}}

  @doc """
  An empty scene.

      iex> Mob.Scene3d.IR.empty().entities
      %{}
  """
  @spec empty() :: t()
  def empty, do: %__MODULE__{}

  @doc """
  Build an IR from a list of entities. Does not validate — `validate/1` is a
  separate, pure step so callers control when the cost is paid.

  Raises `ArgumentError` on duplicate ids: two entities claiming one id is a
  construction bug, not a scene state.

      iex> alias Mob.Scene3d.IR.Entity
      iex> ir = Mob.Scene3d.IR.new([%Entity{id: "a"}, %Entity{id: "b", parent: "a"}])
      iex> Map.keys(ir.entities) |> Enum.sort()
      ["a", "b"]
  """
  @spec new([Entity.t()]) :: t()
  def new(entities) when is_list(entities) do
    map =
      Enum.reduce(entities, %{}, fn %Entity{id: id} = entity, acc ->
        case acc do
          %{^id => _existing} -> raise ArgumentError, "duplicate entity id: #{inspect(id)}"
          _acc -> Map.put(acc, id, entity)
        end
      end)

    %__MODULE__{entities: map}
  end

  @doc """
  Fetch an entity by id.

      iex> alias Mob.Scene3d.IR.Entity
      iex> ir = Mob.Scene3d.IR.new([%Entity{id: "a"}])
      iex> Mob.Scene3d.IR.fetch(ir, "a")
      {:ok, %Entity{id: "a"}}
      iex> Mob.Scene3d.IR.fetch(ir, "ghost")
      {:error, {:unknown_entity, "ghost"}}
  """
  @spec fetch(t(), id()) :: {:ok, Entity.t()} | {:error, {:unknown_entity, id()}}
  def fetch(%__MODULE__{entities: entities}, id) do
    case entities do
      %{^id => entity} -> {:ok, entity}
      _entities -> {:error, {:unknown_entity, id}}
    end
  end

  @doc """
  Validate a scene. Pure; returns `:ok` or the first problem found.

  Checks, in order: id shape and key/id agreement, per-entity field validity,
  parent references, parent cycles, and the scene-wide singletons (at most one
  camera, at most one environment — Filament renders through one camera and
  one IBL/skybox per scene; see the decision record).

      iex> alias Mob.Scene3d.IR.{Entity, Model}
      iex> Mob.Scene3d.IR.validate(Mob.Scene3d.IR.empty())
      :ok

      iex> alias Mob.Scene3d.IR.Entity
      iex> ir = Mob.Scene3d.IR.new([%Entity{id: "a", parent: "ghost"}])
      iex> Mob.Scene3d.IR.validate(ir)
      {:error, {:unknown_parent, "a", "ghost"}}

      iex> alias Mob.Scene3d.IR.Entity
      iex> ir = Mob.Scene3d.IR.new([%Entity{id: "a", parent: "b"}, %Entity{id: "b", parent: "a"}])
      iex> Mob.Scene3d.IR.validate(ir)
      {:error, {:parent_cycle, ["a", "b"]}}

      iex> alias Mob.Scene3d.IR.{Entity, Material, Model}
      iex> bad = %Material{metallic: 1.5}
      iex> ir = Mob.Scene3d.IR.new([%Entity{id: "m", data: %Model{asset: "x.glb", material: bad}}])
      iex> Mob.Scene3d.IR.validate(ir)
      {:error, {:invalid_entity, "m", {:metallic_out_of_range, 1.5}}}
  """
  @spec validate(t()) :: :ok | {:error, error()}
  def validate(%__MODULE__{entities: entities}) do
    with :ok <- validate_ids(entities),
         :ok <- validate_entities(entities),
         :ok <- validate_parents(entities),
         :ok <- validate_cycles(entities) do
      validate_singletons(entities)
    end
  end

  @doc """
  The kind of an entity, derived from its data payload — there is no separate
  kind field to fall out of sync.

      iex> alias Mob.Scene3d.IR.{Entity, Light}
      iex> Mob.Scene3d.IR.kind(%Entity{id: "sun", data: %Light{type: :directional, intensity: 100_000.0}})
      :light
      iex> Mob.Scene3d.IR.kind(%Entity{id: "rig"})
      :group
  """
  @spec kind(Entity.t()) :: :model | :camera | :light | :environment | :group
  def kind(%Entity{data: %Model{}}), do: :model
  def kind(%Entity{data: %Camera{}}), do: :camera
  def kind(%Entity{data: %Light{}}), do: :light
  def kind(%Entity{data: %Environment{}}), do: :environment
  def kind(%Entity{data: nil}), do: :group

  @doc """
  Depth of an entity in the parent forest (roots are 0). Used by the patch
  grammar to order adds parents-first and removals children-first. Assumes a
  validated (acyclic) scene.
  """
  @spec depth(t(), id()) :: non_neg_integer()
  def depth(%__MODULE__{entities: entities}, id), do: do_depth(entities, id, 0)

  defp do_depth(entities, id, acc) do
    case entities do
      %{^id => %Entity{parent: nil}} -> acc
      %{^id => %Entity{parent: parent}} -> do_depth(entities, parent, acc + 1)
      _entities -> acc
    end
  end

  # ── validation internals ───────────────────────────────────────────────────

  defp validate_ids(entities) do
    Enum.find_value(entities, :ok, fn {key, entity} ->
      cond do
        not valid_id?(key) -> {:error, {:invalid_id, key}}
        not match?(%Entity{}, entity) -> {:error, {:invalid_entity, key, :not_an_entity}}
        entity.id != key -> {:error, {:id_mismatch, key, entity.id}}
        true -> nil
      end
    end)
  end

  defp valid_id?(id), do: is_binary(id) and id != ""

  defp validate_entities(entities) do
    Enum.find_value(entities, :ok, fn {id, entity} ->
      case Entity.validate(entity) do
        :ok -> nil
        {:error, reason} -> {:error, {:invalid_entity, id, reason}}
      end
    end)
  end

  defp validate_parents(entities) do
    Enum.find_value(entities, :ok, fn {id, %Entity{parent: parent}} ->
      cond do
        is_nil(parent) -> nil
        parent == id -> {:error, {:parent_cycle, [id]}}
        Map.has_key?(entities, parent) -> nil
        true -> {:error, {:unknown_parent, id, parent}}
      end
    end)
  end

  defp validate_cycles(entities) do
    entities
    |> Map.keys()
    |> Enum.find_value(:ok, fn id ->
      case walk_to_root(entities, id, MapSet.new()) do
        :ok -> nil
        {:cycle, ids} -> {:error, {:parent_cycle, Enum.sort(ids)}}
      end
    end)
  end

  defp walk_to_root(entities, id, seen) do
    cond do
      MapSet.member?(seen, id) -> {:cycle, MapSet.to_list(seen)}
      is_nil(entities[id]) or is_nil(entities[id].parent) -> :ok
      true -> walk_to_root(entities, entities[id].parent, MapSet.put(seen, id))
    end
  end

  defp validate_singletons(entities) do
    cameras = ids_of_kind(entities, Camera)
    environments = ids_of_kind(entities, Environment)

    cond do
      match?([_, _ | _], cameras) -> {:error, {:multiple_cameras, cameras}}
      match?([_, _ | _], environments) -> {:error, {:multiple_environments, environments}}
      true -> :ok
    end
  end

  defp ids_of_kind(entities, module) do
    entities
    |> Enum.filter(fn {_id, %Entity{data: data}} -> is_struct(data, module) end)
    |> Enum.map(fn {id, _entity} -> id end)
    |> Enum.sort()
  end
end
