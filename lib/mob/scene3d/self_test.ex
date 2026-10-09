defmodule Mob.Scene3d.SelfTest do
  @moduledoc """
  The plugin's on-device proof (`Mob.Plugin.SelfTest`), run by
  `mix mob.selftest` and mob_ci for every activated plugin.

  Two native round trips over the NIF wire, no viewport and no GPU:

    1. `scene3d_caps/0` must answer the caps JSON for this library's wire
       schema (`Mob.Scene3d.Wire.schema/0`), listing `remove_entity` and no
       op outside the v1 grammar. On Android that answer comes from the
       Kotlin `Scene3dRuntime` through JNI, so it also proves the bridge
       registered; an unregistered bridge answers
       `{"error":["bridge_unregistered"]}` and fails.
    2. `scene3d_apply/2` on a scratch viewport id with a patch that removes
       an entity that does not exist must be rejected by the native shadow
       registry with `unknown_entity` naming that id. That runs the native
       side's synchronous patch validation (the atomic reject-all every
       real patch goes through) without queueing anything for Filament.
       `scene3d_destroy/1` then clears the scratch viewport's state.

  The host stub's `nif_not_loaded` (no native half linked) is a failure.
  Nothing is rendered: proving Filament draws needs an attached viewport,
  which is the host's screen, not this test.
  """
  @behaviour Mob.Plugin.SelfTest

  alias Mob.Scene3d.{Native, Wire}

  @viewport "mob_scene3d_selftest"
  @ghost "mob_scene3d_selftest_ghost"

  @impl true
  def run(_ctx) do
    native = Native.impl()

    with :ok <- check_caps(native.caps()),
         :ok <- check_reject(native.apply_patch(@viewport, ghost_patch())) do
      check_destroy(native.destroy(@viewport))
    end
  end

  @doc false
  # The patch the native shadow registry must refuse: remove an unknown entity.
  @spec ghost_patch() :: binary()
  def ghost_patch, do: Wire.encode_patch([{:remove_entity, @ghost}])

  @doc false
  @spec check_caps({:ok, binary()} | {:error, term()}) :: :ok | Mob.Plugin.SelfTest.result()
  def check_caps({:error, :nif_not_loaded}) do
    {:fail, "mob_scene3d_nif is not linked into this build: scene3d_caps/0 raised nif_not_loaded"}
  end

  def check_caps({:ok, json}) do
    schema = Wire.schema()

    case Wire.decode_caps(json) do
      {:ok, %{schema: ^schema, ops: ops}} ->
        extra = MapSet.difference(ops, MapSet.new(Wire.v1_op_names()))

        cond do
          not MapSet.member?(ops, "remove_entity") ->
            {:fail, "scene3d_caps/0 answered #{json}, which does not list remove_entity"}

          MapSet.size(extra) > 0 ->
            {:fail,
             "scene3d_caps/0 lists ops outside the v1 grammar: #{inspect(Enum.sort(extra))}"}

          true ->
            :ok
        end

      {:ok, %{schema: other}} ->
        {:fail, "scene3d_caps/0 answered wire schema #{other}, this library speaks #{schema}"}

      {:error, _} ->
        {:fail, "scene3d_caps/0 answered #{json}, expected the caps JSON#{bridge_hint(json)}"}
    end
  end

  @doc false
  @spec check_reject({:ok, binary()} | {:error, term()}) :: :ok | Mob.Plugin.SelfTest.result()
  def check_reject({:error, :nif_not_loaded}) do
    {:fail,
     "mob_scene3d_nif is not linked into this build: scene3d_apply/2 raised nif_not_loaded"}
  end

  def check_reject({:ok, json}) do
    case Wire.decode_result(json) do
      {:error, {:unknown_entity, @ghost}} ->
        :ok

      :ok ->
        {:fail,
         "scene3d_apply/2 accepted removing the unknown entity #{inspect(@ghost)}: " <>
           "the native shadow registry did not validate the patch"}

      _ ->
        {:fail,
         "scene3d_apply/2 answered #{json}, expected " <>
           "{\"error\":[\"unknown_entity\",#{inspect(@ghost)}]}#{bridge_hint(json)}"}
    end
  end

  @doc false
  @spec check_destroy({:ok, binary()} | {:error, term()}) :: Mob.Plugin.SelfTest.result()
  def check_destroy({:ok, json}) do
    case Wire.decode_result(json) do
      :ok -> :pass
      _ -> {:fail, "scene3d_destroy/1 answered #{json}, expected {\"ok\":true}"}
    end
  end

  def check_destroy(other), do: {:fail, "scene3d_destroy/1 returned #{inspect(other)}"}

  defp bridge_hint(json) do
    if json =~ "bridge_unregistered",
      do: " (Kotlin MobScene3dBridge not registered: nativeRegister never ran)",
      else: ""
  end
end
