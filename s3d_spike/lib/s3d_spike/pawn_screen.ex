defmodule S3dSpike.PawnScreen do
  @moduledoc """
  Scoped-material acceptance screen (bead mob_scene3d-bqc): the Chopaat
  two-tone pawn contract, driven end to end. `pawn.glb` ships TWO named
  glTF materials — `pawn_body` (near-white, player-tintable) and
  `pawn_accent` (authored ivory that must NOT take the tint). The screen
  mounts with the player tint scoped to `pawn_body`; the accent band at
  the collar/tip must stay ivory.

  Test-driven over distribution — send to the `:mob_screen` process:

    * `{:s3d_mat, :set, material}` — set `Model.material` on the pawn
      (a `%Material{}`, a list of scoped `%Material{}`, or nil to clear)
    * `{:s3d_mat, :commit_raw, ops, reply_to}` — bypass the diff and ship
      raw ops at the NIF (for the synchronous unknown-material probe and
      the unknown-op skew probe)

  Async scene errors land newest-first in the `:errors` assign — readable
  via `Mob.Test.assigns/1`, which is how the host battery asserts the
  async half of the unknown_material honesty.
  """
  use Mob.Screen

  alias Mob.Scene3d.IR
  alias Mob.Scene3d.IR.{Camera, Entity, Light, Material, Model, Transform}

  # The Chopaat 4p vermilion, scoped to the tintable body material only.
  @body_tint %Material{base_color: {0.8, 0.15, 0.02, 1.0}, scope: "pawn_body"}

  def mount(_params, _session, socket) do
    {:ok,
     Mob.Socket.assign(socket,
       material: @body_tint,
       scene: base_scene(@body_tint),
       errors: []
     )}
  end

  def render(assigns) do
    ~MOB"""
    <Column background={:background} padding={:space_lg}>
      <Text text="Pawn (scoped material)" text_size={:xl} text_color={:on_surface} padding={:space_sm} />
      <Text
        text="pawn.glb — pawn_body tinted, pawn_accent authored ivory"
        text_size={:sm}
        text_color={:muted}
        padding={4}
      />
      <Spacer size={8} />
      {Mob.Scene3d.viewport(id: :pawn_vp, ir: assigns.scene, width: 340, height: 420)}
      <Spacer size={12} />
      <Button id={:back} label="Back" on_tap={{self(), :back}} />
    </Column>
    """
  end

  def handle_info({:tap, :back}, socket) do
    {:noreply, Mob.Socket.pop_screen(socket)}
  end

  def handle_info({:s3d_mat, :set, material}, socket) do
    {:noreply, Mob.Socket.assign(socket, material: material, scene: base_scene(material))}
  end

  # Honest-error probe: ship raw ops straight at the NIF, bypassing the diff
  # (the diff never produces bad ops, so honesty needs a side door).
  def handle_info({:s3d_mat, :commit_raw, ops, reply_to}, socket) do
    patch = Mob.Scene3d.Wire.encode_patch(ops)

    result =
      with {:ok, reply} <- Mob.Scene3d.Native.impl().apply_patch("pawn_vp", patch) do
        Mob.Scene3d.Wire.decode_result(reply)
      end

    send(reply_to, {:s3d_mat_raw_result, result})
    {:noreply, socket}
  end

  def handle_info({:scene3d_error, viewport_id, error}, socket) do
    {:noreply, Mob.Socket.assign(socket, errors: [{viewport_id, error} | socket.assigns.errors])}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  # The pawn is a 26 mm-wide, 40.6 mm-tall beehive (body y 0..0.0325 m at
  # scale 8, accent collar+cap topping out at 0.352 m). Scaled 8x with the
  # camera level at (0, 0.16, 0.6) looking down -Z, the tinted body fills
  # the lower half of the 340x420 viewport and the ivory cap sits around
  # y~=25..50 dp — both regions comfortably samplable.
  defp base_scene(material) do
    IR.new([
      %Entity{
        id: "cam",
        transform: %Transform{position: {0.0, 0.16, 0.6}},
        data: %Camera{fov_y: 40.0, near: 0.05, far: 50.0}
      },
      %Entity{
        id: "sun",
        transform: Transform.from_euler({-45.0, 15.0, 0.0}),
        data: %Light{
          type: :directional,
          intensity: 110_000.0,
          color: {1.0, 0.98, 0.92},
          cast_shadows: false
        }
      },
      %Entity{
        id: "pawn",
        pickable: true,
        transform: %Transform{scale: {8.0, 8.0, 8.0}},
        data: %Model{asset: "pawn.glb", material: material}
      }
    ])
  end
end
