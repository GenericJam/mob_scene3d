defmodule Mob.Scene3d.Assets.Tools do
  @moduledoc """
  Discovery and invocation of the external asset tools:

  - **Khronos glTF validation** via `gltf-transform validate`
    (`@gltf-transform/cli`, which wraps the official KhronosGroup
    glTF-Validator). Resolved from `$PATH`, falling back to
    `npx --no-install @gltf-transform/cli`.
  - **KTX2/Basis texture compression** via `gltf-transform etc1s|uastc`.
  - **IBL prefiltering** via Filament's `cmgen`, resolved from `$PATH` or
    the project-local `vendor/filament-tools/cmgen` that
    `scripts/fetch_cmgen.sh` vendors. The Filament pin is
    `priv/filament-version` — read at compile time (it must live in `priv/`
    so it ships inside the Hex package; AGENTS.md → packaging lesson).

  Every missing tool is an honest, actionable error — never a silent skip.
  """

  # A COMPILE-TIME read: Application.app_dir/2 (the runtime way to reach
  # priv/) cannot resolve the app being compiled, and __DIR__-relative works
  # identically in the repo and inside the unpacked Hex package — which the
  # packed-artifact regression proves on every run.
  # credo:disable-for-next-line ExSlop.Check.Warning.PathExpandPriv
  @filament_version_path Path.expand("../../../../priv/filament-version", __DIR__)
  @external_resource @filament_version_path
  @filament_version @filament_version_path |> File.read!() |> String.trim()

  @gltf_transform_package "@gltf-transform/cli"

  @doc "The pinned Filament release cmgen is fetched from (priv/filament-version)."
  @spec filament_version() :: String.t()
  def filament_version, do: @filament_version

  @doc """
  Runs the Khronos glTF validator over `path`.

  Returns `{:ok, report}` when the file validates (report holds the
  validator's non-error findings), `{:error, {:validation_failed, output}}`
  when the validator finds errors, or `{:error, {:tool_missing, guidance}}`
  when `gltf-transform` is not installed.
  """
  @spec validate(Path.t()) :: {:ok, String.t()} | {:error, term()}
  def validate(path) do
    run_gltf_transform(["validate", path, "--format", "csv"], validation_result(path))
  end

  @doc """
  Compresses the textures inside a `.glb` to KTX2/Basis in place of their
  PNG/JPEG payloads, writing to `output`. `mode` picks the Basis codec:
  `:etc1s` (small, lossier) or `:uastc` (large, high fidelity — normal maps).
  """
  @spec to_ktx2(Path.t(), Path.t(), :etc1s | :uastc) :: {:ok, Path.t()} | {:error, term()}
  def to_ktx2(path, output, mode) when mode in [:etc1s, :uastc] do
    # gltf-transform's etc1s/uastc shell out to KTX-Software's `ktx` binary
    # and fail with a cryptic `command -v ktx` error without it — pre-check
    # so the failure names the actual missing tool.
    if System.find_executable("ktx") do
      run_gltf_transform([Atom.to_string(mode), path, output], fn
        {_output, 0} -> {:ok, output}
        {output, status} -> {:error, {:ktx2_failed, mode, status, output}}
      end)
    else
      {:error, {:tool_missing, ktx_guidance()}}
    end
  end

  @doc "Actionable install guidance for a missing KTX-Software `ktx` encoder."
  @spec ktx_guidance() :: String.t()
  def ktx_guidance do
    """
    ktx (the KTX-Software encoder gltf-transform's etc1s/uastc commands \
    shell out to) was not found on $PATH.

    Install a release from https://github.com/KhronosGroup/KTX-Software/releases \
    (macOS: the Darwin .pkg puts ktx on $PATH; there is no homebrew formula) \
    and re-run.
    """
  end

  @doc """
  Precomputes an IBL environment from an equirectangular `.hdr`/`.exr`/`.png`
  panorama via Filament's `cmgen --deploy`: a prefiltered specular cubemap
  with spherical-harmonics irradiance, plus a skybox cubemap, written under
  `out_dir` and named after it (`<dirname>_ibl.ktx`, `<dirname>_skybox.ktx`) —
  the scene references the environment by that directory name.
  """
  @spec ibl(Path.t(), Path.t(), pos_integer()) :: {:ok, [Path.t()]} | {:error, term()}
  def ibl(panorama, out_dir, size) do
    case cmgen_path() do
      {:ok, cmgen} -> run_cmgen(cmgen, panorama, out_dir, size)
      {:error, _missing} = error -> error
    end
  end

  @doc """
  Locates `cmgen`: `$PATH` first, then the vendored
  `vendor/filament-tools/cmgen`. Returns `{:error, {:tool_missing, guidance}}`
  with the fetch instructions when absent — the caller degrades loudly, not
  silently.
  """
  @spec cmgen_path() :: {:ok, Path.t()} | {:error, {:tool_missing, String.t()}}
  def cmgen_path do
    vendored = Path.join(File.cwd!(), "vendor/filament-tools/cmgen")

    cond do
      path = System.find_executable("cmgen") -> {:ok, path}
      File.exists?(vendored) -> {:ok, vendored}
      true -> {:error, {:tool_missing, cmgen_guidance()}}
    end
  end

  @doc "Actionable install guidance for a missing `cmgen`."
  @spec cmgen_guidance() :: String.t()
  def cmgen_guidance do
    """
    cmgen (Filament's IBL prefilter) was not found on $PATH or at \
    vendor/filament-tools/cmgen.

    Vendor it with: scripts/fetch_cmgen.sh
    (downloads the pinned Filament #{@filament_version} release tgz for this \
    OS and extracts bin/cmgen), or install Filament's host tools yourself \
    from https://github.com/google/filament/releases/tag/#{@filament_version} \
    and put cmgen on $PATH.
    """
  end

  @doc """
  The `gltf-transform` invocation prefix, or an actionable error when the
  CLI is not installed.
  """
  @spec gltf_transform_command() :: {:ok, {Path.t(), [String.t()]}} | {:error, term()}
  def gltf_transform_command do
    npx = System.find_executable("npx")

    cond do
      path = System.find_executable("gltf-transform") ->
        {:ok, {path, []}}

      npx && npx_package_available?(npx) ->
        {:ok, {npx, ["--no-install", @gltf_transform_package]}}

      true ->
        {:error, {:tool_missing, gltf_transform_guidance()}}
    end
  end

  @doc "Actionable install guidance for a missing `gltf-transform`."
  @spec gltf_transform_guidance() :: String.t()
  def gltf_transform_guidance do
    """
    gltf-transform (#{@gltf_transform_package} — Khronos glTF validation and \
    KTX2 compression) was not found on $PATH and is not resolvable via npx.

    Install it with: npm install -g #{@gltf_transform_package}
    """
  end

  defp npx_package_available?(npx) do
    {_output, status} =
      System.cmd(npx, ["--no-install", @gltf_transform_package, "--version"],
        stderr_to_stdout: true
      )

    status == 0
  end

  defp run_gltf_transform(args, on_result) do
    case gltf_transform_command() do
      {:ok, {command, prefix}} ->
        command
        |> System.cmd(prefix ++ args, stderr_to_stdout: true)
        |> on_result.()

      {:error, _missing} = error ->
        error
    end
  end

  defp validation_result(path) do
    fn
      {output, 0} -> {:ok, output}
      {output, _status} -> {:error, {:validation_failed, path, output}}
    end
  end

  defp run_cmgen(cmgen, panorama, out_dir, size) do
    File.mkdir_p!(out_dir)

    args = ["--quiet", "--format=ktx", "--size=#{size}", "--deploy=#{out_dir}", panorama]

    case System.cmd(cmgen, args, stderr_to_stdout: true) do
      {_output, 0} -> {:ok, ibl_outputs(out_dir)}
      {output, status} -> {:error, {:cmgen_failed, status, output}}
    end
  end

  # cmgen --deploy names its outputs after the deploy DIRECTORY, not the
  # input panorama: <dir>/<dirname>_ibl.ktx, <dir>/<dirname>_skybox.ktx and
  # sh.txt. The environment is referenced by that directory name.
  defp ibl_outputs(out_dir) do
    [out_dir, "**", "*.ktx"]
    |> Path.join()
    |> Path.wildcard()
    |> Enum.sort()
  end
end
