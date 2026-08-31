defmodule S3dSpike.TumbleScreen do
  @moduledoc """
  Animation-playback acceptance screen (bead mob_scene3d-al6): the Chopaat
  cowrie-throw contract, driven end to end. `tumbles.glb` carries 32 named
  tumble clips (`throw_k{count}_v{take}`) that all retarget the seven slot
  nodes `shell_0..shell_6`; the screen plays one by setting a declarative
  `%Mob.Scene3d.IR.Animation{}` on the model — replay is a `play_id` change,
  never a command.

  Test-driven over distribution — send to the `:mob_screen` process:

    * `{:s3d_anim, :play, name, play_id, opts}` — set
      `%Animation{name: name, play_id: play_id}` merged with `opts`
      (`:loop`, `:speed`, `:paused`, `:seek`)
    * `{:s3d_anim, :set, %Animation{} | nil}` — set the raw struct (or clear)
    * `{:s3d_anim, :commit_raw, ops, reply_to}` — bypass the diff and ship
      raw ops at the NIF (for the synchronous unknown-animation probe)

  Completions arrive as `{:throw_settled, play_id}` (the `on_animation_done:`
  tag) and accumulate newest-first in the `:done` assign; async scene errors
  land in `:last_error` — both readable via `Mob.Test.assigns/1`, which is
  how the host-side battery asserts "done fired" and "loop never fires".
  """
  use Mob.Screen

  alias Mob.Scene3d.IR
  alias Mob.Scene3d.IR.{Animation, Camera, Entity, Light, Model, Transform}

  def mount(_params, _session, socket) do
    {:ok,
     Mob.Socket.assign(socket,
       scene: base_scene(nil),
       animation: nil,
       done: [],
       last_error: nil
     )}
  end

  def render(assigns) do
    ~MOB"""
    <Column background={:background} padding={:space_lg}>
      <Text text="Tumble (animation)" text_size={:xl} text_color={:on_surface} padding={:space_sm} />
      <Text
        text="tumbles.glb — 32 named clips retargeting shell_0..shell_6"
        text_size={:sm}
        text_color={:muted}
        padding={4}
      />
      <Spacer size={8} />
      {Mob.Scene3d.viewport(
        id: :tumble_vp,
        ir: assigns.scene,
        width: 340,
        height: 420,
        on_animation_done: :throw_settled
      )}
      <Spacer size={12} />
      <Button id={:back} label="Back" on_tap={{self(), :back}} />
    </Column>
    """
  end

  def handle_info({:tap, :back}, socket) do
    {:noreply, Mob.Socket.pop_screen(socket)}
  end

  def handle_info({:s3d_anim, :play, name, play_id, opts}, socket) do
    animation = %Animation{
      name: name,
      play_id: play_id,
      loop: Keyword.get(opts, :loop, false),
      speed: Keyword.get(opts, :speed, 1.0),
      paused: Keyword.get(opts, :paused, false),
      seek: Keyword.get(opts, :seek)
    }

    {:noreply, set_animation(socket, animation)}
  end

  def handle_info({:s3d_anim, :set, animation}, socket) do
    {:noreply, set_animation(socket, animation)}
  end

  # Honest-error probe: ship raw ops straight at the NIF, bypassing the diff
  # (the diff never produces bad ops, so honesty needs a side door).
  def handle_info({:s3d_anim, :commit_raw, ops, reply_to}, socket) do
    patch = Mob.Scene3d.Wire.encode_patch(ops)

    result =
      with {:ok, reply} <- Mob.Scene3d.Native.impl().apply_patch("tumble_vp", patch) do
        Mob.Scene3d.Wire.decode_result(reply)
      end

    send(reply_to, {:s3d_anim_raw_result, result})
    {:noreply, socket}
  end

  # The on_animation_done tag: play_ids accumulate newest-first so the host
  # battery can assert both arrival (mode :once) and absence (loop).
  def handle_info({:throw_settled, play_id}, socket) do
    {:noreply, Mob.Socket.assign(socket, done: [play_id | socket.assigns.done])}
  end

  def handle_info({:scene3d_error, viewport_id, error}, socket) do
    {:noreply, Mob.Socket.assign(socket, last_error: {viewport_id, error})}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp set_animation(socket, animation) do
    Mob.Socket.assign(socket,
      animation: animation,
      scene: base_scene(animation)
    )
  end

  # The tumbles scene: origin at the board plate top (the manifest contract),
  # shells rest with their origins inside +-0.06 m of it. The camera looks
  # down its local -Z; ~40 degrees down from (0, 0.28, 0.30) frames the
  # plate with the ~2.3 cm shells readable.
  defp base_scene(animation) do
    IR.new([
      %Entity{
        id: "cam",
        transform: Transform.from_euler({-40.0, 0.0, 0.0}, position: {0.0, 0.28, 0.30}),
        data: %Camera{fov_y: 45.0, near: 0.01, far: 50.0}
      },
      %Entity{
        id: "sun",
        transform: Transform.from_euler({-50.0, 20.0, 0.0}),
        data: %Light{
          type: :directional,
          intensity: 110_000.0,
          color: {1.0, 0.98, 0.92},
          cast_shadows: false
        }
      },
      %Entity{
        id: "tumbles",
        data: %Model{asset: "tumbles.glb", animation: animation}
      }
    ])
  end
end
