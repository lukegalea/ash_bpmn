# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.Diff do
  @moduledoc """
  What changed between two versions of a process definition, by what they mean.

  Two definitions are compared over the graph the engine runs (`graph`, compiled from the
  BPMN at save), never the XML, so moving a shape in the diagram or reformatting the
  document is not a change:

    * **steps**: each node by its id, added or removed, and for a node in both, each
      property of its configuration that changed: its type, name, the action or call a
      task runs, the decision a rule task consults, who a user task goes to, its timers
      and outcomes;
    * **routing**: each sequence flow by its id, where it goes from and to, and its
      condition;
    * **start**: which node the process starts at.

  The joins and boundary attachments the compiler derives from the nodes and flows are not
  compared on their own, and neither is the FEEL engine version stamped on the graph. A
  definition that did not compile has no graph and compares as empty; its validation says
  why.

  The result is a list of plain maps, one per change, with no struct, so a host can render
  or store it without depending on a type from this package:

      %{
        aspect: :routing,                 # one of aspects/0
        kind: :added | :removed | :changed,
        subject: "Flow_approved",         # the node or flow id; nil for :start
        option: "condition" | nil,        # for :changed, the property that changed
        from: term(), to: term()          # the old and new value, as plain data
      }

  An empty list means nothing this compares changed. It does not mean the documents are
  identical; compare the XML or its hash for that.
  """

  @typedoc "One change between two versions."
  @type change :: %{
          aspect: atom(),
          kind: :added | :removed | :changed,
          subject: String.t() | nil,
          option: String.t() | nil,
          from: term(),
          to: term()
        }

  @doc """
  What `diff/2` compares, in the order a reader should see it, each with an English label.
  A host translates the labels in its own catalogue.
  """
  @spec aspects() :: [{atom(), String.t()}]
  def aspects do
    [
      steps: "Steps",
      routing: "Routing",
      start: "Start"
    ]
  end

  @doc "The changes from `old` to `new`, two definitions (or maps with a `:graph`)."
  @spec diff(map(), map()) :: [change()]
  def diff(old, new) do
    old_graph = graph(old)
    new_graph = graph(new)

    keyed(:steps, part(old_graph, "nodes"), part(new_graph, "nodes")) ++
      keyed(:routing, part(old_graph, "flows"), part(new_graph, "flows")) ++
      value(:start, old_graph["start"], new_graph["start"])
  end

  defp graph(%{graph: %{} = graph}), do: graph
  defp graph(_definition), do: %{}

  defp part(graph, key) do
    case graph[key] do
      %{} = part -> part
      _ -> %{}
    end
  end

  defp value(_aspect, same, same), do: []
  defp value(aspect, from, to), do: [change(aspect, :changed, nil, nil, from, to)]

  # The changes between two maps of named subjects under `aspect`: added and removed names,
  # and, for a name in both, each property whose value differs. Values that are maps are
  # compared property by property; any other value is compared whole.
  defp keyed(aspect, old, new) do
    names = old |> Map.keys() |> Kernel.++(Map.keys(new)) |> Enum.uniq() |> Enum.sort()

    Enum.flat_map(names, fn name ->
      case {Map.fetch(old, name), Map.fetch(new, name)} do
        {:error, {:ok, value}} -> [change(aspect, :added, name, nil, nil, value)]
        {{:ok, value}, :error} -> [change(aspect, :removed, name, nil, value, nil)]
        {{:ok, same}, {:ok, same}} -> []
        {{:ok, from}, {:ok, to}} -> properties(aspect, name, from, to)
      end
    end)
  end

  defp properties(aspect, name, %{} = from, %{} = to) do
    from
    |> Map.keys()
    |> Kernel.++(Map.keys(to))
    |> Enum.uniq()
    |> Enum.sort_by(&to_string/1)
    |> Enum.flat_map(fn option ->
      case {Map.get(from, option), Map.get(to, option)} do
        {same, same} -> []
        {old, new} -> [change(aspect, :changed, name, option, old, new)]
      end
    end)
  end

  defp properties(aspect, name, from, to), do: [change(aspect, :changed, name, nil, from, to)]

  defp change(aspect, kind, subject, option, from, to) do
    %{
      aspect: aspect,
      kind: kind,
      subject: subject && to_string(subject),
      option: option && to_string(option),
      from: from,
      to: to
    }
  end
end
