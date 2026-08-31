defmodule Mob.Scene3d.NativeMock do
  @moduledoc """
  Test double for the NIF boundary.

  `Mob.Scene3d` calls the native impl from the caller's process, so the mock
  keeps its script and its call log in the **process dictionary** — tests
  stay `async: true` and cannot see each other's traffic. `test_helper.exs`
  installs this module as the `:native` impl for the whole suite.
  """
  @behaviour Mob.Scene3d.Native

  alias Mob.Scene3d.Wire

  @calls :scene3d_native_calls
  @script :scene3d_native_script

  @doc """
  Override a reply: `stub(:apply_patch, {:ok, ~s({\"error\":[...]})})`.
  A function reply is called with the NIF args (in the caller's process, so
  it can `send(self(), ...)` to simulate async native messages).
  """
  def stub(fun, reply) when is_atom(fun) do
    Process.put(@script, Map.put(Process.get(@script, %{}), fun, reply))
    :ok
  end

  @doc "Calls made from this process, oldest first."
  def calls, do: Process.get(@calls, []) |> Enum.reverse()

  @doc "Decoded ops of the nth (default: only) shipped patch."
  def shipped_ops(index \\ 0) do
    patches = for {:apply_patch, _vid, patch} <- calls(), do: patch
    patches |> Enum.at(index) |> Wire.decode!() |> Map.fetch!("ops")
  end

  @impl true
  def caps do
    record({:caps})

    default =
      {:ok,
       %{
         "schema" => Wire.schema(),
         "ops" => Wire.v1_op_names(),
         "features" => ["material_scope"]
       }
       |> :json.encode()
       |> IO.iodata_to_binary()}

    scripted(:caps, default)
  end

  @impl true
  def apply_patch(viewport_id, patch_json) do
    record({:apply_patch, viewport_id, patch_json})
    scripted(:apply_patch, {:ok, ~s({"ok":true})})
  end

  @impl true
  def request_scene(viewport_id, request_id) do
    record({:request_scene, viewport_id, request_id})
    scripted_call(:request_scene, [viewport_id, request_id], {:ok, ~s({"ok":true})})
  end

  @impl true
  def destroy(viewport_id) do
    record({:destroy, viewport_id})
    scripted(:destroy, {:ok, ~s({"ok":true})})
  end

  @impl true
  def pick(viewport_id, query_json) do
    record({:pick, viewport_id, query_json})
    scripted_call(:pick, [viewport_id, query_json], {:ok, ~s({"ok":true})})
  end

  @impl true
  def sample(viewport_id, query_json) do
    record({:sample, viewport_id, query_json})
    scripted_call(:sample, [viewport_id, query_json], {:ok, ~s({"ok":true})})
  end

  @impl true
  def frame_stats(viewport_id, request_id) do
    record({:frame_stats, viewport_id, request_id})
    scripted_call(:frame_stats, [viewport_id, request_id], {:ok, ~s({"ok":true})})
  end

  @impl true
  def viewports do
    record({:viewports})
    scripted(:viewports, {:ok, ~s({"viewports":[]})})
  end

  defp record(call), do: Process.put(@calls, [call | Process.get(@calls, [])])

  defp scripted(fun, default), do: Process.get(@script, %{}) |> Map.get(fun, default)

  # Two-arg NIF entries accept function scripts (called with the NIF args in
  # the caller's process, so they can send(self(), ...) the async reply).
  defp scripted_call(fun, args, default) do
    case Process.get(@script, %{}) do
      %{^fun => script} when is_function(script, 2) -> apply(script, args)
      %{^fun => reply} -> reply
      _script -> default
    end
  end
end
