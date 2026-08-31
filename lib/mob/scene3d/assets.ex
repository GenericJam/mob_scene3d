defmodule Mob.Scene3d.Assets do
  @moduledoc """
  The asset pipeline's judgments (see `guides/assets.md` and README →
  Asset formats):

  - **`.glb` only.** Loose `.gltf`, FBX, OBJ and USDZ are rejected with
    guidance naming the converter — conversion happens at authoring time,
    never on device.
  - **Embedded buffers.** A `.glb` referencing external URIs (sidecar `.bin`
    or image files) fails: one file per asset on device.
  - **Khronos-valid.** Every asset passes the official glTF validator
    (via `Mob.Scene3d.Assets.Tools.validate/1`).
  - **Within budget.** Optional per-project budgets (file bytes, triangles,
    KTX2-only textures) from `.scene3d_assets.exs`.
  - **Runtime-loadable extensions.** `extensionsRequired` outside Filament
    gltfio's supported set is an error; unsupported `extensionsUsed` only
    warns (the asset degrades, it doesn't fail to load).

  `mix scene3d.assets` is the CLI over this module.
  """

  alias Mob.Scene3d.Assets.Glb
  alias Mob.Scene3d.Assets.Tools

  @type report :: %{
          path: Path.t(),
          status: :ok | {:error, [String.t()]},
          warnings: [String.t()],
          info: map() | nil
        }

  # Model/scene formats we refuse, with the converter to name in the error.
  # USDZ deliberately gets the bluntest message: it is an Apple-only pipeline
  # dead end for a cross-platform renderer (README → Asset formats).
  @rejected_formats %{
    ".gltf" =>
      "loose .gltf (JSON + sidecar files) is not accepted — devices get one " <>
        "embedded file per asset. Repack: npx @gltf-transform/cli cp model.gltf model.glb",
    ".fbx" =>
      "FBX is not accepted — convert at authoring time: Blender (File → Import → FBX, " <>
        "then File → Export → glTF 2.0, format glTF Binary) or FBX2glTF",
    ".obj" =>
      "OBJ is not accepted — convert at authoring time: Blender (File → Import → Wavefront, " <>
        "then File → Export → glTF 2.0, format glTF Binary) or obj2gltf",
    ".usdz" =>
      "USDZ is not accepted (Apple-only pipeline dead end for a cross-platform renderer) — " <>
        "re-export the source scene as glTF 2.0 (.glb); Blender 4.x imports USD",
    ".bin" =>
      ".bin is a loose-.gltf sidecar, not an asset — repack the owning .gltf as an " <>
        "embedded .glb: npx @gltf-transform/cli cp model.gltf model.glb"
  }

  # Extensions Filament's gltfio loads at the pinned release (see
  # priv/filament-version). Revisit on every Filament bump — this list is a
  # pipeline judgment, not a spec constant.
  @gltfio_supported_extensions ~w(
    KHR_draco_mesh_compression
    KHR_lights_punctual
    KHR_materials_clearcoat
    KHR_materials_emissive_strength
    KHR_materials_ior
    KHR_materials_pbrSpecularGlossiness
    KHR_materials_sheen
    KHR_materials_specular
    KHR_materials_transmission
    KHR_materials_unlit
    KHR_materials_variants
    KHR_materials_volume
    KHR_mesh_quantization
    KHR_texture_basisu
    KHR_texture_transform
  )

  @basis_mime "image/ktx2"

  @doc """
  Validates one asset path. `opts`:

  - `:budgets` — map from `load_budgets!/1` (default: none)
  - `:validator` — `false` skips the Khronos validator (offline use;
    the report carries a warning so the skip is visible)
  """
  @spec validate_file(Path.t(), keyword()) :: report()
  def validate_file(path, opts \\ []) do
    case rejection_for(path) do
      nil -> validate_glb(path, opts)
      message -> %{path: path, status: {:error, [message]}, warnings: [], info: nil}
    end
  end

  @doc """
  Expands each path (file or directory) to the model files under it and
  validates every one. Directories are scanned recursively for `.glb` plus
  the rejected model formats — a stray `duck.usdz` in the asset root is an
  error, not something the scan quietly ignores.
  """
  @spec validate_paths([Path.t()], keyword()) :: [report()]
  def validate_paths(paths, opts \\ []) do
    paths
    |> Enum.flat_map(&expand_path/1)
    |> Enum.map(&validate_file(&1, opts))
  end

  @doc """
  Loads budget config from an `.exs` file returning a map. Recognized keys:
  `:max_file_bytes`, `:max_triangles`, `:require_ktx2`. Unknown keys raise —
  a typo'd budget that silently never fires is worse than none.
  """
  @spec load_budgets!(Path.t()) :: map()
  def load_budgets!(path) do
    {budgets, _bindings} = Code.eval_file(path)

    unless is_map(budgets) do
      raise ArgumentError, "budget config #{path} must return a map, got: #{inspect(budgets)}"
    end

    known = [:max_file_bytes, :max_triangles, :require_ktx2]

    case Map.keys(budgets) -- known do
      [] -> budgets
      unknown -> raise ArgumentError, "unknown budget keys in #{path}: #{inspect(unknown)}"
    end
  end

  @doc "The rejection message for a non-`.glb` model format, or `nil` for `.glb`."
  @spec rejection_for(Path.t()) :: String.t() | nil
  def rejection_for(path) do
    extension = path |> Path.extname() |> String.downcase()

    cond do
      extension == ".glb" -> nil
      message = @rejected_formats[extension] -> "#{path}: #{message}"
      true -> "#{path}: unrecognized asset format #{inspect(extension)} — models are .glb only"
    end
  end

  @doc "Extensions Filament gltfio supports at the pinned release."
  @spec gltfio_supported_extensions() :: [String.t()]
  def gltfio_supported_extensions, do: @gltfio_supported_extensions

  defp validate_glb(path, opts) do
    case Glb.parse(path) do
      {:ok, gltf} ->
        judge(path, Glb.info(gltf), opts)

      {:error, reason} ->
        %{path: path, status: {:error, [parse_error(path, reason)]}, warnings: [], info: nil}
    end
  end

  defp judge(path, info, opts) do
    budgets = Keyword.get(opts, :budgets, %{})

    {validator_errors, validator_warnings} = khronos_findings(path, opts)

    errors =
      structural_errors(path, info) ++
        budget_errors(path, info, budgets) ++
        validator_errors

    warnings = extension_warnings(path, info) ++ validator_warnings

    %{
      path: path,
      status: (errors == [] && :ok) || {:error, errors},
      warnings: warnings,
      info: info
    }
  end

  defp structural_errors(path, info) do
    external =
      case info.external_uris do
        [] ->
          []

        uris ->
          [
            "#{path}: references external files #{inspect(uris)} — a device asset is one " <>
              "embedded .glb. Repack: npx @gltf-transform/cli cp model.glb model.embedded.glb"
          ]
      end

    unsupported = info.extensions_required -- @gltfio_supported_extensions

    required =
      case unsupported do
        [] ->
          []

        extensions ->
          [
            "#{path}: requires glTF extensions Filament gltfio does not load " <>
              "(#{Enum.join(extensions, ", ")}) — the asset cannot render; re-export without them"
          ]
      end

    external ++ required
  end

  defp extension_warnings(path, info) do
    case info.extensions_used -- (info.extensions_required ++ @gltfio_supported_extensions) do
      [] ->
        []

      extensions ->
        [
          "#{path}: uses optional glTF extensions outside gltfio's supported set " <>
            "(#{Enum.join(extensions, ", ")}) — the asset loads but those features are ignored"
        ]
    end
  end

  defp budget_errors(path, info, budgets) do
    file_bytes = file_size(path)

    checks = [
      {:max_file_bytes, file_bytes, "file size (bytes)"},
      {:max_triangles, info.triangles, "triangles"}
    ]

    over_budget =
      for {key, actual, label} <- checks,
          budget = budgets[key],
          is_integer(budget) and actual > budget do
        "#{path}: over budget — #{label} #{actual} exceeds #{key} #{budget}"
      end

    over_budget ++ ktx2_budget_errors(path, info, budgets)
  end

  defp ktx2_budget_errors(path, info, %{require_ktx2: true}) do
    case Map.drop(info.image_mime_types, [@basis_mime]) do
      empty when map_size(empty) == 0 ->
        []

      other ->
        [
          "#{path}: require_ktx2 budget — non-KTX2 textures present " <>
            "(#{inspect(Map.keys(other))}). Compress: mix scene3d.assets #{path} --ktx2 etc1s"
        ]
    end
  end

  defp ktx2_budget_errors(_path, _info, _budgets), do: []

  defp khronos_findings(path, opts) do
    if Keyword.get(opts, :validator, true) do
      khronos_validate(path)
    else
      {[], ["#{path}: Khronos validation skipped (--no-validate)"]}
    end
  end

  defp khronos_validate(path) do
    case Tools.validate(path) do
      {:ok, _report} ->
        {[], []}

      {:error, {:validation_failed, _path, output}} ->
        {["#{path}: Khronos validator found errors:\n#{trimmed(output)}"], []}

      {:error, {:tool_missing, guidance}} ->
        {["#{path}: cannot run Khronos validation — #{guidance}"], []}
    end
  end

  defp expand_path(path) do
    if File.dir?(path) do
      scan =
        Enum.map_join(Map.keys(@rejected_formats) ++ [".glb"], ",", &String.trim_leading(&1, "."))

      [path, "**", "*.{#{scan}}"]
      |> Path.join()
      |> Path.wildcard()
      |> Enum.sort()
    else
      [path]
    end
  end

  defp parse_error(path, :not_glb) do
    "#{path}: not a GLB container (missing glTF magic) — export as glTF Binary (.glb)"
  end

  defp parse_error(path, reason), do: "#{path}: unreadable GLB — #{inspect(reason)}"

  defp file_size(path) do
    case File.stat(path) do
      {:ok, %{size: size}} -> size
      {:error, _posix} -> 0
    end
  end

  defp trimmed(output) do
    output
    |> String.split("\n")
    |> Enum.reject(&(String.trim(&1) == ""))
    |> Enum.take(20)
    |> Enum.join("\n")
  end
end
