defmodule Mob.Scene3d.ViewportTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Mob.Scene3d.IR
  alias Mob.Scene3d.IR.{Entity, Model, Transform}
  alias Mob.Scene3d.NativeMock
  alias Mob.Scene3d.Viewport

  defp scene(x) do
    IR.new([
      %Entity{
        id: "probe",
        data: %Model{asset: "probe.glb"},
        transform: %Transform{position: {x, 0.0, 0.0}}
      }
    ])
  end

  defp mounted(props) do
    {:ok, socket} = Viewport.mount(props, %Mob.Socket{})
    socket
  end

  test "mount bootstraps the scene from empty and holds it as committed" do
    socket = mounted(%{id: :board, ir: scene(0.0), width: 300, height: 400})

    assert socket.assigns.committed == scene(0.0)
    assert [["add_entity", %{"id" => "probe"}]] = NativeMock.shipped_ops()

    assert Viewport.render(socket.assigns) == %{
             viewport_id: "board",
             width: 300,
             height: 400
           }
  end

  test "update diffs against the committed IR, not against dropped intents" do
    socket = mounted(%{id: :board, ir: scene(0.0)})
    {:ok, socket} = Viewport.update(%{id: :board, ir: scene(2.0)}, socket)

    assert socket.assigns.committed == scene(2.0)

    assert [["set_transform", "probe", %{"position" => [2.0, +0.0, +0.0]}]] =
             NativeMock.shipped_ops(1)
  end

  test "a rejected commit keeps the previous committed IR and logs loudly" do
    socket = mounted(%{id: :board, ir: scene(0.0)})
    NativeMock.stub(:apply_patch, {:ok, ~s({"error":["unknown_entity","probe"]})})

    log =
      capture_log(fn ->
        {:ok, updated} = Viewport.update(%{id: :board, ir: scene(2.0)}, socket)
        # Committed did not advance: the native scene stayed at its last
        # good frame, so the next diff is computed against truth.
        assert updated.assigns.committed == scene(0.0)
      end)

    assert log =~ "commit rejected"
    assert log =~ "unknown_entity"
  end

  test "a viewport without an :ir prop commits the empty scene" do
    socket = mounted(%{id: :board})
    assert socket.assigns.committed == IR.empty()
    refute Enum.any?(NativeMock.calls(), &match?({:apply_patch, _, _}, &1))
  end

  test "terminate destroys the native viewport state (mob #111 reclamation)" do
    socket = mounted(%{id: :board, ir: scene(0.0)})
    Viewport.terminate(:shutdown, socket)

    assert {:destroy, "board"} in NativeMock.calls()
  end

  test "async native errors are logged, never swallowed" do
    socket = mounted(%{id: :board})

    log =
      capture_log(fn ->
        {:noreply, _socket} =
          Viewport.handle_info({:scene3d_error, "board", {:bad_asset, "x.glb", "enoent"}}, socket)
      end)

    assert log =~ "bad_asset"
  end
end
