defmodule S3dSpike.Scene3dScreen do
  @moduledoc """
  Filament embedding spike screen (bead mob_scene3d-b9g): hosts the
  native Filament view via `Mob.UI.native_view/2`.
  """
  use Mob.Screen

  def mount(_params, _session, socket) do
    {:ok, Mob.Socket.assign(socket, title: "Filament spike")}
  end

  def render(assigns) do
    ~MOB"""
    <Column background={:background} padding={:space_lg}>
      <Text text={assigns.title} text_size={:xl} text_color={:on_surface} padding={:space_sm} />
      <Text
        text="bevel_cube.glb — Filament v1.75.1"
        text_size={:sm}
        text_color={:muted}
        padding={4}
      />
      <Spacer size={12} />
      {Mob.UI.native_view(S3dSpike.Scene3dComponent, id: :scene3d, width: 340, height: 420)}
    </Column>
    """
  end
end
