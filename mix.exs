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
  # `dev/` is the demo host app: a real Phoenix server that mounts the designer,
  # viewer and task list against a real database. It is how the screenshots in
  # the docs are produced, and the only way to exercise the bpmn-js hook.
  defp elixirc_paths(:dev), do: ["lib", "dev/lib"]
  defp elixirc_paths(_), do: ["lib"]

  # The library owns no supervision tree. Oban workers are started by the host's
  # Oban instance; the test support starts its own under test. `:xmerl` is OTP's
  # XML parser -- the compiler's only XML dependency, no hex package needed.
  #
  # In :dev the demo app supplies one, so `mix dev.server` has something to run.
  def application do
    [extra_applications: [:logger, :xmerl, :crypto, :ssl]] ++ dev_application()
  end

  defp dev_application do
    if Mix.env() == :dev, do: [mod: {AshBpmnDev.Application, []}], else: []
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
      {:bandit, "~> 1.0", only: :dev},
      {:simple_sat, "~> 0.1", only: [:dev, :test]},
      {:sourceror, "~> 1.8", only: [:dev, :test]},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:igniter, "~> 0.6", only: [:dev, :test]},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:mix_audit, ">= 0.0.0", only: [:dev, :test], runtime: false}
    ]
  end

  defp docs do
    [
      # Screenshots live in documentation/assets and are linked relatively:
      # `documentation/assets/x.png` from the README, `../assets/x.png` from a
      # topic page. Those are the paths GitHub needs, and on a private
      # repository they are the *only* ones that work — GitHub fetches absolute
      # image URLs through an unauthenticated proxy, so a raw.githubusercontent
      # link renders as a broken image for everyone, owner included.
      #
      # ex_doc flattens the topic pages into the doc root, where `../assets/`
      # points outside the output, so the shim below rewrites those two prefixes
      # to the copied location at render time. Assets are copied, not linked, so
      # the paths it rewrites to are guaranteed to exist.
      assets: %{"documentation/assets" => "documentation/assets"},
      before_closing_body_tag: &before_closing_body_tag/1,
      # The demo app under dev/ is compiled in :dev, which is the env ex_doc
      # runs in — without this filter its modules land in the published API
      # reference alongside the library's.
      filter_modules: fn module, _metadata ->
        not (Atom.to_string(module) =~ ~r/^Elixir\.AshBpmnDev/)
      end,
      extras: [
        {"README.md", title: "Home"},
        "documentation/topics/how-it-works.md",
        "documentation/topics/the-designer.md",
        "documentation/topics/running-processes.md",
        "documentation/topics/assignment-and-maker-checker.md",
        "documentation/topics/authorization-and-tenancy.md",
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
        Authorization: [
          AshBpmn.Scope,
          AshBpmn.SystemActor,
          AshBpmn.Config,
          ~r/AshBpmn\.Checks/
        ],
        Compiler: [AshBpmn.Compiler, AshBpmn.Expr],
        Web: [~r/AshBpmn\.Web/, AshBpmn.DesignerHook],
        Internals: ~r/.*/
      ]
    ]
  end

  # Points the topic pages' `../assets/...` image links at the copy ex_doc made
  # under documentation/assets. See the comment on `:assets` above for why the
  # markdown cannot simply spell the path ex_doc wants.
  defp before_closing_body_tag(:html) do
    """
    <script>
      document.addEventListener("DOMContentLoaded", function () {
        document.querySelectorAll('img[src^="../assets/"]').forEach(function (img) {
          img.setAttribute(
            "src",
            img.getAttribute("src").replace("../assets/", "documentation/assets/")
          );
        });
      });
    </script>
    """
  end

  defp before_closing_body_tag(_format), do: ""

  defp aliases do
    [
      credo: "credo --strict",
      test: ["test"],
      "dev.assets": ["cmd --cd dev/assets npm install", "cmd --cd dev/assets npm run build"],
      "dev.setup": ["ash_postgres.create", "ash_postgres.migrate", "run dev/priv/seeds.exs"],
      "dev.reset": ["ash_postgres.drop", "dev.setup"],
      "dev.server": ["run --no-halt"]
    ]
  end
end
