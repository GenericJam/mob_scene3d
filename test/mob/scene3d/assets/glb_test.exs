defmodule Mob.Scene3d.Assets.GlbTest do
  use ExUnit.Case, async: true

  alias Mob.Scene3d.Assets.Glb

  @fixture Path.expand("../../../fixtures/bevel_cube.glb", __DIR__)

  describe "parse_binary/1" do
    test "rejects non-GLB binaries" do
      assert {:error, :not_glb} = Glb.parse_binary("{\"asset\": {\"version\": \"2.0\"}}")
      assert {:error, :not_glb} = Glb.parse_binary(<<>>)
    end

    test "rejects unknown container versions" do
      binary = glb(~s({"asset":{"version":"2.0"}}), version: 3)
      assert {:error, {:unsupported_container_version, 3}} = Glb.parse_binary(binary)
    end

    test "rejects a truncated container" do
      binary = glb(~s({"asset":{"version":"2.0"}}))
      truncated = binary_part(binary, 0, byte_size(binary) - 4)
      assert {:error, {:truncated, _details}} = Glb.parse_binary(truncated)
    end

    test "rejects a JSON chunk that is not a glTF object" do
      assert {:error, {:invalid_json, {:not_an_object, [1]}}} = Glb.parse_binary(glb("[1] "))
    end

    test "decodes the JSON chunk of a well-formed container" do
      assert {:ok, %{"asset" => %{"version" => "2.0"}}} =
               Glb.parse_binary(glb(~s({"asset":{"version":"2.0"}})))
    end
  end

  describe "parse/1 + info/1 on a real asset" do
    test "reads the spike's beveled cube" do
      assert {:ok, gltf} = Glb.parse(@fixture)

      info = Glb.info(gltf)

      assert info.meshes == 1
      assert info.primitives == 1
      assert info.triangles > 0
      assert info.external_uris == []
      assert info.extensions_required == []
      assert info.animations == []
    end
  end

  describe "external_uris/1" do
    test "flags non-data buffer and image URIs, ignores embedded ones" do
      gltf = %{
        "buffers" => [
          %{"uri" => "sidecar.bin"},
          %{"uri" => "data:application/octet-stream;base64,AA=="}
        ],
        "images" => [%{"uri" => "texture.png"}, %{"bufferView" => 0}]
      }

      assert Glb.external_uris(gltf) == ["sidecar.bin", "texture.png"]
    end
  end

  describe "info/1 stats" do
    test "estimates triangles from index accessors and counts morph targets" do
      gltf = %{
        "accessors" => [%{"count" => 36}, %{"count" => 12}],
        "meshes" => [
          %{
            "primitives" => [
              %{"indices" => 0, "targets" => [%{}, %{}]},
              %{"attributes" => %{"POSITION" => 1}, "mode" => 4},
              %{"indices" => 0, "mode" => 1}
            ]
          }
        ],
        "images" => [%{"mimeType" => "image/ktx2"}, %{"mimeType" => "image/png"}]
      }

      info = Glb.info(gltf)

      # 36/3 indexed triangles + 12/3 non-indexed; mode 1 (LINES) excluded.
      assert info.triangles == 16
      assert info.morph_targets == 2
      assert info.image_mime_types == %{"image/ktx2" => 1, "image/png" => 1}
    end
  end

  defp glb(json, opts \\ []) do
    version = Keyword.get(opts, :version, 2)
    chunk = <<byte_size(json)::32-little, "JSON", json::binary>>
    total = 12 + byte_size(chunk)
    <<"glTF", version::32-little, total::32-little, chunk::binary>>
  end
end
