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
  alias AshBpmn.Scope

  def queue, do: Config.queue()

  @impl true
  def perform(%Oban.Job{args: args, attempt: _attempt} = _job) do
    instance_id = args["instance_id"]
    node_id = args["node_id"]
    task_outcome = args["task_outcome"]

    scope = Scope.from_job(args, :advance)
    resources = DomainResolver.resolve!(scope.domain)

    # Nobody is waiting on this: the request that enqueued the job returned long
    # ago. The tenant and the domain travelled in the args because there is
    # nothing else left to read them from, and the actor is a named system actor
    # rather than nil so the trail says "the advance worker did this" instead of
    # saying nothing.

    # 1. Load instance and token
    instance =
      resources.instance
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(id == ^instance_id)
      |> Ash.read_one!(Scope.engine(scope))

    # Find the active token at this node. We look by instance+node+status
    # rather than by token_id because the token_id in job args may reference
    # the parent (consumed) token; the actual token to advance is the new one.
    token =
      resources.token
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(instance_id == ^instance_id)
      |> Ash.Query.filter(node_id == ^node_id)
      |> Ash.Query.filter(status == :active)
      |> Ash.read_one!(Scope.engine(scope))

    # Idempotent: skip if token is not active
    if token.status != :active do
      {:ok, :skipped}
    else
      # 2. Claim token
      case claim_token(resources, resources.token, token, scope) do
        {:ok, claimed_token} ->
          # Check max attempts before proceeding
          max = Config.max_attempts()

          if claimed_token.attempts > max do
            mark_instance_failed(resources, instance, node_id, :action_failed, scope)
            {:ok, :failed_permanently}
          else
            # 3. Load graph and dispatch
            # Through the loader seam, not directly: an instance's definition does not
            # necessarily live in the instance's tenant. See `AshBpmn.DefinitionLoader`.
            definition =
              AshBpmn.DefinitionLoader.load!(
                resources.definition,
                instance.definition_id,
                instance,
                scope
              )

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
                  join_info,
                  scope
                )
              else
                ctx = build_context(instance, claimed_token, scope, task_outcome, node["load"])

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
  defp claim_token(resources, _token_module, token, scope) do
    case resources.token.claim(token, Scope.engine(scope)) do
      {:ok, claimed} -> {:ok, claimed}
      {:error, _} -> {:error, :lost_race}
    end
  end

  # ── Parallel join handling ──────────────────────────────────────────────

  defp handle_parallel_join(resources, graph, instance, token, join_node_id, join_info, scope) do
    # The arriving branch's token dies at the join; a single fresh token is
    # minted on the far side once every branch has arrived.
    resources.token.kill!(token, Scope.engine(scope))

    # Record node_entered event
    resources.process_event.create!(
      %{
        instance_id: instance.id,
        token_id: token.id,
        node_id: join_node_id,
        kind: :node_entered,
        data: %{}
      },
      Scope.engine(scope)
    )

    # Count how many tokens at this join node have been consumed/dead
    waits_for = join_info["waits_for"] || []

    all_arrived =
      resources.token
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(instance_id == ^instance.id)
      |> Ash.Query.filter(node_id == ^join_node_id)
      |> Ash.Query.filter(status in [:consumed, :dead])
      |> Ash.read!(Scope.engine(scope))
      |> length()

    if all_arrived >= length(waits_for) do
      # All siblings arrived — advance through the join
      advance_from_join(resources, graph, instance, join_node_id, scope)
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
          |> Ash.read_one!(Scope.engine(scope))
        end)

      if has_active_siblings do
        {:ok, :waiting_for_siblings}
      else
        # Remaining siblings will never arrive (exclusive gateway chose
        # a different path) — advance through the join now.
        advance_from_join(resources, graph, instance, join_node_id, scope)
      end
    end
  end

  defp advance_from_join(resources, graph, instance, join_node_id, scope) do
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
            Scope.engine(scope)
          )
          |> resources.token.claim!(Scope.engine(scope))

        ctx = build_context(instance, new_token, scope)

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

  defp build_context(instance, token, scope, task_outcome \\ nil, load \\ []) do
    subject = load_subject(instance, scope, load)

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
      assigns: assigns,
      scope: scope,
      # The tenant travelled in the job args and the instance also knows its own;
      # either way anything the ctx hands to a resolver or invoker must see it.
      tenant: scope.tenant || Map.get(instance, :organization_id),
      # A job has nobody behind it: the scope carries the named system actor the
      # engine acts as, and nothing else. Read it off the scope so the ctx can
      # never promise an actor the job does not have.
      actor: Map.get(scope, :actor)
    }
  end

  defp load_subject(instance, scope, load),
    do: AshBpmn.Subject.load(instance, scope, load || [])

  # ── Effect application ───────────────────────────────────────────────────

  defp apply_effects(resources, effects, ctx) do
    scope = ctx[:scope]

    # Phase 1: create tokens and tasks first, so later effects can reference
    # the ids the data layer assigned them.
    new_token_map =
      effects
      |> Enum.flat_map(fn
        {:tokens, token_attrs_list} ->
          Enum.map(token_attrs_list, fn attrs ->
            token = resources.token.create!(attrs, Scope.engine(scope))
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
            task = resources.human_task.create!(attrs, Scope.engine(scope))
            {task_ref, task.id}
          end)

        _ ->
          []
      end)
      |> Map.new()

    # Phase 2: Apply remaining effects
    Enum.each(effects, fn
      {:consume_token, true} ->
        resources.token.consume!(ctx[:token], Scope.engine(scope))

      {:park_token, attrs} when is_map(attrs) ->
        # Was a no-op, which left the token `:executing` -- indistinguishable from a token
        # whose job is running or lost, and therefore invisible to any recovery that tells
        # those apart.
        resources.token.park!(ctx[:token], attrs, Scope.engine(scope))

      {:tokens, _token_attrs_list} ->
        # Already handled in phase 1
        :ok

      {:events, event_attrs_list} ->
        Enum.each(event_attrs_list, fn attrs ->
          resources.process_event.create!(attrs, Scope.engine(scope))
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

          insert_job(resources, worker, args, opts, scope)
        end)

      {:error_instance, {outcome, error}} ->
        killed = kill_live_tokens(resources, ctx, scope)

        record_event(resources, ctx, :instance_errored, %{
          "outcome" => outcome,
          "error_ref" => error["ref"],
          "error_code" => error["code"],
          "error_name" => error["name"],
          "errored_by_node_id" => ctx[:token] && ctx[:token].node_id,
          "tokens_killed" => length(killed),
          "killed_node_ids" => Enum.map(killed, & &1.node_id)
        })

        resources.instance.mark_errored!(
          ctx[:instance],
          %{outcome: to_outcome(outcome)},
          Scope.engine(scope)
        )

      {:terminate_instance, outcome} ->
        killed = kill_live_tokens(resources, ctx, scope)

        # One event, not one per token. The question this row answers is "why did that branch
        # stop?", and it is answered by naming the node that terminated and how many branches
        # it took down -- the tokens themselves already carry `:dead`.
        record_event(resources, ctx, :instance_terminated, %{
          "outcome" => outcome,
          "terminated_by_node_id" => ctx[:token] && ctx[:token].node_id,
          "tokens_killed" => length(killed),
          "killed_token_ids" => Enum.map(killed, & &1.id),
          "killed_node_ids" => Enum.map(killed, & &1.node_id)
        })

        resources.instance.mark_completed!(
          ctx[:instance],
          to_outcome(outcome),
          Scope.engine(scope)
        )

        record_event(resources, ctx, :instance_completed, %{"outcome" => outcome})

      {:complete_instance, outcome} ->
        resources.instance.mark_completed!(
          ctx[:instance],
          to_outcome(outcome),
          Scope.engine(scope)
        )

        record_event(resources, ctx, :instance_completed, %{"outcome" => outcome})

      {:tasks, _task_specs} ->
        # Already handled in phase 1
        :ok

      {:candidates, {task_ref, candidate_attrs_list}} ->
        task_id = Map.fetch!(task_id_map, task_ref)

        Enum.each(candidate_attrs_list, fn attrs ->
          resources.task_candidate.create!(
            Map.put(attrs, :task_id, task_id),
            Scope.engine(scope)
          )
        end)

      {:timers, {task_ref, timer_specs}} ->
        attach_timers(resources, Map.fetch!(task_id_map, task_ref), timer_specs, ctx, scope)
    end)
  end

  # Enqueues a task's timers and records the resulting job ids on the task, so
  # completing the task early can cancel them. Without the ids on the row there
  # is nothing to cancel and a decided task still fires its escalation.
  defp attach_timers(_resources, _task_id, [], _ctx, _scope), do: :ok

  defp attach_timers(resources, task_id, timer_specs, ctx, scope) do
    job_ids =
      Enum.map(timer_specs, fn {worker, args, opts} ->
        # The ledger row is written BEFORE the Oban insert, and the job id attached after.
        # A crash between the two then leaves a row saying a timer was meant to exist, which
        # is evidence; the other order leaves a scheduled job nothing knows about, which is a
        # ghost.
        row =
          ledger_row(resources, scope, %{
            instance_id: ctx[:instance] && ctx[:instance].id,
            token_id: ctx[:token] && ctx[:token].id,
            task_id: task_id,
            node_id: ctx[:token] && ctx[:token].node_id,
            kind: timer_kind(args["kind"]),
            due_at: Keyword.get(opts, :scheduled_at)
          })

        {:ok, job} =
          AshBpmn.Runtime.Oban.insert(
            worker,
            Scope.to_job_args(scope, Map.put(args, "task_id", task_id)),
            opts
          )

        row && resources.timer_job.attach_job!(row, job.id, Scope.engine(scope))

        job.id
      end)

    task =
      resources.human_task
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(id == ^task_id)
      |> Ash.read_one!(Scope.engine(scope))

    resources.human_task.attach_timers!(task, job_ids, Scope.engine(scope))

    :ok
  end

  # A catch timer earns a ledger row; an ordinary advance job does not. This clause is
  # generic over every job the interpreter emits, so the gate is the worker module rather
  # than a flag threaded through the effect.
  defp insert_job(resources, AshBpmn.Runtime.CatchTimerWorker = worker, args, opts, scope) do
    row =
      ledger_row(resources, scope, %{
        instance_id: args["instance_id"],
        token_id: args["token_id"],
        node_id: args["node_id"],
        kind: :catch,
        due_at: Keyword.get(opts, :scheduled_at)
      })

    {:ok, job} = AshBpmn.Runtime.Oban.insert(worker, Scope.to_job_args(scope, args), opts)
    row && resources.timer_job.attach_job!(row, job.id, Scope.engine(scope))
    :ok
  end

  defp insert_job(_resources, worker, args, opts, scope) do
    AshBpmn.Runtime.Oban.insert(worker, Scope.to_job_args(scope, args), opts)
    :ok
  end

  # `nil` when the host has not installed the ledger, which is a supported configuration --
  # the kind is optional exactly like the trigger kinds. Every caller must therefore treat
  # `nil` as "not installed" rather than as a failure.
  defp ledger_row(resources, scope, attrs) do
    if resources.timer_job && attrs.kind do
      resources.timer_job.create!(attrs, Scope.engine(scope))
    end
  end

  # Mapped explicitly rather than through `String.to_existing_atom/1`. The kind arrives from
  # the diagram, and an unrecognized one must not take the whole advance down over a
  # bookkeeping row -- it loses its ledger entry and the timer still arms.
  defp timer_kind("remind"), do: :remind
  defp timer_kind("escalate"), do: :escalate
  defp timer_kind("expire"), do: :expire
  defp timer_kind(_), do: nil

  # ── Instance failure ─────────────────────────────────────────────────────

  defp mark_instance_failed(resources, instance, node_id, kind, scope) do
    resources.instance.mark_failed!(instance, Scope.engine(scope))

    resources.process_event.create!(
      %{
        instance_id: instance.id,
        kind: kind,
        node_id: node_id,
        data: %{"reason" => "max_attempts_exceeded"}
      },
      Scope.engine(scope)
    )
  end

  # Every live branch of the instance except the one that just terminated it.
  #
  # `:waiting` is in the list and is the case that makes this work at all: a branch parked on
  # an approval has no job to cancel and no worker to interrupt, so terminating without killing
  # it would leave a token that waits forever on an instance that has already completed --
  # which is precisely the shape a terminate end event exists to prevent.
  #
  # The current token is excluded because the interpreter already consumed it, and consumed is
  # not dead: it finished, it did not get cut off.
  defp kill_live_tokens(resources, ctx, scope) do
    current_id = ctx[:token] && ctx[:token].id
    instance_id = ctx[:instance].id

    resources.token
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(instance_id == ^instance_id and status in [:active, :executing, :waiting])
    |> Ash.read!(Scope.engine(scope))
    |> Enum.reject(&(&1.id == current_id))
    |> Enum.map(fn token ->
      resources.token.kill!(token, Scope.engine(scope))
      token
    end)
  end

  # Outcomes reach here as a string from the diagram or as an atom from a host completing a
  # task. Both are legal inputs and both are stored as text.
  defp to_outcome(nil), do: nil
  defp to_outcome(outcome) when is_binary(outcome), do: outcome
  defp to_outcome(outcome) when is_atom(outcome), do: Atom.to_string(outcome)

  defp record_event(resources, ctx, kind, extra) do
    scope = ctx[:scope]

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

    resources.process_event.create!(attrs, Scope.engine(scope))
  end
end
