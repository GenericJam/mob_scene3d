defmodule Mix.Tasks.Scene3d.AssetsTest do
  use ExUnit.Case, async: false

  @fixture Path.expand("../../fixtures/bevel_cube.glb", __DIR__)

  setup do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
    :ok
  end

  test "passes a directory of valid .glb assets (validator off)" do
    dir = tmp_dir("valid")
    File.cp!(@fixture, Path.join(dir, "cube.glb"))

    Mix.Tasks.Scene3d.Assets.run([dir, "--no-validate"])

    assert_received {:mix_shell, :info, [summary]}, "expected the per-file report line"
    assert summary =~ "cube.glb"
    assert flushed_output() =~ "1 asset(s) valid"
  end

  test "fails loudly on a rejected format, naming the converter" do
    dir = tmp_dir("usdz")
    File.write!(Path.join(dir, "chair.usdz"), "usdz bytes")

    error = assert_raise Mix.Error, fn -> Mix.Tasks.Scene3d.Assets.run([dir, "--no-validate"]) end
    assert error.message =~ "1 of 1 asset(s) failed"
    assert flushed_output() =~ "Apple-only"
  end

  test "raises when no model files are found" do
    dir = tmp_dir("empty")

    assert_raise Mix.Error, ~r/no model files found/, fn ->
      Mix.Tasks.Scene3d.Assets.run([dir, "--no-validate"])
    end
  end

  test "enforces budgets from --config" do
    dir = tmp_dir("budget")
    File.cp!(@fixture, Path.join(dir, "cube.glb"))
    config = Path.join(dir, "budgets.exs")
    File.write!(config, "%{max_triangles: 1}")

    assert_raise Mix.Error, ~r/asset\(s\) failed/, fn ->
      Mix.Tasks.Scene3d.Assets.run([dir, "--no-validate", "--config", config])
    end

    assert flushed_output() =~ "max_triangles 1"
  end

  test "--ktx2 rejects unknown modes and non-glb inputs" do
    assert_raise Mix.Error, ~r/etc1s or uastc/, fn ->
      Mix.Tasks.Scene3d.Assets.run(["x.glb", "--ktx2", "zstd"])
    end

    assert_raise Mix.Error, ~r/operates on \.glb/, fn ->
      Mix.Tasks.Scene3d.Assets.run(["x.gltf", "--ktx2", "etc1s"])
    end
  end

  test "--out with --ktx2 requires exactly one input" do
    assert_raise Mix.Error, ~r/exactly one input/, fn ->
      Mix.Tasks.Scene3d.Assets.run(["a.glb", "b.glb", "--ktx2", "etc1s", "--out", "c.glb"])
    end
  end

  @tag :requires_cmgen
  test "--ibl precomputes an environment via cmgen" do
    dir = tmp_dir("ibl")
    panorama = Path.join(dir, "studio.png")
    File.write!(panorama, equirect_png())
    out = Path.join(dir, "env_studio")

    Mix.Tasks.Scene3d.Assets.run(["--ibl", panorama, "--out", out, "--size", "16"])

    output = flushed_output()
    assert output =~ "IBL environment written"
    assert output =~ "env_studio_ibl.ktx"
    assert output =~ "env_studio_skybox.ktx"
  end

  defp tmp_dir(label) do
    dir =
      Path.join(System.tmp_dir!(), "scene3d_task_#{label}_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp flushed_output do
    flush_shell([]) |> Enum.join("\n")
  end

  defp flush_shell(acc) do
    receive do
      {:mix_shell, _kind, [message]} -> flush_shell([message | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # Minimal 8-bit grayscale equirectangular (2:1) PNG — cmgen's smallest
  # honest input; committing a binary fixture for this would be opaque.
  defp equirect_png do
    width = 64
    height = 32

    raw =
      for y <- 0..(height - 1), into: <<>> do
        row = for x <- 0..(width - 1), into: <<>>, do: <<rem(x * 4 + y * 8, 256)>>
        <<0>> <> row
      end

    zstream = :zlib.open()
    :ok = :zlib.deflateInit(zstream)
    idat = IO.iodata_to_binary(:zlib.deflate(zstream, raw, :finish))
    :zlib.deflateEnd(zstream)
    :zlib.close(zstream)

    header = <<width::32, height::32, 8, 0, 0, 0, 0>>

    <<137, ?P, ?N, ?G, ?\r, ?\n, 26, ?\n>> <>
      png_chunk("IHDR", header) <> png_chunk("IDAT", idat) <> png_chunk("IEND", "")
  end

  defp png_chunk(type, data) do
    <<byte_size(data)::32, type::binary, data::binary, :erlang.crc32(type <> data)::32>>
  end
end
