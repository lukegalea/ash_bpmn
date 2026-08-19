# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.Runtime.Interpreter do
  @moduledoc """
  Node execution dispatcher — interprets each BPMN node type.

  Called by AdvanceWorker with the graph, node config, and context.
  Returns `{:ok, actions}` where actions is a list of effects to apply
  (create tokens, events, enqueue jobs, complete instance, etc.).
  """

  @doc """
  Dispatches execution for a single node.

  Returns `{:ok, effects}` where effects is a keyword list of:
    * `{:tokens, [token_attrs]}` — new tokens to create
    * `{:events, [event_attrs]}` — process events to record
    * `{:jobs, [{worker, args, opts}]}` — jobs to enqueue
    * `{:complete_instance, outcome}` — mark instance completed
    * `{:tasks, [{task_ref, task_attrs}]}` — human tasks to create
    * `{:candidates, {task_ref, [cand_attrs]}}` — candidates for that task
    * `{:timers, {task_ref, [{worker, args, opts}]}}` — timer jobs to enqueue and
      record on the task, so completing it early can cancel them

  `task_ref` is an opaque placeholder that ties the three task effects together;
  the worker resolves it to the created row's real id.
    * `{:consume_token, true}` — consume the current token
    * `{:park_token, true}` — leave token as executing (user tasks)
  """
  @spec dispatch(map(), String.t(), map(), map()) :: {:ok, keyword()} | {:error, String.t()}
  def dispatch(graph, node_id, node, ctx) do
    type = node["type"]

    case type do
      "startEvent" ->
        start_event(graph, node_id, node, ctx)

      "endEvent" ->
        end_event(graph, node_id, node, ctx)

      "serviceTask" ->
        service_task(graph, node_id, node, ctx)

      "businessRuleTask" ->
        business_rule_task(graph, node_id, node, ctx)

      "userTask" ->
        user_task(graph, node_id, node, ctx)

      "exclusiveGateway" ->
        exclusive_gateway(graph, node_id, node, ctx)

      "parallelGateway" ->
        parallel_gateway(graph, node_id, node, ctx)

      other ->
        {:error, "unsupported node type: #{other}"}
    end
  end

  # ── startEvent ───────────────────────────────────────────────────────────

  defp start_event(graph, node_id, _node, ctx) do
    outgoing = find_outgoing_flows(graph, node_id)

    # The start token is consumed like any other: the branch continues on the
    # token minted for the next node. Leaving it executing strands a token on
    # the start event for the life of the instance.
    effects =
      [
        consume_token: true,
        events: [event_attrs(ctx, node_id, :node_entered)]
      ] ++ follow_flows(graph, outgoing, ctx)

    {:ok, effects}
  end

  # ── endEvent ─────────────────────────────────────────────────────────────

  defp end_event(_graph, node_id, node, ctx) do
    outcome = node["outcome"]

    effects = [
      consume_token: true,
      events: [event_attrs(ctx, node_id, :node_completed, %{"outcome" => outcome})],
      complete_instance: outcome
    ]

    {:ok, effects}
  end

  # ── serviceTask ─────────────────────────────────────────────────────────

  # ── businessRuleTask ─────────────────────────────────────────────────────

  # The graph asks a question and routes on the answer; it does not know how the answer was
  # reached. Everything about *what* a decision is belongs to the host's
  # `AshBpmn.DecisionResolver`, which is the same arrangement service tasks and human tasks
  # already have, and for the same reason: a rule inside the graph is a rule every other caller
  # bypasses.
  defp business_rule_task(graph, node_id, node, ctx) do
    resolver = AshBpmn.Config.decision_resolver!()
    decision = node["decision"] || %{}
    ref = decision["ref"]

    with {:ok, inputs} <- resolve_decision_inputs(node["inputs"] || [], ctx, node_id),
         {:ok, raw} <- invoke_decision(resolver, ref, inputs, ctx, node_id),
         {:ok, result} <- AshBpmn.DecisionResolver.normalize_result(raw),
         {:ok, routing} <- promoted_signals(node["promote"] || [], result.outputs, node_id) do
      outgoing = find_outgoing_flows(graph, node_id)

      # Merged over what this token already carried, so a chain of decision nodes accumulates
      # rather than overwrites. `follow_flows/3` reads it back out of the context and puts it
      # on every child token it creates.
      ctx = Map.put(ctx, :routing_override, Map.merge(current_routing(ctx), routing))

      effects =
        [
          consume_token: true,
          events: [
            event_attrs(ctx, node_id, :node_completed),
            event_attrs(ctx, node_id, :decision_evaluated, %{
              "decision_ref" => ref,
              "decision_version" => normalize_version(result[:version]),
              "rule_ids" => result[:rule_ids] || [],
              # The inputs, and only the *promoted* outputs. A decision's full result is the
              # decision layer's record to keep, and duplicating it here would produce two logs
              # that can disagree.
              "inputs" => Map.new(inputs, fn {k, v} -> {k, inspect_value(v)} end),
              "promoted" => routing
            })
          ]
        ] ++ follow_flows(graph, outgoing, ctx)

      {:ok, effects}
    else
      {:error, reason} ->
        # Same convention as a service task: raise, so Oban retries and the instance fails
        # after max_attempts rather than routing itself down a branch nobody chose.
        raise "business rule task '#{node_id}' failed: #{inspect(reason)}"
    end
  end

  defp resolve_decision_inputs(inputs, ctx, node_id) do
    expr_ctx = build_expr_ctx(ctx)

    Enum.reduce_while(inputs, {:ok, %{}}, fn input, {:ok, acc} ->
      case AshBpmn.Feel.evaluate(AshBpmn.Feel.print(input["from"]), expr_ctx) do
        {:ok, value} ->
          {:cont, {:ok, Map.put(acc, input["name"], value)}}

        {:error, reason} ->
          {:halt,
           {:error, "node #{node_id}: input '#{input["name"]}' could not be evaluated: #{reason}"}}
      end
    end)
  end

  defp invoke_decision(resolver, ref, inputs, ctx, node_id) do
    case resolver.decide(ref, inputs, decision_context(ctx, node_id)) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
      other -> {:error, "decision resolver returned #{inspect(other)}"}
    end
  end

  defp decision_context(ctx, node_id) do
    %{
      subject: ctx[:subject],
      actor: ctx[:actor],
      tenant: ctx[:tenant],
      instance: ctx[:instance],
      token: ctx[:token],
      node_id: node_id
    }
  end

  # A token carries routing, not business data, and this is where that stops being a
  # convention and becomes a check. Only declared signals are promoted; each must be a scalar;
  # names and values are length-bounded. A decision that hands back a nested map does not get
  # to put it on the token.
  @max_signal_name_bytes 64
  @max_signal_value_bytes 256

  defp promoted_signals(promote, outputs, node_id) do
    Enum.reduce_while(promote, {:ok, %{}}, fn signal, {:ok, acc} ->
      name = signal["name"]
      # Look the signal up by string key, and fall back to scanning for an equivalent atom key
      # rather than calling `String.to_atom/1` on it. The name comes out of tenant-authored
      # BPMN XML, and creating an uncollectable atom from that is the exact defect the old
      # expression language shipped with.
      value = fetch_output(outputs, signal["from"] || name)

      cond do
        value == :__absent__ and signal["required"] ->
          {:halt, {:error, "node #{node_id}: decision did not return required signal '#{name}'"}}

        value == :__absent__ ->
          {:cont, {:ok, acc}}

        not scalar?(value) ->
          {:halt,
           {:error,
            "node #{node_id}: signal '#{name}' is #{inspect(value, limit: 3)}, which is not a scalar; " <>
              "a token carries routing, not business data"}}

        byte_size(name) > @max_signal_name_bytes ->
          {:halt, {:error, "node #{node_id}: signal name '#{name}' is too long"}}

        byte_size(to_string_value(value)) > @max_signal_value_bytes ->
          {:halt, {:error, "node #{node_id}: signal '#{name}' has an over-long value"}}

        true ->
          {:cont, {:ok, Map.put(acc, name, to_string_value(value))}}
      end
    end)
  end

  defp fetch_output(outputs, name) do
    case Map.fetch(outputs, name) do
      {:ok, value} ->
        value

      :error ->
        Enum.find_value(outputs, :__absent__, fn {key, value} ->
          if is_atom(key) and Atom.to_string(key) == name, do: value
        end)
    end
  end

  defp scalar?(value),
    do:
      is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value) or
        is_struct(value, Decimal) or is_atom(value)

  # Stored as strings so the token's jsonb round-trips to exactly what FEEL will compare
  # against, rather than to whatever the JSON encoder chose.
  defp to_string_value(nil), do: ""
  defp to_string_value(value) when is_boolean(value), do: to_string(value)
  defp to_string_value(%Decimal{} = value), do: Decimal.to_string(value, :normal)
  defp to_string_value(value) when is_binary(value), do: value
  defp to_string_value(value), do: to_string(value)

  defp current_routing(ctx) do
    cond do
      is_map(ctx[:routing_override]) ->
        ctx[:routing_override]

      match?(%{routing: routing} when is_map(routing), ctx[:token]) ->
        ctx[:token].routing

      true ->
        %{}
    end
  end

  defp normalize_version(nil), do: nil
  defp normalize_version(version) when is_binary(version), do: version
  defp normalize_version(version), do: to_string(version)

  defp inspect_value(%Decimal{} = value), do: Decimal.to_string(value, :normal)

  defp inspect_value(value) when is_binary(value) or is_number(value) or is_boolean(value),
    do: value

  defp inspect_value(value), do: inspect(value, limit: 5)

  defp service_task(graph, node_id, node, ctx) do
    action = node["action"]
    invoker = AshBpmn.Config.action_invoker!()

    case invoker.invoke(action, ctx) do
      :ok ->
        outgoing = find_outgoing_flows(graph, node_id)

        effects =
          [
            consume_token: true,
            events: [
              event_attrs(ctx, node_id, :node_completed),
              event_attrs(ctx, node_id, :action_invoked, %{"action" => action})
            ]
          ] ++ follow_flows(graph, outgoing, ctx)

        {:ok, effects}

      {:ok, _result} ->
        outgoing = find_outgoing_flows(graph, node_id)

        effects =
          [
            consume_token: true,
            events: [
              event_attrs(ctx, node_id, :node_completed),
              event_attrs(ctx, node_id, :action_invoked, %{"action" => action})
            ]
          ] ++ follow_flows(graph, outgoing, ctx)

        {:ok, effects}

      {:error, reason} ->
        # Raise so Oban retries; the worker will catch after max_attempts
        raise "service task '#{action}' failed: #{inspect(reason)}"
    end
  end

  # ── userTask ─────────────────────────────────────────────────────────────

  defp user_task(_graph, node_id, node, ctx) do
    resolver = AshBpmn.Config.assignment_resolver!()
    instance = ctx[:instance]
    token = ctx[:token]

    # Resolve candidates
    candidate_specs = node["candidates"] || []
    exclusion_specs = node["exclusions"] || []

    candidate_ctx = Map.take(ctx, [:subject, :actor, :instance, :task, :assigns])

    {:ok, candidates} = resolver.candidates(candidate_specs, candidate_ctx)
    {:ok, exclusions} = resolver.exclusions(exclusion_specs, candidate_ctx)

    filtered_candidates =
      Enum.reject(candidates, fn c -> c.id in exclusions end)

    # A placeholder key, not a real id: the interpreter is pure, so it cannot
    # know the id the data layer will assign. It labels the task here and the
    # worker swaps in the real id when creating candidates and timers.
    task_ref = Ash.UUID.generate()

    task_attrs = %{
      instance_id: instance.id,
      token_id: token.id,
      node_id: node_id,
      name: node["name"] || node_id,
      status: :open
    }

    candidate_attrs =
      Enum.map(filtered_candidates, fn c ->
        %{principal_type: c.type, principal_id: c.id}
      end)

    effects = [
      park_token: true,
      events: [event_attrs(ctx, node_id, :task_created)],
      tasks: [{task_ref, task_attrs}],
      candidates: {task_ref, candidate_attrs},
      timers: {task_ref, timer_jobs(node["timers"] || [])}
    ]

    {:ok, effects}
  end

  # ── exclusiveGateway ─────────────────────────────────────────────────────

  defp exclusive_gateway(graph, node_id, node, ctx) do
    outgoing = find_outgoing_flows(graph, node_id)
    default_flow = node["default_flow"]

    # Evaluate conditions in order; the first that is *true* wins.
    #
    # FEEL is three-valued, and the three values are not interchangeable here. `false` is an
    # ordinary answer. `null` means the condition produced no answer at all -- a path the
    # subject does not have, a type mismatch -- and while it also does not take the branch, it
    # is recorded, because a condition that is silently never true looks exactly like one that
    # is legitimately false and is a far worse bug. An `{:error, _}` is not a FEEL value at all
    # (a timeout, a malformed snapshot) and must not degrade into "branch not taken": it
    # propagates, the job retries, and the instance fails rather than routing itself down a
    # path nobody chose.
    expr_ctx = build_expr_ctx(ctx)

    case evaluate_flows(outgoing, expr_ctx) do
      {:error, reason} ->
        {:error, "exclusive gateway #{node_id}: #{reason}"}

      {:ok, chosen_flow, nulls} ->
        target_flow = chosen_flow || Enum.find(outgoing, &(&1["id"] == default_flow))

        null_events =
          Enum.map(nulls, fn flow ->
            event_attrs(ctx, node_id, :condition_null, %{
              "flow_id" => flow["id"],
              "expression" => AshBpmn.Feel.print(flow["condition"])
            })
          end)

        if target_flow do
          effects =
            [
              consume_token: true,
              events:
                null_events ++
                  [
                    event_attrs(ctx, node_id, :gateway_branch_taken, %{
                      "flow_id" => target_flow["id"],
                      "target_node" => target_flow["to"],
                      "expression" => AshBpmn.Feel.print(target_flow["condition"])
                    })
                  ]
            ] ++ follow_flow(graph, target_flow, ctx)

          {:ok, effects}
        else
          {:error,
           "exclusive gateway #{node_id}: no condition matched and no default flow" <>
             null_summary(nulls)}
        end
    end
  end

  # Walks the outgoing flows in order, stopping at the first true condition. Returns the
  # chosen flow (or nil) together with every flow whose condition evaluated to null, so the
  # caller can record them whichever way the gateway resolves.
  defp evaluate_flows(flows, expr_ctx) do
    Enum.reduce_while(flows, {:ok, nil, []}, fn
      %{"condition" => nil}, acc ->
        # An unconditioned flow is the default path, not a condition that failed to answer.
        {:cont, acc}

      flow, {:ok, nil, nulls} ->
        case AshBpmn.Feel.evaluate_condition(flow["condition"], expr_ctx) do
          {:ok, true} -> {:halt, {:ok, flow, nulls}}
          {:ok, false} -> {:cont, {:ok, nil, nulls}}
          {:ok, nil} -> {:cont, {:ok, nil, [flow | nulls]}}
          {:error, reason} -> {:halt, {:error, "flow #{flow["id"]}: #{reason}"}}
        end
    end)
    |> case do
      {:ok, flow, nulls} -> {:ok, flow, Enum.reverse(nulls)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp null_summary([]), do: ""

  defp null_summary(nulls),
    do:
      " (#{length(nulls)} condition(s) evaluated to null: #{Enum.map_join(nulls, ", ", & &1["id"])})"

  # ── parallelGateway ─────────────────────────────────────────────────────

  defp parallel_gateway(graph, node_id, _node, ctx) do
    outgoing = find_outgoing_flows(graph, node_id)
    join_info = graph["joins"][node_id]

    if join_info && length(outgoing) <= 1 do
      # This is a join gateway — all siblings have arrived; advance through
      effects =
        [
          events: [event_attrs(ctx, node_id, :node_entered)]
        ] ++ follow_flows(graph, outgoing, ctx)

      {:ok, effects}
    else
      # Fork gateway — mint multiple tokens with a shared fork_id + advance jobs
      fork_id = Ash.UUID.generate()

      fork_effects =
        Enum.flat_map(outgoing, fn flow ->
          target_node_id = flow["to"]

          [
            {:tokens,
             [
               %{
                 instance_id: ctx[:instance].id,
                 node_id: target_node_id,
                 status: :active,
                 fork_id: fork_id
               }
             ]},
            {:jobs,
             [{AshBpmn.Runtime.AdvanceWorker, build_advance_args(ctx, target_node_id), []}]}
          ]
        end)

      effects =
        [
          consume_token: true,
          events: [event_attrs(ctx, node_id, :node_entered)]
        ] ++ fork_effects

      {:ok, effects}
    end
  end

  # ── Flow helpers ────────────────────────────────────────────────────────

  defp find_outgoing_flows(graph, node_id) do
    graph["flows"]
    |> Enum.filter(fn {_id, flow} -> flow["from"] == node_id end)
    |> Enum.map(fn {id, flow} -> Map.put(flow, "id", id) end)
    |> Enum.sort_by(& &1["id"])
  end

  defp follow_flows(graph, flows, ctx) do
    Enum.flat_map(flows, &follow_flow(graph, &1, ctx))
  end

  defp follow_flow(graph, flow, ctx) do
    target_node_id = flow["to"]
    target_node = graph["nodes"][target_node_id]

    if target_node do
      [
        {:tokens,
         [
           %{
             instance_id: ctx[:instance].id,
             node_id: target_node_id,
             status: :active,
             # Routing travels down the graph with the tokens. A signal promoted by a decision
             # node is read by a gateway further on, and there is nowhere else for it to live:
             # the token is the only thing that exists per-branch.
             routing: current_routing(ctx)
           }
         ]},
        {:jobs, [{AshBpmn.Runtime.AdvanceWorker, build_advance_args(ctx, target_node_id), []}]}
      ]
    else
      []
    end
  end

  defp build_advance_args(ctx, node_id) do
    %{
      "instance_id" => ctx[:instance].id,
      "token_id" => ctx[:token].id,
      "node_id" => node_id
    }
  end

  # ── Timer helpers ────────────────────────────────────────────────────────

  # The worker fills in "task_id" once the task row exists.
  defp timer_jobs(timers) do
    Enum.map(timers, fn timer ->
      minutes = timer["minutes"] || 0
      scheduled_at = DateTime.add(DateTime.utc_now(), minutes, :minute)

      {AshBpmn.Runtime.TimerWorker, %{"kind" => timer["kind"]}, [scheduled_at: scheduled_at]}
    end)
  end

  # ── Expression context ─────────────────────────────────────────────────

  # The context FEEL navigates. Everything is converted through `AshBpmn.Feel.to_feel_value/2`,
  # which turns Ash records into string-keyed maps and -- importantly -- *drops* unloaded and
  # forbidden fields rather than nilling them. A dropped key is a missing path is `null`, which
  # is the honest answer for a value we do not have; and for a field the actor may not read, it
  # is the only safe one, since nilling it would let a hidden value influence routing.
  defp build_expr_ctx(ctx) do
    assigns = AshBpmn.Feel.to_feel_value(ctx[:assigns] || %{})

    %{
      "subject" => AshBpmn.Feel.to_feel_value(ctx[:subject]),
      "task" => Map.get(assigns, "task") || %{},
      # Routing comes off the token, not out of assigns: it is per-branch state that a
      # business rule task promoted onto this token's ancestors, and assigns is per-call.
      "routing" => AshBpmn.Feel.to_feel_value(current_routing(ctx))
    }
    |> Map.merge(assigns)
  end

  # ── Event attrs helper ───────────────────────────────────────────────────

  defp event_attrs(ctx, node_id, kind, extra_data \\ %{}) do
    base = %{
      instance_id: ctx[:instance].id,
      kind: kind,
      node_id: node_id
    }

    base =
      if ctx[:token] do
        Map.put(base, :token_id, ctx[:token].id)
      else
        base
      end

    data = Map.merge(extra_data, ctx[:assigns] || %{})
    Map.put(base, :data, data)
  end
end
