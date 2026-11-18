# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.Camera.MixProject do
  use Mix.Project

  @moduledoc """
  Camera support for Beam Bots: the `BB.Camera` behaviour, a bounded shared
  capture interface, and Membrane interoperability.
  """

  @version "0.1.0"

  def project do
    [
      aliases: aliases(),
      app: :bb_camera,
      consolidate_protocols: Mix.env() == :prod,
      deps: deps(),
      description: @moduledoc,
      dialyzer: dialyzer(),
      docs: docs(),
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      package: package(),
      start_permanent: Mix.env() == :prod,
      version: @version
    ]
  end

  defp dialyzer do
    [
      plt_add_apps: [:mix]
    ]
  end

  defp package do
    [
      files: ~w(lib priv .formatter.exs mix.exs README* CHANGELOG* LICENSE* usage-rules.md),
      maintainers: ["James Harton <james@harton.nz>"],
      licenses: ["Apache-2.0"],
      links: %{
        "Source" => "https://github.com/beam-bots/bb_camera",
        "Sponsor" => "https://github.com/sponsors/jimsynz"
      }
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp docs do
    [
      main: "readme",
      logo: "assets/logo.png",
      extras:
        ["README.md"]
        |> Enum.concat(Path.wildcard("documentation/**/*.{md,livemd,cheatmd}")),
      groups_for_extras: [
        Tutorials: ~r/tutorials\//
      ],
      source_ref: "main",
      source_url: "https://github.com/beam-bots/bb_camera"
    ]
  end

  defp aliases, do: []

  defp bb_dep(default) do
    case System.get_env("BB_VERSION") do
      nil -> default
      "local" -> [path: "../bb", override: true]
      "main" -> [git: "https://github.com/beam-bots/bb.git", override: true]
      version -> "~> #{version}"
    end
  end

  defp deps do
    [
      {:bb, bb_dep("~> 0.33")},

      # Optional: only `BB.Camera.Membrane.Source` needs these, and Membrane
      # constrains `decimal` to ~> 2.0 through `ratio`, which a robot that
      # isn't building a media pipeline shouldn't have to accept.
      {:membrane_core, "~> 1.3", optional: true},
      {:membrane_jpeg_format, "~> 0.1", optional: true},

      # Membrane's `ratio` still declares `decimal ~> 1.6 or ~> 2.0`, which
      # would hold this package's own dev/test tree down on a `decimal` with
      # open DoS advisories. `ratio` treats `decimal` as optional and Membrane
      # never hands it one, so overriding is safe here.
      #
      # Scoped to dev/test because Hex refuses to build a package that
      # overrides one of its own dependencies, and because it would do a
      # consumer no good anyway: Mix honours `override: true` only from the
      # top-level project. A consumer that opts into Membrane needs this line
      # in its own `mix.exs`; one that doesn't gets `decimal 3.x` from `bb`
      # with nothing to argue about.
      {:decimal, "~> 3.0", override: true, only: [:dev, :test]},

      # dev/test
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_check, "~> 0.16", only: [:dev, :test], runtime: false},
      {:ex_doc, ">= 0.0.0", only: [:dev, :test], runtime: false},
      {:git_ops, "~> 2.9", only: [:dev, :test], runtime: false},
      {:igniter, "~> 0.6", only: [:dev, :test], runtime: false}
    ]
  end

  defp elixirc_paths(env) when env in [:dev, :test], do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
end
