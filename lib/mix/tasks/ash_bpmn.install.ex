# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.AshBpmn.Install do
    @shortdoc "Installs AshBpmn. Invoked by `mix igniter.install ash_bpmn`"

    @moduledoc """
    Wires AshBpmn into a project.

    Does one thing, and it is the one thing nobody remembers to do by hand:
    adds `:ash_bpmn` to `import_deps` in the project's `.formatter.exs`.
    Without it the formatter does not know the `ash_bpmn` DSL and may
    rewrite DSL calls on the first save.
    """

    use Igniter.Mix.Task

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{group: :ash}
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      Igniter.Project.Formatter.import_dep(igniter, :ash_bpmn)
    end
  end
else
  defmodule Mix.Tasks.AshBpmn.Install do
    @shortdoc "Installs AshBpmn | Install `igniter` to use"

    @moduledoc @shortdoc

    use Mix.Task

    @impl Mix.Task
    def run(_argv) do
      Mix.shell().error("""
      The task 'ash_bpmn.install' requires igniter. Please install igniter and try again.

      For more information, see: https://hexdocs.pm/igniter/readme.html#installation
      """)

      exit({:shutdown, 1})
    end
  end
end
