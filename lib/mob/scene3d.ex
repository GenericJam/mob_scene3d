defmodule Mob.Scene3d do
  @moduledoc """
  Declarative 3D scenes for Mob apps, rendered by Filament on both platforms.

  The scene is **data in assigns**: the screen holds a `Mob.Scene3d.IR`
  struct and re-renders like any other Mob state change. `viewport/1` hosts
  the native Filament surface as an ordinary `Mob.UI.native_view/2` node; on
  every screen render the `Mob.Scene3d.Viewport` component diffs the new IR
  against the **last committed** IR (`Mob.Scene3d.IR.Patch.diff/2`) and
  ships only the patch over the NIF wire — scene content never rides the 2D
  JSON tree.

      def render(assigns) do
        ~MOB\"\"\"
        <Column>
          {Mob.Scene3d.viewport(id: :board, ir: @scene, width: 340, height: 420)}
        </Column>
        \"\"\"
      end

  ## Threading contract (binding, from the Filament spike)

  BEAM schedulers never call Filament. `commit/3` validates the whole patch
  synchronously against the native applier's shadow registry (pure
  bookkeeping — atomic reject-all before anything touches Filament state)
  and enqueues the validated ops; the platform render thread
  (Choreographer / CADisplayLink) applies them between frames.

  ## Version skew

  Before shipping a patch, `commit/3` consults `scene3d_caps/0` from the
  native side (`caps/0`) and refuses ops the applier does not declare with a
  loud `{:error, {:unsupported, op}}` — degraded loudly, never silently
  (mob #111 posture). Defense in depth: an applier receiving an unknown op
  anyway rejects the whole patch with `{:unknown_op, op}`.
  """

  alias Mob.Scene3d.IR
  alias Mob.Scene3d.IR.{Entity, Model, Patch}
  alias Mob.Scene3d.{Native, Wire}

  @scene_timeout 2_000
  # Host-side rpc wrappers add headroom over the device-local await so the
  # local :timeout (honest, per-query) wins over a blunt :badrpc.
  @rpc_headroom 3_000

  @doc """
  A screen element hosting the native Filament viewport.

  Options:

    * `:id` — atom, required, unique per screen (the `Mob.UI.native_view/2`
      contract). Its string form is the viewport id used everywhere else.
    * `:ir` — the `%Mob.Scene3d.IR{}` to commit, straight from assigns.
      Defaults to the empty scene.
    * `:width` / `:height` — viewport size in dp/pt.
    * `:on_pick` — atom tag for pick events, default `:pick`. A tap on a
      model with `pickable: true` delivers `{tag, entity_id}` to the owning
      screen's `handle_info/2` (mob's configurable-tag grammar, like
      `on_tap`/`on_dismiss`). A tap that hits nothing pickable is **not** an
      event — misses are a query result (`pick/3`), never noise pushed at
      the screen.
  """
  @spec viewport(keyword()) :: map()
  def viewport(opts) when is_list(opts) do
    tag = Keyword.get(opts, :on_pick, :pick)

    unless is_atom(tag) do
      raise ArgumentError, "Mob.Scene3d.viewport :on_pick must be an atom, got: #{inspect(tag)}"
    end

    # render/1 runs in the screen server process, so self() here is the
    # screen pid — the pick-event delivery target the Viewport component
    # forwards to (the component itself lives in its own process).
    opts = opts |> Keyword.put(:on_pick, tag) |> Keyword.put(:screen_pid, self())
    Mob.UI.native_view(Mob.Scene3d.Viewport, opts)
  end

  @doc """
  Diff `next` against `committed` and ship the patch for `viewport_id`.

  Returns `{:ok, next}` (the new committed IR — hold onto it for the next
  commit) or an honest `{:error, reason}`:

    * `{:invalid_scene, reason}` — `next` failed `IR.validate/1`; nothing
      was shipped
    * `{:unsupported, op}` — the native applier's caps do not declare an op
      this patch needs (version skew, degraded loudly)
    * `{:schema_mismatch, native, ours}` — the applier speaks a different
      wire schema
    * `:nif_not_loaded` — no native half (host BEAM, or a device build
      predating this library)
    * any term from the patch error taxonomy, decoded from the native
      reply (`{:unknown_entity, id}`, `{:duplicate_entity, id}`, ...)

  An empty diff ships nothing and returns `{:ok, next}`.
  """
  @spec commit(String.t(), IR.t(), IR.t()) :: {:ok, IR.t()} | {:error, term()}
  def commit(viewport_id, %IR{} = committed, %IR{} = next) when is_binary(viewport_id) do
    with :ok <- validate(next),
         ops when ops != [] <- Patch.diff(committed, next),
         :ok <- guard_ops(ops),
         :ok <- ship(viewport_id, ops) do
      {:ok, next}
    else
      [] -> {:ok, next}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  The native applier capabilities: `{:ok, %{schema: n, ops: MapSet}}`, or
  `{:error, :nif_not_loaded}` on a BEAM without the native half.
  """
  @spec caps() :: {:ok, %{schema: pos_integer(), ops: MapSet.t(String.t())}} | {:error, term()}
  def caps do
    with {:ok, json} <- Native.impl().caps() do
      Wire.decode_caps(json)
    end
  end

  @doc """
  Read back the **applied** scene from the native side — the applier's own
  registry (world transforms, asset load status), not the Elixir intent
  echoed back. Divergence between this and the committed IR is, by
  construction, a wire/applier bug; detecting that is the point.

  Two calling shapes, mirroring `Mob.Test` conventions:

    * `scene(node)` / `scene(node, viewport_id)` — host-side, `node` is the
      device's Erlang node (atom). With no viewport id the single attached
      viewport is used (`{:error, {:multiple_viewports, ids}}` otherwise).
    * `scene(viewport_id, timeout \\\\ #{@scene_timeout})` — device-local.
      Blocks the calling process for the round-trip (the reply rides the
      next render tick).

  Returns `{:ok, scene_map}` with string keys mirroring the wire encoding,
  or an honest error (`{:no_viewport, id}` before the surface attaches,
  `:timeout`, ...).
  """
  @spec scene(node() | String.t(), String.t() | timeout()) :: {:ok, map()} | {:error, term()}
  def scene(target, arg \\ @scene_timeout)

  def scene(node, viewport_id) when is_atom(node) and is_binary(viewport_id),
    do: rpc(node, :scene, [viewport_id])

  def scene(node, _default_timeout) when is_atom(node) do
    with {:ok, viewport_id} <- default_viewport(node), do: scene(node, viewport_id)
  end

  def scene(viewport_id, timeout) when is_binary(viewport_id) do
    request_id = new_request_id()

    with {:ok, reply} <- Native.impl().request_scene(viewport_id, request_id),
         :ok <- Wire.decode_result(reply) do
      await_reply(:scene3d_scene, viewport_id, request_id, timeout)
    end
  end

  @doc """
  Ray-pick the scene at viewport-local `{x, y}` (dp/pt, origin top-left) —
  the same render-thread `View::pick` the `{tag, entity_id}` touch events
  ride, so test-time picking and runtime picking cannot disagree. Filament's
  pick is async (the GPU resolves a frame or two later); this call awaits
  the resolution.

  Only models with `pickable: true` participate. Returns `{:ok, entity_id}`
  or the honest miss `{:error, {:no_entity_at_point, x, y}}` — a hit on a
  non-pickable model and a hit on nothing are the same documented miss.

    * `pick(node, x, y)` / `pick(node, viewport_id, x, y)` — host-side.
    * `pick(viewport_id, x, y, timeout \\\\ #{@scene_timeout})` — device-local.
  """
  @spec pick(node() | String.t(), number(), number()) ::
          {:ok, String.t()} | {:error, term()}
  def pick(node, x, y) when is_atom(node) and is_number(x) and is_number(y) do
    with {:ok, viewport_id} <- default_viewport(node), do: pick(node, viewport_id, x, y)
  end

  def pick(viewport_id, x, y) when is_binary(viewport_id) and is_number(x) and is_number(y),
    do: pick(viewport_id, x, y, @scene_timeout)

  @spec pick(node() | String.t(), String.t() | number(), number(), number() | timeout()) ::
          {:ok, String.t()} | {:error, term()}
  def pick(node, viewport_id, x, y)
      when is_atom(node) and is_binary(viewport_id) and is_number(x) and is_number(y),
      do: rpc(node, :pick, [viewport_id, x, y])

  def pick(viewport_id, x, y, timeout)
      when is_binary(viewport_id) and is_number(x) and is_number(y) do
    request_id = new_request_id()
    query = encode_query(%{"request_id" => request_id, "x" => x * 1.0, "y" => y * 1.0})

    with {:ok, reply} <- Native.impl().pick(viewport_id, query),
         :ok <- Wire.decode_result(reply),
         {:ok, payload} <- await_reply(:scene3d_pick, viewport_id, request_id, timeout) do
      decode_pick(payload, x, y)
    end
  end

  @doc """
  Sample the pixels the 3D viewport actually rendered — GPU readback via
  Filament `readPixels` on the render thread. Window capture **cannot** see
  the 3D surface (the SurfaceView blindspot, spike evidence), so this is the
  pixel-truth primitive for 3D; the rect is viewport-local dp/pt
  `{x, y, w, h}`, origin top-left.

  Returns the same shape as `Mob.Test.sample_color/2` (it reduces through
  `Mob.Test.reduce_rgba/3`): `{:ok, %{average: 0xAARRGGBB, dominant: _,
  dominant_share: _, distinct: _, pixels: _}}`.

  The readback is the displayed framebuffer: **post lighting, exposure and
  tone mapping** — assert on `:dominant`/`:dominant_share` and compare with
  tolerance, never bit-exact against IR base colors (see the pick +
  introspection decision record). Rects clamp to the viewport;
  `{:error, :offscreen}` when nothing overlaps. Payload is `w * h * scale²
  * 4` bytes — probe-sized rects, not the full viewport.

    * `sample_region(node, rect)` / `sample_region(node, viewport_id, rect)`
    * `sample_region(viewport_id, rect, timeout \\\\ #{@scene_timeout})`
  """
  @spec sample_region(node() | String.t(), tuple() | String.t()) ::
          {:ok, map()} | {:error, term()}
  def sample_region(node, {x, y, w, h}) when is_atom(node) do
    with {:ok, viewport_id} <- default_viewport(node),
         do: sample_region(node, viewport_id, {x, y, w, h})
  end

  def sample_region(viewport_id, {_x, _y, _w, _h} = rect) when is_binary(viewport_id),
    do: sample_region(viewport_id, rect, @scene_timeout)

  @spec sample_region(node() | String.t(), String.t() | tuple(), tuple() | timeout()) ::
          {:ok, map()} | {:error, term()}
  def sample_region(node, viewport_id, {x, y, w, h})
      when is_atom(node) and is_binary(viewport_id),
      do: rpc(node, :sample_region, [viewport_id, {x, y, w, h}])

  def sample_region(viewport_id, {x, y, w, h}, timeout)
      when is_binary(viewport_id) and is_number(x) and is_number(y) and is_number(w) and
             is_number(h) do
    request_id = new_request_id()

    query =
      encode_query(%{
        "request_id" => request_id,
        "x" => x * 1.0,
        "y" => y * 1.0,
        "w" => w * 1.0,
        "h" => h * 1.0
      })

    with {:ok, reply} <- Native.impl().sample(viewport_id, query),
         :ok <- Wire.decode_result(reply),
         {:ok, payload} <- await_reply(:scene3d_sample, viewport_id, request_id, timeout) do
      decode_sample(payload)
    end
  end

  @doc """
  Rendering performance as numbers, not vibes — read back from a ring
  buffer the render thread fills (cheap: one delta per vsync tick).

  Returns `{:ok, stats}`:

    * `:frames` — frames rendered since the last `frame_stats` query
    * `:avg_ms` / `:p95_ms` — rolling frame-to-frame time over the ring
      buffer window (vsync-to-vsync, so an idle-but-healthy viewport reads
      ~16.7 ms at 60 Hz)
    * `:dropped` — frames since the last query whose delta exceeded 1.5×
      the display's refresh period
    * `:entities` — entities in the applier registry
    * `:renderables` — renderable entities currently in the Filament scene

    * `frame_stats(node)` / `frame_stats(node, viewport_id)` — host-side.
    * `frame_stats(viewport_id, timeout \\\\ #{@scene_timeout})` — local.
  """
  @spec frame_stats(node() | String.t(), String.t() | timeout()) ::
          {:ok, map()} | {:error, term()}
  def frame_stats(target, arg \\ @scene_timeout)

  def frame_stats(node, viewport_id) when is_atom(node) and is_binary(viewport_id),
    do: rpc(node, :frame_stats, [viewport_id])

  def frame_stats(node, _default_timeout) when is_atom(node) do
    with {:ok, viewport_id} <- default_viewport(node), do: frame_stats(node, viewport_id)
  end

  def frame_stats(viewport_id, timeout) when is_binary(viewport_id) do
    request_id = new_request_id()

    with {:ok, reply} <- Native.impl().frame_stats(viewport_id, request_id),
         :ok <- Wire.decode_result(reply),
         {:ok, payload} <-
           await_reply(:scene3d_frame_stats, viewport_id, request_id, timeout) do
      decode_frame_stats(payload)
    end
  end

  @doc """
  The viewport ids with an attached native renderer. `viewports/0` is
  device-local; `viewports/1` takes the device node.
  """
  @spec viewports() :: {:ok, [String.t()]} | {:error, term()}
  def viewports do
    with {:ok, reply} <- Native.impl().viewports() do
      case Wire.decode!(reply) do
        %{"viewports" => ids} when is_list(ids) -> {:ok, ids}
        other -> {:error, {:bad_native_reply, other}}
      end
    end
  end

  @spec viewports(node()) :: {:ok, [String.t()]} | {:error, term()}
  def viewports(node) when is_atom(node), do: rpc(node, :viewports, [])

  @doc """
  Destroy the native scene state for a viewport: registry, shadow, queued
  patches. Called by `Mob.Scene3d.Viewport.terminate/2` when the owning
  screen exits (mob #111 component reclamation); safe to call twice.
  """
  @spec destroy(String.t()) :: :ok | {:error, term()}
  def destroy(viewport_id) when is_binary(viewport_id) do
    with {:ok, reply} <- Native.impl().destroy(viewport_id) do
      Wire.decode_result(reply)
    end
  end

  @doc """
  Resolve a logical asset ref to an on-device absolute path.

  Absolute refs pass through. Relative refs resolve against the configured
  asset root — `config :mob_scene3d, asset_root: {otp_app, "priv/scene3d_assets"}`
  (or an absolute path) — and pass through unchanged when no root is
  configured (the native applier then reports `{:bad_asset, ref, reason}`
  honestly rather than guessing). Final asset-root layout is the asset
  pipeline bead's (`mob_scene3d-392`).
  """
  @spec resolve_asset(String.t()) :: String.t()
  def resolve_asset("/" <> _rest = absolute), do: absolute

  def resolve_asset(ref) when is_binary(ref) do
    case Application.get_env(:mob_scene3d, :asset_root) do
      nil -> ref
      {app, relative} -> app |> Application.app_dir(relative) |> Path.join(ref)
      root when is_binary(root) -> Path.join(root, ref)
    end
  end

  # ── commit pipeline ─────────────────────────────────────────────────────────

  defp validate(ir) do
    case IR.validate(ir) do
      :ok -> :ok
      {:error, reason} -> {:error, {:invalid_scene, reason}}
    end
  end

  # Version-skew guard: every op in the patch must be declared by the native
  # caps, and the wire schema must agree. Loud errors, never silent drops.
  defp guard_ops(ops) do
    with {:ok, %{schema: schema, ops: supported}} <- caps() do
      cond do
        schema != Wire.schema() ->
          {:error, {:schema_mismatch, schema, Wire.schema()}}

        missing = Enum.find(ops, &(not MapSet.member?(supported, Wire.op_name(&1)))) ->
          {:error, {:unsupported, elem(missing, 0)}}

        true ->
          :ok
      end
    end
  end

  defp ship(viewport_id, ops) do
    patch = ops |> Enum.map(&resolve_op_assets/1) |> Wire.encode_patch()

    with {:ok, reply} <- Native.impl().apply_patch(viewport_id, patch) do
      Wire.decode_result(reply)
    end
  end

  # The committed IR keeps logical refs (diffs compare intent); absolute
  # on-device paths are an encode-boundary concern only.
  defp resolve_op_assets({tag, %Entity{data: %Model{} = model} = entity})
       when tag in [:add_entity, :replace_entity] do
    {tag, %Entity{entity | data: %Model{model | asset: resolve_asset(model.asset)}}}
  end

  defp resolve_op_assets(op), do: op

  # ── introspection plumbing ──────────────────────────────────────────────────

  defp new_request_id, do: Base.encode16(:crypto.strong_rand_bytes(8))

  defp encode_query(map), do: map |> :json.encode() |> IO.iodata_to_binary()

  # Async replies are 4-tuples {tag, viewport, request, json}; anything not
  # matching this exact request stays in the mailbox for its own awaiter.
  defp await_reply(tag, viewport_id, request_id, timeout) do
    receive do
      {^tag, ^viewport_id, ^request_id, json} -> {:ok, Wire.decode!(json)}
    after
      timeout -> {:error, :timeout}
    end
  end

  defp decode_pick(%{"entity" => id}, _x, _y) when is_binary(id), do: {:ok, id}
  defp decode_pick(%{"miss" => true}, x, y), do: {:error, {:no_entity_at_point, x, y}}
  defp decode_pick(%{"error" => reason}, _x, _y), do: {:error, Wire.decode_error(reason)}
  defp decode_pick(other, _x, _y), do: {:error, {:bad_native_reply, other}}

  defp decode_sample(%{"width" => w, "height" => h, "rgba" => b64})
       when is_integer(w) and is_integer(h) and is_binary(b64) do
    case Base.decode64(b64) do
      # One reducer for 2D and 3D pixel truth: the exact stats shape
      # Mob.Test.sample_color/2 returns, so parity assertions compare like
      # with like.
      {:ok, rgba} -> Mob.Test.reduce_rgba(rgba, w, h)
      :error -> {:error, {:bad_native_reply, :rgba_base64}}
    end
  end

  defp decode_sample(%{"error" => reason}), do: {:error, Wire.decode_error(reason)}
  defp decode_sample(other), do: {:error, {:bad_native_reply, other}}

  @frame_stat_keys ~w(frames avg_ms p95_ms dropped entities renderables)

  defp decode_frame_stats(%{"error" => reason}), do: {:error, Wire.decode_error(reason)}

  defp decode_frame_stats(payload) when is_map(payload) do
    if Enum.all?(@frame_stat_keys, &is_number(payload[&1])) do
      {:ok,
       %{
         frames: payload["frames"],
         avg_ms: payload["avg_ms"],
         p95_ms: payload["p95_ms"],
         dropped: payload["dropped"],
         entities: payload["entities"],
         renderables: payload["renderables"]
       }}
    else
      {:error, {:bad_native_reply, payload}}
    end
  end

  defp decode_frame_stats(other), do: {:error, {:bad_native_reply, other}}

  defp default_viewport(node) do
    case viewports(node) do
      {:ok, [viewport_id]} -> {:ok, viewport_id}
      {:ok, []} -> {:error, :no_viewport}
      {:ok, ids} -> {:error, {:multiple_viewports, ids}}
      {:error, _reason} = error -> error
    end
  end

  defp rpc(node, fun, args) do
    case :rpc.call(node, __MODULE__, fun, args, @scene_timeout + @rpc_headroom) do
      {:badrpc, reason} -> {:error, {:badrpc, reason}}
      other -> other
    end
  end
end
