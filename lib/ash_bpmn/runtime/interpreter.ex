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

    # Evaluate conditions in order; first true wins
    expr_ctx = build_expr_ctx(ctx)

    chosen_flow =
      Enum.find(outgoing, fn flow ->
        condition = flow["condition"]

        if condition do
          {:ok, result} = AshBpmn.Expr.eval(condition, expr_ctx)
          result
        else
          false
        end
      end)

    target_flow = chosen_flow || Enum.find(outgoing, &(&1["id"] == default_flow))

    if target_flow do
      effects =
        [
          consume_token: true,
          events: [
            event_attrs(ctx, node_id, :gateway_branch_taken, %{
              "flow_id" => target_flow["id"],
              "target_node" => target_flow["to"]
            })
          ]
        ] ++ follow_flow(graph, target_flow, ctx)

      {:ok, effects}
    else
      {:error, "exclusive gateway #{node_id}: no condition matched and no default flow"}
    end
  end

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
             status: :active
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

  defp build_expr_ctx(ctx) do
    subject = ctx[:subject]

    # Reload subject fresh from data if possible
    subject =
      case subject do
        nil -> nil
        _ -> subject
      end

    %{
      "subject" => subject,
      "task" => ctx[:assigns]["task"] || %{}
    }
    |> Map.merge(ctx[:assigns] || %{})
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
