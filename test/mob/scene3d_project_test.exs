defmodule Mob.Scene3dProjectTest do
  # bead mob_scene3d-xzh: end-to-end tests for Mob.Scene3d.project/N.
  # The pure-math half is in Mob.Scene3d.ProjectionTest; this file pins
  # the scene decoding + error surface + the through-the-mock native flow.
  use ExUnit.Case, async: false

  # Scene shape: two entities, a camera at world +Z=5 and a model at the
  # world origin. Both carry world_transform in Filament's flat 16-float
  # column-major format the applier emits.
  @scene %{
    "entities" => %{
      "camera" => %{
        "data" => %{"kind" => "camera", "fov_y" => 90.0, "near" => 0.1, "far" => 100.0},
        "world_transform" => [
          1.0,
          0.0,
          0.0,
          0.0,
          0.0,
          1.0,
          0.0,
          0.0,
          0.0,
          0.0,
          1.0,
          0.0,
          0.0,
          0.0,
          5.0,
          1.0
        ]
      },
      "model" => %{
        "data" => %{"kind" => "model"},
        "world_transform" => [
          1.0,
          0.0,
          0.0,
          0.0,
          0.0,
          1.0,
          0.0,
          0.0,
          0.0,
          0.0,
          1.0,
          0.0,
          0.0,
          0.0,
          0.0,
          1.0
        ]
      }
    }
  }

  describe "project_from_scene/3" do
    test "an entity at the world origin projects to the viewport centre" do
      {:ok, %{x: x, y: y, in_frame?: true}} =
        Mob.Scene3d.project_from_scene(@scene, "model", {400.0, 300.0})

      assert_in_delta x, 200.0, 1.0e-6
      assert_in_delta y, 150.0, 1.0e-6
    end

    test "unknown entity id → {:error, {:no_entity, id}}" do
      assert Mob.Scene3d.project_from_scene(@scene, "nope", {400.0, 300.0}) ==
               {:error, {:no_entity, "nope"}}
    end

    test "scene without a camera → {:error, :no_camera}" do
      no_cam =
        update_in(@scene, ["entities"], fn ents -> Map.delete(ents, "camera") end)

      assert Mob.Scene3d.project_from_scene(no_cam, "model", {400.0, 300.0}) ==
               {:error, :no_camera}
    end

    test "scene without entities → {:error, {:bad_scene, :no_entities}}" do
      assert Mob.Scene3d.project_from_scene(%{"other" => 1}, "model", {400.0, 300.0}) ==
               {:error, {:bad_scene, :no_entities}}
    end

    test "an entity missing world_transform projects from identity" do
      # An entity that has committed but hasn't received its first world
      # transform back (fresh apply, hasn't ticked) reads as at world
      # origin. The result mirrors that assumption instead of raising.
      partial =
        put_in(@scene, ["entities", "model"], %{"data" => %{"kind" => "model"}})

      {:ok, %{x: x, y: y}} =
        Mob.Scene3d.project_from_scene(partial, "model", {400.0, 300.0})

      assert_in_delta x, 200.0, 1.0e-6
      assert_in_delta y, 150.0, 1.0e-6
    end
  end

  describe "project/3 device-local" do
    # The device-local shape goes through Mob.Scene3d.Native.impl().request_scene
    # to fetch the scene reply. Swap the impl for a stub that returns our
    # canned JSON, then verify the full pipeline decodes correctly.
    setup do
      original = Application.get_env(:mob_scene3d, :native)
      Application.put_env(:mob_scene3d, :native, __MODULE__.NativeStub)

      # Handshake: request_scene returns {:ok, "\"ok\""} synchronously and
      # then sends the scene reply as a message to the caller. Mimic that.
      pid = self()

      :persistent_term.put(
        {__MODULE__, :scene_delivery},
        fn viewport_id, request_id ->
          send(
            pid,
            {:scene3d_scene, viewport_id, request_id,
             :json.encode(@scene) |> IO.iodata_to_binary()}
          )
        end
      )

      on_exit(fn ->
        :persistent_term.erase({__MODULE__, :scene_delivery})
        if original, do: Application.put_env(:mob_scene3d, :native, original)
      end)

      :ok
    end

    test "projects through the mock native to the correct pixel" do
      assert {:ok, %{x: x, y: y, in_frame?: true}} =
               Mob.Scene3d.project("vp_test", "model", {400.0, 300.0})

      assert_in_delta x, 200.0, 1.0e-6
      assert_in_delta y, 150.0, 1.0e-6
    end

    test "returns an :no_viewport error when the scene call returns one" do
      # Override the delivery to skip sending — scene() will time out. The
      # await_reply path returns :timeout in that shape.
      :persistent_term.put({__MODULE__, :scene_delivery}, fn _, _ -> :ok end)

      assert Mob.Scene3d.project("vp_test", "model", {400.0, 300.0}, 200) ==
               {:error, :timeout}
    end
  end

  # Native mock: satisfy Mob.Scene3d.Native's behaviour, deliver a canned
  # scene, degrade every other function to :nif_not_loaded (the tests don't
  # care).
  defmodule NativeStub do
    @behaviour Mob.Scene3d.Native

    @impl true
    def caps, do: {:ok, ~s({"schema":1,"ops":[],"features":[]})}

    @impl true
    def apply_patch(_vp, _patch), do: {:error, :nif_not_loaded}

    @impl true
    def request_scene(viewport_id, request_id) do
      deliver =
        :persistent_term.get({Mob.Scene3dProjectTest, :scene_delivery}, fn _, _ -> :ok end)

      deliver.(viewport_id, request_id)
      {:ok, ~s({"ok":true})}
    end

    @impl true
    def destroy(_vp), do: {:ok, ~s({"ok":true})}

    @impl true
    def pick(_vp, _q), do: {:error, :nif_not_loaded}

    @impl true
    def sample(_vp, _q), do: {:error, :nif_not_loaded}

    @impl true
    def frame_stats(_vp, _r), do: {:error, :nif_not_loaded}

    @impl true
    def viewports, do: {:ok, ~s({"viewports":["vp_test"]})}
  end
end
