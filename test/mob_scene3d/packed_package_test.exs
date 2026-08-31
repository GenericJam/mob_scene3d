defmodule MobScene3d.PackedPackageTest do
  use ExUnit.Case, async: false

  # The packed-artifact regression (AGENTS.md → "The packaging lesson",
  # mob_new 0.4.27 / mob_dev 0.6.29): build the real Hex package, compile it
  # in isolation, and exercise the compile-time resource. Repo tests passing
  # is not packaging verification — a compile-time File.read! of a file Hex
  # omits (e.g. a repo-root dotfile) only fails when the *package* compiles.
  @tag :integration
  @tag timeout: 180_000
  test "packed Hex source compiles in isolation and its compile-time resources load" do
    root = Path.expand("../..", __DIR__)

    temp =
      Path.join(System.tmp_dir!(), "mob_scene3d_packed_#{System.unique_integer([:positive])}")

    package = Path.join(temp, "package")
    build = Path.join(temp, "build")
    on_exit(fn -> File.rm_rf!(temp) end)

    run_mix!(root, ["hex.build", "--unpack", "--output", package])

    # Compile-time resources must ship inside the package — in priv/, never
    # a repo-root dotfile (Hex omits those).
    assert File.exists?(Path.join(package, "priv/filament-version"))
    assert File.exists?(Path.join(package, "priv/mob_plugin.exs"))
    refute File.exists?(Path.join(package, ".tool-versions"))

    # Compile the package in isolation, reusing the repo's already-built
    # deps (mob is a prod dep) instead of a network deps.get — the mob_dev
    # toolchain_package_test pattern.
    link_compiled_dependencies(root, build)

    env = [
      {"MIX_ENV", "prod"},
      {"MIX_BUILD_PATH", build},
      {"MIX_DEPS_PATH", Path.join(root, "deps")}
    ]

    run_mix!(package, ["compile", "--warnings-as-errors"], env)

    expected_pin =
      root |> Path.join("priv/filament-version") |> File.read!() |> String.trim()

    probe = ~S'''
    beam = Mob.Scene3d.Assets.Tools |> :code.which() |> List.to_string()
    true = String.contains?(beam, "mob_scene3d_packed_")

    version = Mob.Scene3d.Assets.Tools.filament_version()
    true = Mob.Scene3d.Assets.Tools.cmgen_guidance() =~ version
    true = Code.ensure_loaded?(Mix.Tasks.Scene3d.Assets)
    true = Code.ensure_loaded?(Mob.Scene3d.IR)
    IO.puts("packed_scene3d_ok=" <> version)
    '''

    probe_output = run_mix!(package, ["run", "--no-compile", "--no-start", "-e", probe], env)
    assert probe_output =~ "packed_scene3d_ok=#{expected_pin}"
  end

  defp run_mix!(working_dir, args, env \\ []) do
    {output, status} =
      System.cmd(System.find_executable("mix"), args,
        cd: working_dir,
        env: env,
        stderr_to_stdout: true
      )

    assert status == 0, "mix #{Enum.join(args, " ")} failed:\n#{output}"
    output
  end

  defp link_compiled_dependencies(root, build) do
    build_lib = Path.join(build, "lib")
    File.mkdir_p!(build_lib)

    root
    |> Path.join("_build/test/lib/*")
    |> Path.wildcard()
    |> Enum.reject(&(Path.basename(&1) == "mob_scene3d"))
    |> Enum.each(fn dependency ->
      File.ln_s!(dependency, Path.join(build_lib, Path.basename(dependency)))
    end)
  end
end
