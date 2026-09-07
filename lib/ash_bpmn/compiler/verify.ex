# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.Compiler.Verify do
  @moduledoc false

  alias AshBpmn.Compiler.Errors
  alias AshBpmn.Runtime.Interpreter

  @spec verify(map()) :: [map()]
  def verify(graph) do
    errors = []
    nodes = graph["nodes"]
    flows = graph["flows"]
    joins = graph["joins"]

    # 1. Exactly one start event; >=1 end event
    errors = errors ++ verify_start_end(nodes)

    # 2. Reachability: every node reachable from start; every reachable node can reach some end
    errors = errors ++ verify_reachability(graph)

    # 3. Exclusive gateways: >=1 outgoing; exactly one default or all conditioned
    errors = errors ++ verify_exclusive_gateways(nodes, flows)

    # 4. userTask validation (already done in graph build, but verify completeness)
    # 5. serviceTask validation (already done in graph build)
    # These are handled in graph.ex; verify doesn't duplicate

    # 6. Parallel gateway mixed mode rejection
    errors = errors ++ verify_parallel_gateways(nodes, flows, joins)

    # 7. Business rule tasks: a configured resolver, and a decision that exists
    errors = errors ++ verify_business_rule_tasks(nodes)

    # 8. Service and send tasks: when the host's invoker can confirm its action
    #    catalogue, an action that does not exist fails here rather than at runtime
    errors = errors ++ verify_service_task_actions(nodes)

    # 9. Service and send tasks bound with ash:call: the callable ref resolves against
    #    the host's configured domains, and every declared input names an argument of
    #    the callable's action
    errors = errors ++ verify_call_bindings(nodes)

    errors
  end

  # Publishing a `businessRuleTask` against a decision that does not exist should fail here,
  # where a person is looking at the diagram, rather than at three in the morning on the first
  # instance that reaches the node.
  #
  # This asks the host a question and the host will answer it with a query. That is fine and
  # worth stating plainly, because the surrounding project has a rule that policy checks must
  # never query: the rule is about the per-request authorization path, and publishing is
  # neither per-request nor authorization.
  defp verify_business_rule_tasks(nodes) do
    decision_nodes =
      Enum.filter(nodes, fn {_id, node} -> node["type"] == "businessRuleTask" end)

    case {decision_nodes, AshBpmn.Config.decision_resolver()} do
      {[], _} ->
        []

      {[{id, _node} | _], nil} ->
        [
          Errors.error(
            id,
            "businessRuleTask '#{id}' needs a decision resolver, but none is configured. " <>
              "Set `config :ash_bpmn, decision_resolver: MyApp.Bpmn.Decisions`."
          )
        ]

      {decision_nodes, resolver} ->
        Enum.flat_map(decision_nodes, fn {id, node} ->
          ref = get_in(node, ["decision", "ref"])

          # A resolver that cannot answer `exists?/1` -- because it is unreachable, or the
          # host has not implemented it -- must not silently pass. Publishing an unverifiable
          # reference is the thing this check exists to prevent.
          case safe_exists?(resolver, ref) do
            :ok ->
              []

            {:error, :missing} ->
              [
                Errors.error(
                  id,
                  "businessRuleTask '#{id}' references decision '#{ref}', which does not exist"
                )
              ]

            {:error, reason} ->
              [
                Errors.error(
                  id,
                  "businessRuleTask '#{id}': could not verify decision '#{ref}': #{inspect(reason)}"
                )
              ]
          end
        end)
    end
  end

  defp safe_exists?(resolver, ref) do
    if resolver.exists?(ref), do: :ok, else: {:error, :missing}
  rescue
    e -> {:error, Exception.message(e)}
  end

  # The same publish-time promise the decision check makes, for the action seam. It is
  # opt-in on the host's side: an `ActionInvoker` that exports `exists?(ref) :: boolean`
  # is offering its catalogue for verification, so a diagram cannot ship against an
  # action that does not exist. An invoker without the export is simply not asked --
  # invoking the action is still the only contract it owes the engine.
  defp verify_service_task_actions(nodes) do
    invoker = Application.get_env(:ash_bpmn, :action_invoker)

    if invoker && function_exported?(invoker, :exists?, 1) do
      nodes
      |> Enum.filter(fn {_id, node} -> node["type"] in ["serviceTask", "sendTask"] end)
      |> Enum.flat_map(fn {id, node} ->
        ref = node["action"]
        type = node["type"]

        case safe_action_exists?(invoker, ref) do
          :ok ->
            []

          {:error, :missing} ->
            [
              Errors.error(
                id,
                "#{type} '#{id}' references action '#{ref}', which does not exist"
              )
            ]

          {:error, reason} ->
            [
              Errors.error(
                id,
                "#{type} '#{id}': could not verify action '#{ref}': #{inspect(reason)}"
              )
            ]
        end
      end)
    else
      []
    end
  end

  defp safe_action_exists?(invoker, ref) do
    if invoker.exists?(ref), do: :ok, else: {:error, :missing}
  rescue
    e -> {:error, Exception.message(e)}
  end

  # The publish-time promise for `ash:call`, mirroring the decision check above: a
  # diagram cannot ship against a callable that does not resolve, or against declared
  # inputs the callee would not know what to do with. The resolution is the *same*
  # walk the runtime does (`AshBpmn.Runtime.Interpreter.resolve_callable/1`), so a
  # diagram that verified here is the diagram that executes -- the catalogue is the
  # host's configured domains, and a ref outside them does not exist.
  defp verify_call_bindings(nodes) do
    nodes
    |> Enum.filter(fn {_id, node} -> is_map_key(node, "call") end)
    |> Enum.flat_map(fn {id, node} ->
      call = node["call"]
      ref = call["ref"]
      type = node["type"]

      case Interpreter.resolve_callable(ref) do
        {:ok, %{resource: resource, action: action_name}} ->
          verify_call_inputs(id, type, ref, resource, action_name, node)

        {:error, reason} ->
          [
            Errors.error(
              id,
              "#{type} '#{id}' references callable '#{ref}', which does not exist (#{reason})"
            )
          ]
      end
    end)
  end

  defp verify_call_inputs(id, type, ref, resource, action_name, node) do
    case Ash.Resource.Info.action(resource, action_name) do
      nil ->
        [
          Errors.error(
            id,
            "#{type} '#{id}': could not verify callable '#{ref}': the action is no longer on the resource"
          )
        ]

      action ->
        # Every action type -- generic, create, update, destroy, read -- carries its
        # declared arguments here, so one check covers the lot. Input names arrive from
        # XML as strings; argument names are atoms, and the comparison goes
        # atom-to-string, never the other way.
        argument_names = MapSet.new(action.arguments, &Atom.to_string(&1.name))

        node
        |> Map.get("inputs", [])
        |> Enum.flat_map(fn input ->
          name = input["name"]

          if MapSet.member?(argument_names, name) do
            []
          else
            [
              Errors.error(
                id,
                "#{type} '#{id}' declares input '#{name}', which is not an argument of callable '#{ref}'"
              )
            ]
          end
        end)
    end
  end

  defp verify_start_end(nodes) do
    starts =
      nodes
      |> Enum.filter(fn {_id, n} -> n["type"] == "startEvent" end)

    ends =
      nodes
      |> Enum.filter(fn {_id, n} -> n["type"] == "endEvent" end)

    errors = []

    errors =
      case starts do
        [] ->
          [Errors.error("process", "Process must have exactly one start event") | errors]

        [{_id, _}] ->
          errors

        _multiple ->
          ids = Enum.map_join(starts, ", ", fn {id, _} -> "'#{id}'" end)

          [
            Errors.error(
              "process",
              "Process has multiple start events: #{ids}; exactly one is required"
            )
            | errors
          ]
      end

    errors =
      if ends == [] do
        [Errors.error("process", "Process must have at least one end event") | errors]
      else
        errors
      end

    errors
  end

  defp verify_reachability(graph) do
    nodes = graph["nodes"]
    flows = graph["flows"]
    start = graph["start"]

    errors = []

    # Build adjacency: outgoing from each node
    outgoing =
      flows
      |> Enum.group_by(fn {_fid, f} -> f["from"] end, fn {_fid, f} -> f["to"] end)

    # BFS from start to find reachable nodes
    reachable = bfs_reachable(start, outgoing)

    # Check all nodes are reachable
    unreachable =
      nodes
      |> Map.keys()
      |> MapSet.new()
      |> MapSet.difference(reachable)

    errors =
      unreachable
      |> Enum.map(fn id ->
        Errors.error(id, "Node '#{id}' is not reachable from the start event")
      end)
      |> Enum.concat(errors)

    # For each reachable node, check it can reach some end event
    end_nodes =
      nodes
      |> Enum.filter(fn {_id, n} -> n["type"] == "endEvent" end)
      |> Enum.map(fn {id, _} -> id end)
      |> MapSet.new()

    errors =
      reachable
      |> Enum.filter(fn id ->
        nodes[id]["type"] != "endEvent" and
          not can_reach_end?(id, outgoing, end_nodes, MapSet.new())
      end)
      |> Enum.map(fn id ->
        Errors.error(id, "Node '#{id}' cannot reach any end event")
      end)
      |> Enum.concat(errors)

    # Check no unreachable end events (end events with no incoming flows)
    unreachable_ends =
      end_nodes
      |> Enum.filter(fn id -> not MapSet.member?(reachable, id) end)

    errors =
      unreachable_ends
      |> Enum.map(fn id ->
        Errors.error(id, "End event '#{id}' is not reachable from the start event")
      end)
      |> Enum.concat(errors)

    errors
  end

  defp bfs_reachable(start, outgoing) do
    do_bfs([start], outgoing, MapSet.new([start]))
  end

  defp do_bfs([], _outgoing, visited), do: visited

  defp do_bfs([current | rest], outgoing, visited) do
    neighbors = Map.get(outgoing, current, [])

    new_neighbors =
      neighbors
      |> Enum.filter(fn n -> not MapSet.member?(visited, n) end)

    new_visited = Enum.reduce(new_neighbors, visited, &MapSet.put(&2, &1))
    do_bfs(rest ++ new_neighbors, outgoing, new_visited)
  end

  defp can_reach_end?(node_id, outgoing, end_nodes, visited) do
    if MapSet.member?(visited, node_id) do
      false
    else
      visited = MapSet.put(visited, node_id)

      if MapSet.member?(end_nodes, node_id) do
        true
      else
        neighbors = Map.get(outgoing, node_id, [])

        Enum.any?(neighbors, fn n -> can_reach_end?(n, outgoing, end_nodes, visited) end)
      end
    end
  end

  defp verify_exclusive_gateways(nodes, flows) do
    nodes
    |> Enum.filter(fn {_id, n} -> n["type"] == "exclusiveGateway" end)
    |> Enum.flat_map(fn {id, node} ->
      outgoing =
        flows
        |> Enum.filter(fn {_fid, f} -> f["from"] == id end)

      if outgoing == [] do
        [
          Errors.error(
            id,
            "exclusiveGateway '#{id}' must have at least one outgoing sequenceFlow"
          )
        ]
      else
        verify_exclusive_branches(id, node, outgoing)
      end
    end)
  end

  defp verify_exclusive_branches(gw_id, node, outgoing) do
    default_flow = node["default_flow"]

    defaults =
      outgoing
      |> Enum.filter(fn {_fid, f} -> f["condition"] == nil end)

    cond do
      default_flow != nil and length(defaults) > 1 ->
        [
          Errors.error(
            gw_id,
            "exclusiveGateway '#{gw_id}' has a default flow but multiple outgoing flows without conditions"
          )
        ]

      default_flow != nil and length(defaults) == 1 ->
        default_fid = elem(hd(defaults), 0)

        if default_fid != default_flow do
          [
            Errors.error(
              gw_id,
              "exclusiveGateway '#{gw_id}' default attribute '#{default_flow}' does not match the unconditioned flow '#{default_fid}'"
            )
          ]
        else
          # Check the default flow doesn't also have a condition
          if Map.get(node, "default_flow") != nil and
               Enum.any?(outgoing, fn {fid, f} ->
                 fid == default_flow and f["condition"] != nil
               end) do
            [
              Errors.error(
                gw_id,
                "exclusiveGateway '#{gw_id}' default flow '#{default_flow}' must not have a conditionExpression"
              )
            ]
          else
            []
          end
        end

      default_flow == nil and defaults != [] ->
        [
          Errors.error(
            gw_id,
            "exclusiveGateway '#{gw_id}' has outgoing flows without conditions but no default flow; every outgoing flow must have a condition or exactly one must be the default"
          )
        ]

      true ->
        []
    end
  end

  defp verify_parallel_gateways(nodes, flows, joins) do
    nodes
    |> Enum.filter(fn {_id, n} -> n["type"] == "parallelGateway" end)
    |> Enum.flat_map(fn {id, _node} ->
      incoming =
        flows
        |> Enum.filter(fn {_fid, f} -> f["to"] == id end)

      outgoing =
        flows
        |> Enum.filter(fn {_fid, f} -> f["from"] == id end)

      has_join = length(incoming) > 1
      has_fork = length(outgoing) > 1

      cond do
        has_join and has_fork ->
          [
            Errors.error(
              id,
              "parallelGateway '#{id}' is both a fork (#{length(outgoing)} outgoing) and a join (#{length(incoming)} incoming); mixed parallel gateways are not supported"
            )
          ]

        has_join ->
          # Verify waits_for matches actual incoming flows
          join_entry = Map.get(joins, id, %{"waits_for" => []})
          waits_for = join_entry["waits_for"]
          actual_sources = Enum.map(incoming, fn {_fid, f} -> f["from"] end)

          if Enum.sort(waits_for) != Enum.sort(actual_sources) do
            [
              Errors.error(
                id,
                "parallelGateway '#{id}' joins 'waits_for' does not match actual incoming flows"
              )
            ]
          else
            []
          end

        true ->
          []
      end
    end)
  end
end
