# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.MixProject do
  use Mix.Project

  @version "0.1.0"

  @description """
  BPMN-designed, Ash-executed business processes: an embedded bpmn-js designer, a
  compiler from BPMN XML to an immutable graph snapshot, and a durable token
  interpreter over Postgres and Oban.
  """

  def project do
    [
      app: :ash_bpmn,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      aliases: aliases(),
      deps: deps(),
      docs: &docs/0,
      description: @description,
      package: package(),
      source_url: "https://github.com/lukegalea/ash_bpmn",
      homepage_url: "https://github.com/lukegalea/ash_bpmn",
      dialyzer: [
        plt_add_apps: [:mix, :ex_unit],
        plt_file: {:no_warn, "priv/plts/dialyzer.plt"},
        ignore_warnings: ".dialyzer_ignore.exs",
        list_unused_filters: true
      ]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # The library owns no supervision tree. Oban workers are started by the host's
  # Oban instance; the test support starts its own under test. `:xmerl` is OTP's
  # XML parser -- the compiler's only XML dependency, no hex package needed.
  def application do
    [extra_applications: [:logger, :xmerl, :crypto, :ssl]]
  end

  defp package do
    [
      name: :ash_bpmn,
      licenses: ["MIT"],
      maintainers: ["Luke Galea <luke@ideaforge.org>"],
      files: ~w(lib priv/js documentation CHANGELOG.md LICENSE LICENSE.license LICENSES
        README.md usage-rules.md mix.exs .formatter.exs),
      links: %{
        "GitHub" => "https://github.com/lukegalea/ash_bpmn"
      }
    ]
  end

  defp deps do
    [
      {:ash, "~> 3.0"},
      {:ash_postgres, "~> 2.0"},
      {:oban, "~> 2.0"},
      {:jason, "~> 1.2"},
      {:phoenix_live_view, "~> 1.0"},
      # dev/test only
      {:simple_sat, "~> 0.1", only: [:dev, :test]},
      {:sourceror, "~> 1.8", only: [:dev, :test]},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:igniter, "~> 0.6", only: [:dev, :test]},
      {:mix_audit, ">= 0.0.0", only: [:dev, :test], runtime: false}
    ]
  end

  defp docs do
    [
      extras: [
        {"README.md", title: "Home"},
        "documentation/topics/how-it-works.md",
        "documentation/topics/the-designer.md",
        "documentation/topics/running-processes.md",
        "documentation/topics/assignment-and-maker-checker.md",
        "documentation/topics/what-it-refuses.md",
        "CHANGELOG.md"
      ],
      groups_for_extras: [
        Tutorials: ~r'documentation/tutorials',
        Topics: ~r'documentation/topics'
      ],
      groups_for_modules: [
        Resources: [~r/AshBpmn\.Resources/],
        Runtime: [~r/AshBpmn\.Runtime/, AshBpmn],
        Compiler: [AshBpmn.Compiler, AshBpmn.Expr],
        Web: [~r/AshBpmn\.Web/, AshBpmn.DesignerHook],
        Internals: ~r/.*/
      ]
    ]
  end

  defp aliases do
    [
      credo: "credo --strict",
      test: ["test"]
    ]
  end
end
