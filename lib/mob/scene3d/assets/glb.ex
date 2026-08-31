defmodule Mob.Scene3d.Assets.Glb do
  @moduledoc """
  Minimal reader for the GLB (glTF 2.0 binary) container.

  Parses the 12-byte header and the JSON chunk — enough to power the
  pipeline's own structural judgments (embedded-buffer discipline, required
  extensions, budget stats) with zero native dependencies. Spec-level
  conformance is the Khronos validator's job
  (`Mob.Scene3d.Assets.Tools.validate/1`); this module reads only what the
  validator does not judge: this repo's rules from README → Asset formats.
  """

  @triangle_modes [nil, 4, 5, 6]

  @doc """
  Parses a `.glb` file and returns its decoded glTF JSON document.

  Errors are shaped, never raised: `{:error, :not_glb}` for a file without
  the `glTF` magic, `{:error, {:unsupported_container_version, n}}`,
  `{:error, {:truncated, details}}`, `{:error, {:invalid_json, reason}}`,
  or a `File` posix error.
  """
  @spec parse(Path.t()) :: {:ok, map()} | {:error, term()}
  def parse(path) do
    case File.read(path) do
      {:ok, binary} -> parse_binary(binary)
      {:error, posix} -> {:error, {:unreadable, path, posix}}
    end
  end

  @doc """
  Parses an in-memory GLB container. See `parse/1` for the error shapes.
  """
  @spec parse_binary(binary()) :: {:ok, map()} | {:error, term()}
  def parse_binary(<<"glTF", 2::32-little, declared::32-little, chunks::binary>> = binary) do
    if byte_size(binary) == declared do
      decode_json_chunk(chunks)
    else
      {:error, {:truncated, declared_bytes: declared, actual_bytes: byte_size(binary)}}
    end
  end

  def parse_binary(<<"glTF", version::32-little, _rest::binary>>) do
    {:error, {:unsupported_container_version, version}}
  end

  def parse_binary(_binary), do: {:error, :not_glb}

  @doc """
  Derives the pipeline's stats from a decoded glTF document (as returned by
  `parse/1`): mesh/primitive/material/skin counts, a triangle estimate from
  accessor counts, animation names, morph-target count, embedded image MIME
  types, declared extensions, and any external (non-`data:`) buffer or image
  URIs — which a device-ready `.glb` must not have.
  """
  @spec info(map()) :: map()
  def info(gltf) when is_map(gltf) do
    %{
      generator: get_in(gltf, ["asset", "generator"]),
      meshes: length(Map.get(gltf, "meshes", [])),
      primitives: primitives(gltf) |> length(),
      triangles: triangle_estimate(gltf),
      materials: length(Map.get(gltf, "materials", [])),
      animations: gltf |> Map.get("animations", []) |> Enum.map(&Map.get(&1, "name")),
      skins: length(Map.get(gltf, "skins", [])),
      morph_targets: morph_target_count(gltf),
      image_mime_types: image_mime_types(gltf),
      extensions_used: Map.get(gltf, "extensionsUsed", []),
      extensions_required: Map.get(gltf, "extensionsRequired", []),
      external_uris: external_uris(gltf)
    }
  end

  @doc """
  Non-`data:` URIs referenced by buffers or images. A shippable `.glb` embeds
  everything (single file per asset — no loose sidecars on device), so any
  entry here fails the pipeline.
  """
  @spec external_uris(map()) :: [String.t()]
  def external_uris(gltf) when is_map(gltf) do
    ["buffers", "images"]
    |> Enum.flat_map(&Map.get(gltf, &1, []))
    |> Enum.flat_map(fn entry ->
      case Map.get(entry, "uri") do
        nil -> []
        "data:" <> _rest -> []
        uri -> [uri]
      end
    end)
  end

  defp decode_json_chunk(<<length::32-little, "JSON", json::binary-size(length), _rest::binary>>) do
    case JSON.decode(json) do
      {:ok, gltf} when is_map(gltf) -> {:ok, gltf}
      {:ok, other} -> {:error, {:invalid_json, {:not_an_object, other}}}
      {:error, reason} -> {:error, {:invalid_json, reason}}
    end
  end

  defp decode_json_chunk(chunks) do
    {:error, {:truncated, json_chunk_header: binary_slice(chunks, 0, 8)}}
  end

  defp primitives(gltf) do
    gltf
    |> Map.get("meshes", [])
    |> Enum.flat_map(&Map.get(&1, "primitives", []))
  end

  # Estimate from accessor counts: exact for TRIANGLES (mode 4, the default),
  # close enough for strips/fans; points/lines contribute nothing. Draco
  # primitives still declare accessor counts, so they are covered too.
  defp triangle_estimate(gltf) do
    accessors = Map.get(gltf, "accessors", [])

    gltf
    |> primitives()
    |> Enum.filter(&(Map.get(&1, "mode") in @triangle_modes))
    |> Enum.map(&primitive_vertex_count(&1, accessors))
    |> Enum.map(&div(&1, 3))
    |> Enum.sum()
  end

  defp primitive_vertex_count(primitive, accessors) do
    index = Map.get(primitive, "indices") || get_in(primitive, ["attributes", "POSITION"])

    case index && Enum.at(accessors, index) do
      %{"count" => count} -> count
      _missing -> 0
    end
  end

  defp morph_target_count(gltf) do
    gltf
    |> primitives()
    |> Enum.map(&length(Map.get(&1, "targets", [])))
    |> Enum.sum()
  end

  defp image_mime_types(gltf) do
    gltf
    |> Map.get("images", [])
    |> Enum.map(&(Map.get(&1, "mimeType") || mime_from_uri(Map.get(&1, "uri"))))
    |> Enum.frequencies()
  end

  defp mime_from_uri("data:" <> rest), do: rest |> String.split(";", parts: 2) |> hd()
  defp mime_from_uri(_uri), do: "external"
end
