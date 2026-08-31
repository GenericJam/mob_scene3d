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

  test "a native pick event is re-tagged and forwarded to the owning screen" do
    socket = mounted(%{id: :board, on_pick: :piece_picked, screen_pid: self()})

    {:noreply, _socket} =
      Viewport.handle_info({:scene3d_pick_event, "board", "pawn_red_2"}, socket)

    assert_received {:piece_picked, "pawn_red_2"}
  end

  test "the pick tag defaults to :pick" do
    socket = mounted(%{id: :board, screen_pid: self()})
    {:noreply, _socket} = Viewport.handle_info({:scene3d_pick_event, "board", "probe"}, socket)

    assert_received {:pick, "probe"}
  end

  test "a pick event with no screen pid logs instead of crashing" do
    socket = mounted(%{id: :board})

    log =
      capture_log(fn ->
        {:noreply, _socket} =
          Viewport.handle_info({:scene3d_pick_event, "board", "probe"}, socket)
      end)

    assert log =~ "no owning screen"
    refute_received {:pick, _id}
  end

  test "Mob.Scene3d.viewport/1 refuses a non-atom on_pick tag" do
    assert_raise ArgumentError, ~r/on_pick must be an atom/, fn ->
      Mob.Scene3d.viewport(id: :board, on_pick: "strings_leak")
    end
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
