defmodule Mob.Scene3d.AssetsTest do
  use ExUnit.Case, async: true

  alias Mob.Scene3d.Assets
  alias Mob.Scene3d.Assets.Tools

  @fixture Path.expand("../../fixtures/bevel_cube.glb", __DIR__)

  describe "rejection_for/1 — the .glb-only rule" do
    test "accepts .glb" do
      assert Assets.rejection_for("models/board.glb") == nil
      assert Assets.rejection_for("models/BOARD.GLB") == nil
    end

    test "rejects loose .gltf naming the repack command" do
      message = Assets.rejection_for("models/board.gltf")
      assert message =~ "@gltf-transform/cli cp"
      assert message =~ "sidecar"
    end

    test "rejects FBX naming a converter" do
      message = Assets.rejection_for("models/board.fbx")
      assert message =~ "FBX2glTF"
      assert message =~ "Blender"
    end

    test "rejects OBJ naming a converter" do
      message = Assets.rejection_for("models/board.obj")
      assert message =~ "obj2gltf"
    end

    test "rejects USDZ as the Apple-only dead end it is" do
      message = Assets.rejection_for("models/board.usdz")
      assert message =~ "Apple-only"
      assert message =~ "glTF 2.0"
    end

    test "rejects anything unrecognized" do
      assert Assets.rejection_for("models/board.dae") =~ "models are .glb only"
    end
  end

  describe "validate_file/2 (validator off — pure judgments)" do
    test "passes the spike's beveled cube and reports the skipped validation" do
      report = Assets.validate_file(@fixture, validator: false)

      assert report.status == :ok
      assert ["#{@fixture}: Khronos validation skipped (--no-validate)"] == report.warnings
      assert report.info.triangles > 0
    end

    test "fails a file that is not a GLB container" do
      path = tmp_file("not_a_model.glb", "definitely not gltf")
      assert %{status: {:error, [message]}} = Assets.validate_file(path, validator: false)
      assert message =~ "not a GLB container"
    end

    test "fails over-budget assets with actual vs budget in the message" do
      budgets = %{max_file_bytes: 10, max_triangles: 1}
      report = Assets.validate_file(@fixture, validator: false, budgets: budgets)

      assert {:error, errors} = report.status
      assert Enum.any?(errors, &(&1 =~ "file size" and &1 =~ "max_file_bytes 10"))
      assert Enum.any?(errors, &(&1 =~ "triangles" and &1 =~ "max_triangles 1"))
    end

    test "require_ktx2 budget flags PNG-textured assets" do
      # bevel_cube has no textures at all — build a doc with a PNG image.
      budgets = %{require_ktx2: true}

      path =
        tmp_glb("png_textured.glb", %{
          "asset" => %{"version" => "2.0"},
          "images" => [%{"mimeType" => "image/png"}]
        })

      assert %{status: {:error, [message]}} =
               Assets.validate_file(path, validator: false, budgets: budgets)

      assert message =~ "non-KTX2 textures"
      assert message =~ "--ktx2 etc1s"
    end

    test "fails assets referencing external sidecar files" do
      gltf = %{"asset" => %{"version" => "2.0"}, "buffers" => [%{"uri" => "mesh.bin"}]}
      path = tmp_glb("external.glb", gltf)

      assert %{status: {:error, [message]}} = Assets.validate_file(path, validator: false)
      assert message =~ "external files"
      assert message =~ "mesh.bin"
    end

    test "fails on required extensions gltfio does not load, warns on optional ones" do
      required = %{
        "asset" => %{"version" => "2.0"},
        "extensionsRequired" => ["EXT_meshopt_compression"],
        "extensionsUsed" => ["EXT_meshopt_compression"]
      }

      assert %{status: {:error, [message]}} =
               Assets.validate_file(tmp_glb("req.glb", required), validator: false)

      assert message =~ "EXT_meshopt_compression"
      assert message =~ "cannot render"

      optional = %{
        "asset" => %{"version" => "2.0"},
        "extensionsUsed" => ["KHR_materials_iridescence"]
      }

      report = Assets.validate_file(tmp_glb("opt.glb", optional), validator: false)
      assert report.status == :ok
      assert Enum.any?(report.warnings, &(&1 =~ "KHR_materials_iridescence"))
    end
  end

  describe "validate_paths/2" do
    test "scans directories recursively and judges every model format found" do
      dir = tmp_dir("scan")
      File.mkdir_p!(Path.join(dir, "nested"))
      File.cp!(@fixture, Path.join(dir, "cube.glb"))
      File.write!(Path.join([dir, "nested", "stray.usdz"]), "usdz bytes")

      reports = Assets.validate_paths([dir], validator: false)

      assert [%{path: cube, status: :ok}, %{path: stray, status: {:error, [message]}}] =
               Enum.sort_by(reports, & &1.path)

      assert cube =~ "cube.glb"
      assert stray =~ "stray.usdz"
      assert message =~ "Apple-only"
    end
  end

  describe "load_budgets!/1" do
    test "loads a map and rejects unknown keys" do
      good = tmp_file("budgets.exs", "%{max_triangles: 50_000}")
      assert Assets.load_budgets!(good) == %{max_triangles: 50_000}

      typo = tmp_file("typo.exs", "%{max_trianlges: 50_000}")
      assert_raise ArgumentError, ~r/unknown budget keys/, fn -> Assets.load_budgets!(typo) end

      not_a_map = tmp_file("list.exs", "[max_triangles: 1]")
      assert_raise ArgumentError, ~r/must return a map/, fn -> Assets.load_budgets!(not_a_map) end
    end
  end

  describe "Khronos validation (gltf-transform)" do
    @tag :requires_gltf_transform
    test "the spike's beveled cube passes the official validator" do
      assert %{status: :ok, warnings: []} = Assets.validate_file(@fixture)
    end

    @tag :requires_gltf_transform
    test "a corrupt container fails with the validator's findings" do
      truncated = binary_part(File.read!(@fixture), 0, 2000)
      path = tmp_file("truncated.glb", truncated)

      assert %{status: {:error, errors}} = Assets.validate_file(path)
      assert Enum.any?(errors, &(&1 =~ "Khronos validator" or &1 =~ "unreadable GLB"))
    end
  end

  describe "filament pin lockstep" do
    test "the compile-time pin matches priv/filament-version" do
      on_disk =
        "priv/filament-version"
        |> Path.expand(Path.expand("../../..", __DIR__))
        |> File.read!()
        |> String.trim()

      assert Tools.filament_version() == on_disk
      assert Tools.filament_version() =~ ~r/^v\d+\.\d+\.\d+$/
    end

    test "cmgen guidance names the fetch script and the pinned release" do
      assert Tools.cmgen_guidance() =~ "scripts/fetch_cmgen.sh"
      assert Tools.cmgen_guidance() =~ Tools.filament_version()
    end

    test "ktx guidance names the KTX-Software release page" do
      assert Tools.ktx_guidance() =~ "KhronosGroup/KTX-Software/releases"
    end
  end

  defp tmp_dir(label) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "scene3d_assets_#{label}_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp tmp_file(name, contents) do
    path = Path.join(tmp_dir("file"), name)
    File.write!(path, contents)
    path
  end

  defp tmp_glb(name, gltf) do
    json = JSON.encode!(gltf)
    chunk = <<byte_size(json)::32-little, "JSON", json::binary>>
    total = 12 + byte_size(chunk)
    tmp_file(name, <<"glTF", 2::32-little, total::32-little, chunk::binary>>)
  end
end
