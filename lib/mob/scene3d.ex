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

  @doc """
  A screen element hosting the native Filament viewport.

  Options:

    * `:id` — atom, required, unique per screen (the `Mob.UI.native_view/2`
      contract). Its string form is the viewport id used everywhere else.
    * `:ir` — the `%Mob.Scene3d.IR{}` to commit, straight from assigns.
      Defaults to the empty scene.
    * `:width` / `:height` — viewport size in dp/pt.
  """
  @spec viewport(keyword()) :: map()
  def viewport(opts) when is_list(opts) do
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

  Blocks the calling process for the round-trip (the reply rides the next
  render tick). Returns `{:ok, scene_map}` with string keys mirroring the
  wire encoding, or an honest error (`{:no_viewport, id}` before the
  surface attaches, `:timeout`, ...).
  """
  @spec scene(String.t(), timeout()) :: {:ok, map()} | {:error, term()}
  def scene(viewport_id, timeout \\ @scene_timeout) when is_binary(viewport_id) do
    request_id = Base.encode16(:crypto.strong_rand_bytes(8))

    with {:ok, reply} <- Native.impl().request_scene(viewport_id, request_id),
         :ok <- Wire.decode_result(reply) do
      await_scene(viewport_id, request_id, timeout)
    end
  end

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

  defp await_scene(viewport_id, request_id, timeout) do
    receive do
      {:scene3d_scene, ^viewport_id, ^request_id, json} -> {:ok, Wire.decode!(json)}
    after
      timeout -> {:error, :timeout}
    end
  end
end
