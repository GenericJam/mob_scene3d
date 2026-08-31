defmodule Mob.Scene3d.Native do
  @moduledoc """
  The NIF boundary, as a behaviour so host tests can mock it.

  The real implementation (`Mob.Scene3d.Native.NIF`) forwards to
  `:mob_scene3d_nif`; every function returns `{:ok, json_binary}` from the
  native side or `{:error, :nif_not_loaded}` when the native half is absent
  (host/dev BEAM, or a version-skewed device build that predates this
  library — the mob #111-shaped guard the version-skew section of the IR
  decision record calls for).

  All native replies are JSON binaries decoded by `Mob.Scene3d.Wire`; the
  boundary stays byte-oriented so the mock in host tests exercises the same
  decode path the device does.
  """

  @callback caps() :: {:ok, binary()} | {:error, :nif_not_loaded}
  @callback apply_patch(viewport_id :: binary(), patch_json :: binary()) ::
              {:ok, binary()} | {:error, :nif_not_loaded}
  @callback request_scene(viewport_id :: binary(), request_id :: binary()) ::
              {:ok, binary()} | {:error, :nif_not_loaded}
  @callback destroy(viewport_id :: binary()) :: {:ok, binary()} | {:error, :nif_not_loaded}

  @doc "The configured implementation (mocked in host tests via app env)."
  @spec impl() :: module()
  def impl, do: Application.get_env(:mob_scene3d, :native, Mob.Scene3d.Native.NIF)
end

defmodule Mob.Scene3d.Native.NIF do
  @moduledoc false
  @behaviour Mob.Scene3d.Native

  @impl true
  def caps, do: call(fn -> :mob_scene3d_nif.scene3d_caps() end)

  @impl true
  def apply_patch(viewport_id, patch_json) when is_binary(viewport_id) and is_binary(patch_json),
    do: call(fn -> :mob_scene3d_nif.scene3d_apply(viewport_id, patch_json) end)

  @impl true
  def request_scene(viewport_id, request_id)
      when is_binary(viewport_id) and is_binary(request_id),
      do: call(fn -> :mob_scene3d_nif.scene3d_scene(viewport_id, request_id) end)

  @impl true
  def destroy(viewport_id) when is_binary(viewport_id),
    do: call(fn -> :mob_scene3d_nif.scene3d_destroy(viewport_id) end)

  defp call(fun) do
    {:ok, fun.()}
  rescue
    # erlang:nif_error(nif_not_loaded) — the stub loaded without its native
    # half. Honest degradation, never a crash in the render path.
    ErlangError -> {:error, :nif_not_loaded}
  end
end
