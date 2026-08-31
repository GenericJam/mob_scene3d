defmodule MobScene3d.MixProject do
  use Mix.Project

  def project do
    [
      app: :mob_scene3d,
      version: "0.1.0",
      description:
        "Declarative 3D scenes for Mob apps — one scene IR, diffed and " <>
          "patched over a NIF wire, rendered by Filament on both platforms",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      package: package()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/GenericJam/mob_scene3d"},
      # Native sources + the plugin manifest must ship in the package — the
      # host's native build compiles them from deps/mob_scene3d/priv
      # (mob_camera precedent).
      files: ~w(lib src priv mix.exs README* CHANGELOG*)
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
