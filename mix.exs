defmodule MobScene3d.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/GenericJam/mob_scene3d"

  def project do
    [
      app: :mob_scene3d,
      version: @version,
      description:
        "Declarative 3D scenes for Mob apps — one scene IR, diffed and " <>
          "patched over a NIF wire, rendered by Filament on both platforms",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      aliases: aliases(),
      source_url: @source_url,
      package: package(),
      docs: docs()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp aliases do
    # `mix setup` after cloning installs deps and activates the shared git
    # hooks (.githooks): format / Credo --strict / compile run on every push
    # and the full suite when mix.exs changes — the same gate CI enforces.
    [setup: ["deps.get", "cmd git config core.hooksPath .githooks"]]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      # Native sources + the plugin manifest must ship in the package — the
      # host's native build compiles them from deps/mob_scene3d/priv
      # (mob_camera precedent). Anything read at COMPILE time also lives in
      # priv/, never a repo-root dotfile (AGENTS.md → "The packaging lesson",
      # mob_new 0.4.27 / mob_dev 0.6.29); the packed-artifact regression
      # (test/mob_scene3d/packed_package_test.exs) compiles exactly this
      # file set in isolation.
      files: ~w(lib src priv guides mix.exs mix.lock README* CHANGELOG* LICENSE)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_url: @source_url,
      source_url_pattern: "#{@source_url}/blob/master/%{path}#L%{line}",
      extras: [
        "README.md": [title: "mob_scene3d"],
        "CHANGELOG.md": [title: "Changelog"],
        "guides/assets.md": [title: "Asset Pipeline"]
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:mob, "~> 0.7"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:jump_credo_checks, "~> 0.1.0", only: [:dev, :test], runtime: false},
      # ex_slop — Credo plugin that catches AI-generated Elixir patterns
      # (blanket rescue, narrator-style docs, redundant Enum chains, etc).
      # Wired in via .credo.exs as `plugins: [{ExSlop, []}]`, mirroring mob.
      {:ex_slop, "~> 0.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      # Erlang formatting for src/ (the NIF stub) — the AGENTS.md gate.
      {:erlfmt, "~> 1.3", only: [:dev, :test], runtime: false},
      # Property tests: the patch grammar is locked by
      # apply(a, diff(a, b)) == b round-trips over generated scenes.
      {:stream_data, "~> 1.1", only: [:dev, :test]}
    ]
  end
end
