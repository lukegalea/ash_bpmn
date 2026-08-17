# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.Runtime.AdvanceWorker do
  @moduledoc """
  Oban worker that advances a process token to the next node.

  Job args: `%{"instance_id" => id, "token_id" => id, "node_id" => binary}`

  Steps:
    1. Load instance + token; skip unless token is :active
    2. Claim token (optimistic lock); skip on lost race
    3. Dispatch node execution via Interpreter
    4. Apply effects (create tokens, events, enqueue jobs, etc.)
    5. Handle max_attempts exhaustion → mark instance failed
  """

  use Oban.Worker, max_attempts: 10

  require Ash.Query

  alias AshBpmn.Config
  alias AshBpmn.Runtime.{DomainResolver, Interpreter}

  def queue, do: Config.queue()

  @impl true
  def perform(%Oban.Job{args: args, attempt: _attempt} = _job) do
    instance_id = args["instance_id"]
    node_id = args["node_id"]
    task_outcome = args["task_outcome"]

    resources = DomainResolver.resolve!()

    # 1. Load instance and token
    instance =
      resources.instance
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(id == ^instance_id)
      |> Ash.read_one!(authorize?: false)

    # Find the active token at this node. We look by instance+node+status
    # rather than by token_id because the token_id in job args may reference
    # the parent (consumed) token; the actual token to advance is the new one.
    token =
      resources.token
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(instance_id == ^instance_id)
      |> Ash.Query.filter(node_id == ^node_id)
      |> Ash.Query.filter(status == :active)
      |> Ash.read_one!(authorize?: false)

    # Idempotent: skip if token is not active
    if token.status != :active do
      {:ok, :skipped}
    else
      # 2. Claim token
      case claim_token(resources, resources.token, token) do
        {:ok, claimed_token} ->
          # Check max attempts before proceeding
          max = Config.max_attempts()

          if claimed_token.attempts > max do
            mark_instance_failed(resources, instance, node_id, :action_failed)
            {:ok, :failed_permanently}
          else
            # 3. Load graph and dispatch
            definition =
              resources.definition
              |> Ash.Query.for_read(:read)
              |> Ash.Query.filter(id == ^instance.definition_id)
              |> Ash.read_one!(authorize?: false)

            graph = definition.graph

            node = graph["nodes"][node_id]

            if node do
              # Check if this is a parallel join — handle join semantics here
              join_info = graph["joins"][node_id]

              if join_info && node["type"] == "parallelGateway" do
                handle_parallel_join(
                  resources,
                  graph,
                  instance,
                  claimed_token,
                  node_id,
                  join_info
                )
              else
                ctx = build_context(instance, claimed_token, task_outcome)

                case Interpreter.dispatch(graph, node_id, node, ctx) do
                  {:ok, effects} ->
                    apply_effects(resources, effects, ctx)
                    {:ok, :advanced}

                  {:error, reason} ->
                    # Let Oban retry
                    {:error, reason}
                end
              end
            else
              {:error, "node #{node_id} not found in graph"}
            end
          end

        {:error, _} ->
          # Lost the race — another worker won
          {:ok, :lost_race}
      end
    end
  rescue
    e ->
      # Re-raise for Oban retry mechanism
      reraise e, __STACKTRACE__
  end

  # ── Token claim ──────────────────────────────────────────────────────────

  # The :claim action's EnsureActiveInDb change re-reads the row inside the
  # transaction, so a token claimed by a concurrent worker fails here rather
  # than being executed twice.
  defp claim_token(resources, _token_module, token) do
    case resources.token.claim(token, authorize?: false) do
      {:ok, claimed} -> {:ok, claimed}
      {:error, _} -> {:error, :lost_race}
    end
  end

  # ── Parallel join handling ──────────────────────────────────────────────

  defp handle_parallel_join(resources, graph, instance, token, join_node_id, join_info) do
    # The arriving branch's token dies at the join; a single fresh token is
    # minted on the far side once every branch has arrived.
    resources.token.kill!(token, authorize?: false)

    # Record node_entered event
    resources.process_event.create!(
      %{
        instance_id: instance.id,
        token_id: token.id,
        node_id: join_node_id,
        kind: :node_entered,
        data: %{}
      },
      authorize?: false
    )

    # Count how many tokens at this join node have been consumed/dead
    waits_for = join_info["waits_for"] || []

    all_arrived =
      resources.token
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(instance_id == ^instance.id)
      |> Ash.Query.filter(node_id == ^join_node_id)
      |> Ash.Query.filter(status in [:consumed, :dead])
      |> Ash.read!(authorize?: false)
      |> length()

    if all_arrived >= length(waits_for) do
      # All siblings arrived — advance through the join
      advance_from_join(resources, graph, instance, join_node_id)
    else
      # Not all siblings have arrived yet — check if remaining siblings
      # will ever arrive (i.e., are there active tokens on their source nodes?)
      incoming_nodes =
        graph["flows"]
        |> Map.values()
        |> Enum.filter(fn f -> f["to"] == join_node_id end)
        |> Enum.map(fn f -> f["from"] end)
        |> Enum.reject(fn from -> from == token.node_id end)

      has_active_siblings =
        Enum.any?(incoming_nodes, fn from_node ->
          resources.token
          |> Ash.Query.for_read(:read)
          |> Ash.Query.filter(instance_id == ^instance.id)
          |> Ash.Query.filter(node_id == ^from_node)
          |> Ash.Query.filter(status in [:active, :executing])
          |> Ash.read_one!(authorize?: false)
        end)

      if has_active_siblings do
        {:ok, :waiting_for_siblings}
      else
        # Remaining siblings will never arrive (exclusive gateway chose
        # a different path) — advance through the join now.
        advance_from_join(resources, graph, instance, join_node_id)
      end
    end
  end

  defp advance_from_join(resources, graph, instance, join_node_id) do
    outgoing =
      graph["flows"]
      |> Map.values()
      |> Enum.filter(fn flow -> flow["from"] == join_node_id end)

    case outgoing do
      [flow | _] ->
        next_node_id = flow["to"]

        # Claim immediately: the node past the join is dispatched inline here,
        # and its effects (consume, park) act on an executing token.
        new_token =
          resources.token.create!(
            %{
              instance_id: instance.id,
              node_id: next_node_id,
              status: :active
            },
            authorize?: false
          )
          |> resources.token.claim!(authorize?: false)

        ctx = build_context(instance, new_token)

        node = graph["nodes"][next_node_id]

        if node do
          case Interpreter.dispatch(graph, next_node_id, node, ctx) do
            {:ok, effects} ->
              apply_effects(resources, effects, ctx)
              {:ok, :joined_and_advanced}

            {:error, reason} ->
              {:error, reason}
          end
        else
          {:ok, :joined}
        end

      [] ->
        {:ok, :joined_no_outgoing}
    end
  end

  # ── Context building ───────────────────────────────────────────────────

  defp build_context(instance, token, task_outcome \\ nil) do
    subject = load_subject(instance)

    assigns =
      if task_outcome do
        %{"task" => %{"outcome" => task_outcome}}
      else
        %{}
      end

    %{
      instance: instance,
      token: token,
      subject: subject,
      assigns: assigns
    }
  end

  defp load_subject(instance) do
    if instance.subject_type && instance.subject_id do
      try do
        # subject_type already includes "Elixir." prefix from to_string/1
        mod = String.to_atom(instance.subject_type)

        mod
        |> Ash.Query.for_read(:read)
        |> Ash.Query.filter(id == ^instance.subject_id)
        |> Ash.read_one!(authorize?: false)
      rescue
        _ -> nil
      end
    else
      nil
    end
  end

  # ── Effect application ───────────────────────────────────────────────────

  defp apply_effects(resources, effects, ctx) do
    # Phase 1: create tokens and tasks first, so later effects can reference
    # the ids the data layer assigned them.
    new_token_map =
      effects
      |> Enum.flat_map(fn
        {:tokens, token_attrs_list} ->
          Enum.map(token_attrs_list, fn attrs ->
            token = resources.token.create!(attrs, authorize?: false)
            {attrs[:node_id], token.id}
          end)

        _ ->
          []
      end)
      |> Map.new()

    task_id_map =
      effects
      |> Enum.flat_map(fn
        {:tasks, task_specs} ->
          Enum.map(task_specs, fn {task_ref, attrs} ->
            task = resources.human_task.create!(attrs, authorize?: false)
            {task_ref, task.id}
          end)

        _ ->
          []
      end)
      |> Map.new()

    # Phase 2: Apply remaining effects
    Enum.each(effects, fn
      {:consume_token, true} ->
        resources.token.consume!(ctx[:token], authorize?: false)

      {:park_token, true} ->
        :ok

      {:tokens, _token_attrs_list} ->
        # Already handled in phase 1
        :ok

      {:events, event_attrs_list} ->
        Enum.each(event_attrs_list, fn attrs ->
          resources.process_event.create!(attrs, authorize?: false)
        end)

      {:jobs, job_list} ->
        Enum.each(job_list, fn {worker, args, opts} ->
          # If this is an advance job, patch token_id to the new token
          args =
            if node_id = args["node_id"] do
              case Map.get(new_token_map, node_id) do
                nil -> args
                new_id -> Map.put(args, "token_id", new_id)
              end
            else
              args
            end

          AshBpmn.Runtime.Oban.insert(worker, args, opts)
        end)

      {:complete_instance, outcome} ->
        resources.instance.mark_completed!(ctx[:instance], outcome, authorize?: false)
        record_event(resources, ctx, :instance_completed, %{"outcome" => outcome})

      {:tasks, _task_specs} ->
        # Already handled in phase 1
        :ok

      {:candidates, {task_ref, candidate_attrs_list}} ->
        task_id = Map.fetch!(task_id_map, task_ref)

        Enum.each(candidate_attrs_list, fn attrs ->
          resources.task_candidate.create!(
            Map.put(attrs, :task_id, task_id),
            authorize?: false
          )
        end)

      {:timers, {task_ref, timer_specs}} ->
        attach_timers(resources, Map.fetch!(task_id_map, task_ref), timer_specs)
    end)
  end

  # Enqueues a task's timers and records the resulting job ids on the task, so
  # completing the task early can cancel them. Without the ids on the row there
  # is nothing to cancel and a decided task still fires its escalation.
  defp attach_timers(_resources, _task_id, []), do: :ok

  defp attach_timers(resources, task_id, timer_specs) do
    job_ids =
      Enum.map(timer_specs, fn {worker, args, opts} ->
        {:ok, job} =
          AshBpmn.Runtime.Oban.insert(worker, Map.put(args, "task_id", task_id), opts)

        job.id
      end)

    task =
      resources.human_task
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(id == ^task_id)
      |> Ash.read_one!(authorize?: false)

    resources.human_task.attach_timers!(task, job_ids, authorize?: false)

    :ok
  end

  # ── Instance failure ─────────────────────────────────────────────────────

  defp mark_instance_failed(resources, instance, node_id, kind) do
    resources.instance.mark_failed!(instance, authorize?: false)

    resources.process_event.create!(
      %{
        instance_id: instance.id,
        kind: kind,
        node_id: node_id,
        data: %{"reason" => "max_attempts_exceeded"}
      },
      authorize?: false
    )
  end

  defp record_event(resources, ctx, kind, extra) do
    attrs = %{
      instance_id: ctx[:instance].id,
      kind: kind,
      data: Map.merge(extra, ctx[:assigns] || %{})
    }

    attrs =
      if ctx[:token] do
        Map.put(attrs, :token_id, ctx[:token].id)
      else
        attrs
      end

    resources.process_event.create!(attrs, authorize?: false)
  end
end
