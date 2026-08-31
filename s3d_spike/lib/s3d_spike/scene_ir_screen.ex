defmodule S3dSpike.SceneIrScreen do
  @moduledoc """
  Plugin-core acceptance screen (beads mob_scene3d-t05 / mob_scene3d-nhf):
  drives the real mob_scene3d plugin — the scene lives in assigns as an
  `%Mob.Scene3d.IR{}`, `Mob.Scene3d.viewport/1` hosts the native Filament
  surface, and every render diffs against the last committed IR and ships
  only the patch over the NIF wire.

  Test-driven over distribution: send `{:s3d, ...}` messages to the
  `:mob_screen` process —

    * `{:s3d, :set_scene, %IR{}}` — replace the whole scene intent
    * `{:s3d, :move, id, {x, y, z}}` — reposition one entity
    * `{:s3d, :spin, id, degrees}` — set a Y rotation on one entity
    * `{:s3d, :remove, id}` — drop an entity
    * `{:s3d, :commit_raw, ops}` — bypass the diff and ship raw ops (for
      honest-error probes: unknown ids, bad patches)
    * `{:s3d, :spin_loop, n}` — per-frame move loop: n renders ~16 ms apart
      rotating the probe (frame_stats under load)
    * `{:s3d, :set_pickable, id, bool}` — flip pick participation

  `Mob.Scene3d.scene/1` readback runs via `:rpc` from the host. Picks on
  the pickable probe arrive as `{:probe_picked, id}` (the `on_pick:` tag)
  and accumulate in the `:picks` assign, newest first — readable via
  `Mob.Test.assigns/1`. The decoy model is `pickable: false`: tapping it
  must leave `:picks` untouched (the honest-miss ruling).
  """
  use Mob.Screen

  alias Mob.Scene3d.IR
  alias Mob.Scene3d.IR.{Camera, Entity, Light, Material, Model, Transform}

  def mount(_params, _session, socket) do
    {:ok,
     Mob.Socket.assign(socket,
       scene: base_scene(),
       last_error: nil,
       picks: [],
       spin_left: 0
     )}
  end

  def render(assigns) do
    ~MOB"""
    <Column background={:background} padding={:space_lg}>
      <Text text="Scene IR (plugin)" text_size={:xl} text_color={:on_surface} padding={:space_sm} />
      <Text
        text="probe.glb — mob_scene3d plugin core"
        text_size={:sm}
        text_color={:muted}
        padding={4}
      />
      <Spacer size={8} />
      {Mob.Scene3d.viewport(
        id: :probe_vp,
        ir: assigns.scene,
        width: 340,
        height: 420,
        on_pick: :probe_picked
      )}
      <Spacer size={12} />
      <Button id={:back} label="Back" on_tap={{self(), :back}} />
    </Column>
    """
  end

  def handle_info({:tap, :back}, socket) do
    {:noreply, Mob.Socket.pop_screen(socket)}
  end

  def handle_info({:s3d, :set_scene, %IR{} = scene}, socket) do
    {:noreply, Mob.Socket.assign(socket, scene: scene)}
  end

  def handle_info({:s3d, :move, id, {_x, _y, _z} = position}, socket) do
    updater = fn %Entity{transform: %Transform{} = transform} = entity ->
      %Entity{entity | transform: %Transform{transform | position: position}}
    end

    {:noreply, update_entity(socket, id, updater)}
  end

  def handle_info({:s3d, :spin, id, degrees}, socket) do
    %Transform{rotation: rotation} = Transform.from_euler({0.0, degrees * 1.0, 0.0})

    updater = fn %Entity{transform: %Transform{} = transform} = entity ->
      %Entity{entity | transform: %Transform{transform | rotation: rotation}}
    end

    {:noreply, update_entity(socket, id, updater)}
  end

  def handle_info({:s3d, :remove, id}, socket) do
    scene = %IR{entities: Map.delete(socket.assigns.scene.entities, id)}
    {:noreply, Mob.Socket.assign(socket, scene: scene)}
  end

  # Honest-error probe: ship raw ops straight at the NIF, bypassing the diff
  # (the diff never produces bad ops, so honesty needs a side door).
  def handle_info({:s3d, :commit_raw, ops, reply_to}, socket) do
    patch = Mob.Scene3d.Wire.encode_patch(ops)

    result =
      with {:ok, reply} <- Mob.Scene3d.Native.impl().apply_patch("probe_vp", patch) do
        Mob.Scene3d.Wire.decode_result(reply)
      end

    send(reply_to, {:s3d_raw_result, result})
    {:noreply, socket}
  end

  def handle_info({:probe_picked, entity_id}, socket) do
    {:noreply, Mob.Socket.assign(socket, picks: [entity_id | socket.assigns.picks])}
  end

  def handle_info({:s3d, :set_pickable, id, pickable?}, socket) do
    updater = fn %Entity{} = entity -> %Entity{entity | pickable: pickable?} end
    {:noreply, update_entity(socket, id, updater)}
  end

  # Per-frame move loop: one re-render (one commit) every ~16 ms, rotating
  # the probe 6°/frame — the frame_stats-under-load probe.
  def handle_info({:s3d, :spin_loop, frames}, socket) when is_integer(frames) do
    send(self(), :s3d_spin_tick)
    {:noreply, Mob.Socket.assign(socket, spin_left: frames)}
  end

  def handle_info(:s3d_spin_tick, socket) do
    case socket.assigns.spin_left do
      n when n <= 0 ->
        {:noreply, socket}

      n ->
        Process.send_after(self(), :s3d_spin_tick, 16)
        %Transform{rotation: rotation} = Transform.from_euler({0.0, n * 6.0, 0.0})

        socket =
          update_entity(socket, "probe", fn %Entity{transform: %Transform{} = transform} =
                                              entity ->
            %Entity{entity | transform: %Transform{transform | rotation: rotation}}
          end)

        {:noreply, Mob.Socket.assign(socket, spin_left: n - 1)}
    end
  end

  def handle_info({:scene3d_error, viewport_id, error}, socket) do
    {:noreply, Mob.Socket.assign(socket, last_error: {viewport_id, error})}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp update_entity(socket, id, fun) do
    case socket.assigns.scene.entities do
      %{^id => %Entity{} = entity} ->
        scene = %IR{entities: Map.put(socket.assigns.scene.entities, id, fun.(entity))}
        Mob.Socket.assign(socket, scene: scene)

      _entities ->
        socket
    end
  end

  defp base_scene do
    IR.new([
      # probe.glb is a 10 cm cube sitting on the origin; scaled 4x below it
      # spans 0.4 m centered at y=0.2. The camera looks down its local -Z
      # (identity rotation) from just above cube-center height.
      %Entity{
        id: "cam",
        transform: %Transform{position: {0.0, 0.25, 1.6}},
        data: %Camera{fov_y: 40.0, near: 0.05, far: 100.0}
      },
      %Entity{
        id: "sun",
        transform: Transform.from_euler({-40.0, 25.0, 0.0}),
        data: %Light{
          type: :directional,
          intensity: 110_000.0,
          color: {1.0, 0.98, 0.92},
          cast_shadows: true
        }
      },
      %Entity{id: "rig"},
      # The pick/sampler target: strongly red-tinted so sample_region's
      # dominant channel check is unambiguous against the dark blue skybox.
      %Entity{
        id: "probe",
        parent: "rig",
        pickable: true,
        transform: %Transform{position: {-0.3, 0.0, 0.0}, scale: {4.0, 4.0, 4.0}},
        data: %Model{
          asset: "probe.glb",
          material: %Material{base_color: {0.9, 0.05, 0.05, 1.0}, roughness: 0.8}
        }
      },
      # Same mesh, pickable: false — tapping it must be a miss (no event,
      # pick/3 → {:no_entity_at_point, x, y}).
      %Entity{
        id: "decoy",
        transform: %Transform{position: {0.3, 0.0, 0.0}, scale: {4.0, 4.0, 4.0}},
        data: %Model{asset: "probe.glb"}
      }
    ])
  end
end
