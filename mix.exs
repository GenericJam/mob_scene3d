defmodule MobScene3d.MixProject do
  use Mix.Project

  def project do
    [
      app: :mob_scene3d,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:jump_credo_checks, "~> 0.1.0", only: [:dev, :test], runtime: false},
      # ex_slop — Credo plugin that catches AI-generated Elixir patterns
      # (blanket rescue, narrator-style docs, redundant Enum chains, etc).
      # Wired in via .credo.exs as `plugins: [{ExSlop, []}]`, mirroring mob.
      {:ex_slop, "~> 0.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      # Property tests: the patch grammar is locked by
      # apply(a, diff(a, b)) == b round-trips over generated scenes.
      {:stream_data, "~> 1.1", only: [:dev, :test]}
    ]
  end
end
