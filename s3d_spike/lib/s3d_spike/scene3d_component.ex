defmodule S3dSpike.Scene3dComponent do
  @moduledoc """
  Filament embedding spike — `Mob.Component` wrapping a native Filament
  view that renders a spinning .glb with a directional light.

  Native registry key (module name, dots -> underscores):
  `"S3dSpike_Scene3dComponent"`. The native side reads `asset_path`
  (an absolute on-device path to a .glb, resolved from this app's priv)
  plus `width`/`height` in dp/pt, and fires a `"ready"` event after the
  first frame renders — honest evidence the surface is alive, not just
  that the view mounted.
  """
  use Mob.Component

  @impl true
  def mount(props, socket) do
    asset =
      props[:asset_path] ||
        Application.app_dir(:s3d_spike, "priv/models/bevel_cube.glb")

    {:ok,
     Mob.Socket.assign(socket,
       asset_path: asset,
       width: props[:width] || 340,
       height: props[:height] || 420,
       ready: false,
       frames: 0
     )}
  end

  @impl true
  def update(_props, socket), do: {:ok, socket}

  @impl true
  def render(assigns) do
    %{
      asset_path: assigns.asset_path,
      width: assigns.width,
      height: assigns.height
    }
  end

  @impl true
  def handle_event("ready", payload, socket) do
    {:noreply, Mob.Socket.assign(socket, ready: true, frames: payload["frames"] || 1)}
  end
end
