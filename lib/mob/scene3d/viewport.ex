defmodule Mob.Scene3d.Viewport do
  @moduledoc """
  The `Mob.Component` hosting a Filament viewport.

  Owns the diff/commit cycle: the screen passes the scene IR as the `:ir`
  prop on every render, and this component diffs it against the last
  **committed** IR held in its own state — so coalesced re-renders diff
  against what actually reached the native applier, never against dropped
  intents. Only `render/1`'s output (`viewport_id`, `width`, `height`)
  rides the 2D JSON tree; scene content crosses on the dedicated NIF wire.

  Teardown rides mob #111 component reclamation: when the owning screen
  exits (or the viewport leaves the tree), `terminate/2` destroys the
  native scene state — running even when a user callback raises, before the
  screen's own `terminate/2`. Re-entering the screen mounts a fresh
  component and bootstraps the scene from `IR.empty()` again.

  Native registration key (module name, dots → underscores):
  `"Mob_Scene3d_Viewport"`.
  """
  use Mob.Component

  require Logger

  alias Mob.Scene3d.IR

  @impl true
  def mount(props, socket) do
    viewport_id = props |> Map.fetch!(:id) |> to_string()

    socket =
      Mob.Socket.assign(socket,
        viewport_id: viewport_id,
        width: props[:width] || 340,
        height: props[:height] || 420,
        pick_tag: props[:on_pick] || :pick,
        anim_tag: props[:on_animation_done] || :animation_done,
        screen_pid: props[:screen_pid],
        committed: IR.empty()
      )

    {:ok, commit(socket, props[:ir])}
  end

  @impl true
  def update(props, socket) do
    socket =
      Mob.Socket.assign(socket,
        width: props[:width] || socket.assigns.width,
        height: props[:height] || socket.assigns.height,
        pick_tag: props[:on_pick] || socket.assigns.pick_tag,
        anim_tag: props[:on_animation_done] || socket.assigns.anim_tag,
        screen_pid: props[:screen_pid] || socket.assigns.screen_pid
      )

    {:ok, commit(socket, props[:ir])}
  end

  @impl true
  def render(assigns) do
    %{
      viewport_id: assigns.viewport_id,
      width: assigns.width,
      height: assigns.height
    }
  end

  @impl true
  def handle_info(message, socket) do
    # Async native events (asset load failures after a structurally-valid
    # patch applied, surface attach notices, resolved picks) land here
    # because this process made the NIF calls. Nothing is swallowed silently.
    case message do
      {:scene3d_pick_event, _viewport_id, entity_id} ->
        # Native only delivers hits on pickable models (misses are silence,
        # per the pick decision addendum); re-tag with the screen's
        # configured on_pick and forward — the screen's handle_info/2 sees
        # {tag, entity_id}, matching mob's tap event grammar.
        case socket.assigns do
          %{screen_pid: screen_pid, pick_tag: tag} when is_pid(screen_pid) ->
            send(screen_pid, {tag, entity_id})

          _assigns ->
            Logger.warning("[scene3d] pick event with no owning screen: #{inspect(entity_id)}")
        end

      {:scene3d_animation_done, _viewport_id, play_id} ->
        # A non-looping clip reached its end: re-tag with the screen's
        # configured on_animation_done (default :animation_done, so the
        # out-of-box message is the decision record's {:animation_done,
        # play_id}) and forward — play_id is the correlation token the
        # screen set when it started the clip.
        case socket.assigns do
          %{screen_pid: screen_pid, anim_tag: tag} when is_pid(screen_pid) ->
            send(screen_pid, {tag, play_id})

          _assigns ->
            Logger.warning("[scene3d] animation_done with no owning screen: #{inspect(play_id)}")
        end

      {:scene3d_error, viewport_id, error} ->
        Logger.error("[scene3d] viewport #{viewport_id}: #{inspect(error)}")

      {:scene3d_ready, viewport_id} ->
        Logger.info("[scene3d] viewport #{viewport_id}: surface attached")

      other ->
        Logger.warning("[scene3d] unexpected message: #{inspect(other)}")
    end

    {:noreply, socket}
  end

  @impl true
  def terminate(_reason, socket) do
    case socket.assigns do
      %{viewport_id: viewport_id} -> Mob.Scene3d.destroy(viewport_id)
      _assigns -> :ok
    end
  end

  defp commit(socket, nil), do: commit(socket, IR.empty())

  defp commit(socket, %IR{} = ir) do
    %{viewport_id: viewport_id, committed: committed} = socket.assigns

    case Mob.Scene3d.commit(viewport_id, committed, ir) do
      {:ok, committed} ->
        Mob.Socket.assign(socket, committed: committed)

      {:error, reason} ->
        # The committed IR is NOT advanced: the native scene stayed at its
        # last good frame (atomic reject-all), so the next render diffs
        # against truth. Loud, never silent.
        Logger.error("[scene3d] viewport #{viewport_id}: commit rejected: #{inspect(reason)}")

        socket
    end
  end
end
