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
       %{"schema" => Wire.schema(), "ops" => Wire.v1_op_names()}
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

    case Process.get(@script, %{}) do
      %{request_scene: fun} when is_function(fun, 2) -> fun.(viewport_id, request_id)
      %{request_scene: reply} -> reply
      _script -> {:ok, ~s({"ok":true})}
    end
  end

  @impl true
  def destroy(viewport_id) do
    record({:destroy, viewport_id})
    scripted(:destroy, {:ok, ~s({"ok":true})})
  end

  defp record(call), do: Process.put(@calls, [call | Process.get(@calls, [])])

  defp scripted(fun, default), do: Process.get(@script, %{}) |> Map.get(fun, default)
end
