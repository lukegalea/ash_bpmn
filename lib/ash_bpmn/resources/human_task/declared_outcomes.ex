# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.Resources.HumanTask.DeclaredOutcomes do
  @moduledoc """
  The generated `HumanTask` calculation `:outcomes`: what the task's BPMN step
  declares in `<ash:outcomes>`, so a host can offer a picker rather than a free
  text box.

  The compiler writes a user task's outcomes into the published graph
  (`graph["nodes"][node_id]["outcomes"]`), and an instance pins its definition
  for life, so the answer is read from the definition the task's instance runs,
  never from whatever is published now.

  `nil` when there is nothing to read: a standalone approval (no instance; the
  outcomes a `RequireApproval` change declares are not stored), or a node that
  declares none.

  The instances and definitions are read with the engine's authority, two
  queries for the whole batch of tasks. The graph is the engine's own data, and
  a person who may read a task need not be able to read process definitions.
  """

  use Ash.Resource.Calculation

  require Ash.Query

  alias AshBpmn.Scope

  @impl true
  def init(opts) do
    if is_atom(opts[:instance]) and not is_nil(opts[:instance]) do
      {:ok, opts}
    else
      {:error, "instance must be the Instance resource module"}
    end
  end

  @impl true
  def load(_query, _opts, _context), do: [:instance_id, :node_id]

  @impl true
  def calculate(tasks, opts, context) do
    scope = %Scope{actor: context.actor, tenant: context.tenant}
    graphs = graphs_by_instance(opts[:instance], tasks, scope)

    Enum.map(tasks, fn task ->
      case get_in(graphs, [task.instance_id, "nodes", task.node_id, "outcomes"]) do
        [_ | _] = outcomes -> outcomes
        _none -> nil
      end
    end)
  end

  defp graphs_by_instance(instance_resource, tasks, scope) do
    instance_ids = tasks |> Enum.map(& &1.instance_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    if instance_ids == [] do
      %{}
    else
      instances =
        instance_resource
        |> Ash.Query.for_read(:read)
        |> Ash.Query.filter(id in ^instance_ids)
        |> Ash.Query.select([:id, :definition_id])
        |> Ash.read!(Scope.engine(scope))

      definition_ids = instances |> Enum.map(& &1.definition_id) |> Enum.uniq()

      graphs =
        instance_resource
        |> Ash.Resource.Info.relationship(:definition)
        |> Map.fetch!(:destination)
        |> Ash.Query.for_read(:read)
        |> Ash.Query.filter(id in ^definition_ids)
        |> Ash.Query.select([:id, :graph])
        |> Ash.read!(Scope.engine(scope))
        |> Map.new(&{&1.id, &1.graph})

      Map.new(instances, &{&1.id, Map.get(graphs, &1.definition_id)})
    end
  end
end
