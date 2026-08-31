defmodule Mix.Tasks.Scene3d.Assets do
  @shortdoc "Validates and prepares a project's scene3d assets"

  @moduledoc """
  Validates and prepares a project's 3D assets (see `guides/assets.md`).

      mix scene3d.assets [PATH ...] [options]

  With no `PATH`, scans `priv/scene3d_assets`. Every
  model file found is judged: `.glb` only (loose `.gltf`, FBX, OBJ, USDZ are
  rejected with converter guidance), embedded buffers only, Khronos-valid
  (official glTF validator via `gltf-transform validate`), required
  extensions loadable by Filament gltfio, and within the optional budgets.

  ## Options

    * `--config PATH` — budgets config (`.exs` returning a map with any of
      `:max_file_bytes`, `:max_triangles`, `:require_ktx2`). Defaults to
      `.scene3d_assets.exs` when that file exists.
    * `--no-validate` — skip the Khronos validator (offline; the skip is
      reported, not silent).
    * `--ktx2 etc1s|uastc` — compress the textures of each input `.glb` to
      KTX2/Basis (writes `<name>.ktx2.glb` beside the input, or `--out FILE`
      for a single input). `etc1s` is small/lossier; `uastc` is for normal
      maps and high-fidelity data.
    * `--ibl PANORAMA` — precompute an IBL environment (prefiltered specular
      cubemap + SH irradiance, plus a skybox) from an equirectangular
      `.hdr`/`.exr`/`.png` via Filament's `cmgen`. Requires cmgen on `$PATH`
      or vendored via `scripts/fetch_cmgen.sh`.
    * `--out PATH` — output file (`--ktx2`, single input) or directory
      (`--ibl`, default `priv/scene3d_assets/env`).
    * `--size N` — cubemap base size for `--ibl` (power of two, default 256).
  """

  use Mix.Task

  alias Mob.Scene3d.Assets
  alias Mob.Scene3d.Assets.Tools

  @default_root "priv/scene3d_assets"
  @default_config ".scene3d_assets.exs"

  @switches [
    config: :string,
    validate: :boolean,
    ktx2: :string,
    ibl: :string,
    out: :string,
    size: :integer
  ]

  @doc false
  @spec default_root() :: String.t()
  def default_root, do: @default_root

  @impl Mix.Task
  def run(argv) do
    {opts, paths} = OptionParser.parse!(argv, strict: @switches)

    case Keyword.fetch(opts, :ibl) do
      {:ok, panorama} -> run_ibl(panorama, opts)
      :error -> run_models(paths, opts)
    end
  end

  defp run_models(paths, opts) do
    paths = (paths == [] && [@default_root]) || paths
    paths = maybe_compress(paths, opts)

    validate_opts = [
      budgets: budgets(opts),
      validator: Keyword.get(opts, :validate, true)
    ]

    reports = Assets.validate_paths(paths, validate_opts)

    if reports == [] do
      Mix.raise("no model files found under #{Enum.join(paths, ", ")}")
    end

    Enum.each(reports, &print_report/1)

    failures = Enum.reject(reports, &(&1.status == :ok))

    if failures != [] do
      Mix.raise("#{length(failures)} of #{length(reports)} asset(s) failed — see errors above")
    end

    Mix.shell().info("✓ #{length(reports)} asset(s) valid")
  end

  defp maybe_compress(paths, opts) do
    case Keyword.fetch(opts, :ktx2) do
      {:ok, mode} ->
        Enum.map(paths, &compress!(&1, ktx2_mode!(mode), ktx2_output(paths, opts)))

      :error ->
        paths
    end
  end

  defp ktx2_mode!("etc1s"), do: :etc1s
  defp ktx2_mode!("uastc"), do: :uastc
  defp ktx2_mode!(other), do: Mix.raise("--ktx2 expects etc1s or uastc, got: #{other}")

  defp ktx2_output([_single], opts), do: Keyword.get(opts, :out)

  defp ktx2_output(paths, opts) do
    if Keyword.has_key?(opts, :out) do
      Mix.raise("--out with --ktx2 needs exactly one input .glb, got #{length(paths)}")
    end

    nil
  end

  defp compress!(path, mode, output) do
    if Path.extname(path) != ".glb" do
      Mix.raise("--ktx2 operates on .glb files, got: #{path}")
    end

    output = output || Path.rootname(path, ".glb") <> ".ktx2.glb"

    case Tools.to_ktx2(path, output, mode) do
      {:ok, written} ->
        Mix.shell().info("compressed #{path} → #{written} (#{mode})")
        written

      {:error, {:tool_missing, guidance}} ->
        Mix.raise(guidance)

      {:error, reason} ->
        Mix.raise("KTX2 compression failed for #{path}: #{inspect(reason)}")
    end
  end

  defp run_ibl(panorama, opts) do
    out_dir = Keyword.get(opts, :out, Path.join(@default_root, "env"))
    size = Keyword.get(opts, :size, 256)

    case Tools.ibl(panorama, out_dir, size) do
      {:ok, outputs} ->
        Mix.shell().info("✓ IBL environment written under #{out_dir}:")
        Enum.each(outputs, &Mix.shell().info("  #{&1}"))

      {:error, {:tool_missing, guidance}} ->
        Mix.raise(guidance)

      {:error, {:cmgen_failed, status, output}} ->
        Mix.raise("cmgen exited #{status}:\n#{output}")
    end
  end

  defp budgets(opts) do
    case Keyword.fetch(opts, :config) do
      {:ok, path} ->
        Assets.load_budgets!(path)

      :error ->
        (File.exists?(@default_config) && Assets.load_budgets!(@default_config)) || %{}
    end
  end

  defp print_report(%{status: :ok} = report) do
    Mix.shell().info("  ok  #{report.path}#{summary(report.info)}")
    Enum.each(report.warnings, &Mix.shell().info("      warning: #{&1}"))
  end

  defp print_report(%{status: {:error, errors}} = report) do
    Mix.shell().error("FAIL  #{report.path}")
    Enum.each(errors, &Mix.shell().error("      #{&1}"))
    Enum.each(report.warnings, &Mix.shell().info("      warning: #{&1}"))
  end

  defp summary(nil), do: ""

  defp summary(info) do
    "  (#{info.triangles} tris, #{info.materials} materials, " <>
      "#{length(info.animations)} animations)"
  end
end
