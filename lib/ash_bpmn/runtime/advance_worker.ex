# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.Runtime.AdvanceWorker do
  @moduledoc """
  Oban worker that advances a process token to the next node.

  Job args: `%{"instance_id" => id, "token_id" => id, "node_id" => binary}`

  Steps:
    1. Load instance + token. No live token is a redelivery: skip.
    2. Claim token (optimistic lock); skip on lost race
    3. Dispatch node execution via Interpreter
    4. Apply effects (create tokens, events, enqueue jobs, etc.)
    5. On a node failure, hand the claim back so Oban's retry can take it again -- or, once
       the attempts are spent, kill the token and mark the instance `:failed`
    6. A retry that finds its token still `:executing` is resuming after a crash: it takes the
       claim back once it is older than `AshBpmn.Config.claim_timeout/0`, and snoozes until then
  """

  use Oban.Worker, max_attempts: 10

  require Ash.Query

  alias AshBpmn.Config
  alias AshBpmn.FlightView
  alias AshBpmn.Runtime.{DomainResolver, Interpreter}
  alias AshBpmn.Scope

  def queue, do: Config.queue()

  @impl true
  def perform(%Oban.Job{args: args} = job) do
    instance_id = args["instance_id"]
    node_id = args["node_id"]

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

    # The token to advance, by id when the id names a live one and by position otherwise.
    #
    # This used to look by instance+node+status only, on the stated grounds that the
    # `token_id` in job args may name the parent that was just consumed. That was true of
    # every job the engine emitted, because a node held one token -- and it stopped being true
    # with multi-instance, where N tokens sit at the same node and a position lookup finds all
    # of them and raises. Preferring the id when it resolves keeps the old behaviour exactly
    # where it was right and makes a fan-out addressable.
    #
    # Nil is an ordinary answer, not an error: the token moved on, or was killed, or the job is
    # a redelivery of one that already ran. It used to fall through to `token.status` and crash
    # every retry of a job whose node had failed, which is how a failed service task wedged its
    # instance `:running` forever.
    case instance && resolve_token(resources, args["token_id"], instance_id, node_id, scope) do
      %{status: :active} = token ->
        claim_and_run(resources, job, instance, token, scope)

      %{status: :executing} = token ->
        resume_executing(resources, job, instance, token, scope)

      _ ->
        {:ok, :skipped}
    end
  end

  # ── Claim and run ─────────────────────────────────────────────────────────

  defp claim_and_run(resources, job, instance, token, scope) do
    # 2. Claim token
    case claim_token(resources, resources.token, token, scope) do
      {:ok, claimed_token} ->
        # The claim is movement too — a token visibly "in progress" between
        # arriving at a node and finishing there.
        FlightView.token_moved(instance, claimed_token)

        # The budget is spent before this attempt starts -- a re-claim after a crash
        # increments it without a failure having been handled. Same ending as a failure on
        # the last attempt.
        if claimed_token.attempts > Config.max_attempts() do
          mark_instance_failed(
            resources,
            instance,
            claimed_token,
            claimed_token.node_id,
            "attempts exhausted before the node ran",
            scope
          )

          {:ok, :failed_permanently}
        else
          run_node(resources, job, instance, claimed_token, scope)
        end

      {:error, _} ->
        # Lost the race — another worker won
        {:ok, :lost_race}
    end
  end

  defp run_node(resources, job, instance, token, scope) do
    node_id = token.node_id

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
    # Check if this is a parallel join — handle join semantics here
    join_info = graph["joins"][node_id]

    cond do
      is_nil(node) ->
        node_failed(
          resources,
          job,
          instance,
          token,
          {:error, "node #{node_id} not found in graph"},
          scope
        )

      join_info && node["type"] == "parallelGateway" ->
        handle_parallel_join(resources, graph, instance, token, node_id, join_info, scope)

      true ->
        ctx =
          build_context(instance, token, scope, job.args["task_outcome"], node["load"])

        case dispatch(graph, node_id, node, ctx) do
          {:ok, effects} ->
            apply_effects(resources, effects, ctx)
            {:ok, :advanced}

          failure ->
            node_failed(resources, job, instance, token, failure, scope)
        end
    end
  end

  # The node's own failure, told apart from a failure applying its effects. Dispatch is the
  # interpreter deciding what to do -- the host action a service task calls runs here -- and it
  # writes nothing of the engine's, so a failure inside it leaves the token exactly as claimed
  # and safe to hand back. A failure in `apply_effects/3` may have written half the node's
  # effects, and is left to propagate: that is the crash case, recovered by
  # `resume_executing/5` once the claim is stale.
  defp dispatch(graph, node_id, node, ctx) do
    Interpreter.dispatch(graph, node_id, node, ctx)
  rescue
    e -> {:raised, e, __STACKTRACE__}
  end

  # 5. A node failed: hand the claim back for Oban's retry, or -- on the last attempt the
  # engine or Oban will make -- give up the way the docs say: the token dead, the instance
  # `:failed`, an `:action_failed` event naming the node and the error.
  #
  # Re-read rather than trusted, because the node may have run for a while: a cancel that
  # killed the token meanwhile wins, and the failure is only passed on.
  defp node_failed(resources, job, instance, token, failure, scope) do
    current = reload_token(resources, token, scope)

    cond do
      is_nil(current) or current.status != :executing ->
        pass_on(failure)

      exhausted?(current, job) ->
        mark_instance_failed(
          resources,
          instance,
          current,
          current.node_id,
          describe_failure(failure),
          scope
        )

        {:ok, :failed_permanently}

      true ->
        released = resources.token.release!(current, Scope.engine(scope))
        FlightView.token_moved(instance, released)
        pass_on(failure)
    end
  end

  # The engine's budget (`Config.max_attempts/0`, counted on the token by every claim) or
  # Oban's (the job's own `max_attempts`), whichever runs out first. Oban's matters as much as
  # the engine's: a job Oban discards with the token handed back leaves an `:active` token
  # nothing will ever run.
  defp exhausted?(token, %Oban.Job{attempt: attempt, max_attempts: max_attempts}) do
    token.attempts >= Config.max_attempts() or
      (is_integer(attempt) and is_integer(max_attempts) and attempt >= max_attempts)
  end

  defp pass_on({:error, reason}), do: {:error, reason}
  defp pass_on({:raised, e, stacktrace}), do: reraise(e, stacktrace)

  defp describe_failure({:error, reason}) when is_binary(reason), do: reason
  defp describe_failure({:error, reason}), do: inspect(reason)
  defp describe_failure({:raised, e, _stacktrace}), do: Exception.message(e)

  # 6. A retry finding its token still `:executing`: the job that held the claim died
  # mid-node, so nothing will ever hand it back.
  #
  # Only a retry (`attempt > 1`) may take it, because only a retry can be the job that left
  # it. A first attempt finding the token `:executing` is a duplicate of a job that is running
  # right now, and taking the claim from it would run the node twice. Even a retry waits until
  # the claim is older than `Config.claim_timeout/0`, which is what keeps a duplicate that
  # happens to be a retry from cutting into a long node that is still running.
  defp resume_executing(resources, %Oban.Job{attempt: attempt} = job, instance, token, scope)
       when is_integer(attempt) and attempt > 1 do
    remaining = Config.claim_timeout() - claim_age(token)

    if remaining > 0 do
      {:snooze, remaining}
    else
      case resources.token.release(token, Scope.engine(scope)) do
        {:ok, released} -> claim_and_run(resources, job, instance, released, scope)
        {:error, _} -> {:ok, :lost_race}
      end
    end
  end

  defp resume_executing(_resources, _job, _instance, _token, _scope), do: {:ok, :skipped}

  # Seconds since the claim. `updated_at` is the claim's timestamp because the claim is the
  # last write a token in `:executing` receives.
  defp claim_age(%{updated_at: %DateTime{} = at}),
    do: DateTime.diff(DateTime.utc_now(), at, :second)

  defp claim_age(%{updated_at: %NaiveDateTime{} = at}),
    do: NaiveDateTime.diff(NaiveDateTime.utc_now(), at, :second)

  defp reload_token(resources, token, scope) do
    resources.token
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^token.id)
    |> Ash.read_one!(Scope.engine(scope))
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
    killed = resources.token.kill!(token, Scope.engine(scope))
    FlightView.token_moved(instance, killed)

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

        FlightView.token_moved(instance, new_token)

        ctx = build_context(instance, new_token, scope)

        node = graph["nodes"][next_node_id]

        if node do
          case dispatch(graph, next_node_id, node, ctx) do
            {:ok, effects} ->
              apply_effects(resources, effects, ctx)
              {:ok, :joined_and_advanced}

            failure ->
              hand_off_after_join(resources, instance, new_token, failure, scope)
          end
        else
          {:ok, :joined}
        end

      [] ->
        {:ok, :joined_no_outgoing}
    end
  end

  # `:executing` is admitted by id and only by id. By id it is this job's own token, left
  # mid-flight by an earlier attempt that died, and `resume_executing/5` decides whether it may
  # be taken back. By position it could be any token at the node, held by any job.
  # The node past a join failed inline, in a job that belongs to the arriving branch -- whose
  # token the join has already killed. A retry of *this* job would find that token dead and
  # skip, so the new token would sit `:executing` with nothing coming for it. It is handed
  # back and given a job of its own instead, which then retries and fails the instance exactly
  # as any other node does. The join itself is done, so this job succeeds.
  defp hand_off_after_join(resources, instance, token, failure, scope) do
    case resources.token.release(token, Scope.engine(scope)) do
      {:ok, released} ->
        FlightView.token_moved(instance, released)

        AshBpmn.Runtime.Oban.insert(
          __MODULE__,
          Scope.to_job_args(scope, %{
            "instance_id" => instance.id,
            "token_id" => released.id,
            "node_id" => released.node_id
          })
        )

        {:ok, :joined}

      {:error, _} ->
        pass_on(failure)
    end
  end

  defp resolve_token(resources, token_id, instance_id, node_id, scope) do
    by_id =
      token_id &&
        resources.token
        |> Ash.Query.for_read(:read)
        |> Ash.Query.filter(
          id == ^token_id and status in [:active, :executing] and node_id == ^node_id
        )
        |> Ash.read_one!(Scope.engine(scope))

    by_id ||
      resources.token
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(
        instance_id == ^instance_id and node_id == ^node_id and status == :active
      )
      |> Ash.read!(Scope.engine(scope))
      |> case do
        [token] ->
          token

        [] ->
          nil

        many ->
          # Several live tokens at one node and nothing in the job naming which. That is a
          # fan-out whose job lost its id, and guessing would advance an arbitrary instance
          # twice while leaving another untouched.
          raise "#{length(many)} active tokens at #{node_id} and no token_id in the job args"
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
            FlightView.token_moved(ctx[:instance], token)
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
        consumed = resources.token.consume!(ctx[:token], Scope.engine(scope))
        FlightView.token_moved(ctx[:instance], consumed)

      {:park_token, attrs} when is_map(attrs) ->
        # Was a no-op, which left the token `:executing` -- indistinguishable from a token
        # whose job is running or lost, and therefore invisible to any recovery that tells
        # those apart.
        parked = resources.token.park!(ctx[:token], attrs, Scope.engine(scope))
        FlightView.token_moved(ctx[:instance], parked)

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

      {:emit_signal, %{name: name} = spec} ->
        # Through the facade, so a throw and a host call take the same path -- including the
        # depth inheritance, which is what stops a signal that starts a process that throws a
        # signal going round forever.
        case AshBpmn.emit_signal(name,
               instance: ctx[:instance],
               node_id: spec.node_id,
               actor: Map.get(scope, :actor),
               tenant: Map.get(scope, :tenant)
             ) do
          {:ok, _signal} ->
            :ok

          {:error, :signals_not_installed} ->
            # A published diagram throws a signal and the host has no signal resource. The
            # process is not wrong and neither is the host -- they disagree about what is
            # installed -- so the throw is recorded as having gone nowhere rather than
            # failing an instance that would fail again on every retry.
            record_event(resources, ctx, :signal_not_delivered, %{
              "signal_name" => name,
              "reason" => "signals_not_installed"
            })

          {:error, reason} ->
            raise "signal throw #{spec.node_id} failed: #{inspect(reason)}"
        end

      {:start_child, spec} ->
        start_child_instance(resources, ctx, spec, scope)

      {:multi_instance_fan, token_attrs} ->
        # Created and enqueued together, so each job names the token it is for. Everything
        # else in this module can key a job by node id because a node holds one token; a
        # fan-out is the one place that is not true.
        # Every token first, then every job. The two loops are not interchangeable: the join
        # asks whether any siblings are still live, so an instance that starts before its
        # siblings exist sees none, joins immediately, and carries the branch on while the
        # rest of the fan-out is still being created. Inline mode makes that certain by
        # running each job as it is inserted; in production it is a crash window rather than a
        # certainty, which is worse to debug.
        tokens =
          Enum.map(token_attrs, fn attrs ->
            {attrs, resources.token.create!(attrs, Scope.engine(scope))}
          end)

        Enum.each(tokens, fn {attrs, token} ->
          FlightView.token_moved(ctx[:instance], token)

          AshBpmn.Runtime.Oban.insert(
            AshBpmn.Runtime.AdvanceWorker,
            Scope.to_job_args(scope, %{
              "instance_id" => attrs.instance_id,
              "token_id" => token.id,
              "node_id" => attrs.node_id
            })
          )
        end)

      {:multi_instance_join, spec} ->
        # The current token is consumed by an earlier effect in this same list, so "are any
        # siblings left?" is the whole question -- the same shape as deciding whether an end
        # event finishes the instance or just its branch.
        siblings =
          resources.token
          |> Ash.Query.for_read(:read)
          |> Ash.Query.filter(
            instance_id == ^ctx[:instance].id and fork_id == ^spec.fork_id and
              status in [:active, :executing, :waiting]
          )
          |> Ash.read!(Scope.engine(scope))

        if siblings == [] do
          record_event(resources, ctx, :node_completed, %{"multi_instance" => "joined"})
          Enum.each(spec.targets, &continue_from_join(resources, ctx, &1, spec.as, scope))
        else
          record_event(resources, ctx, :branch_completed, %{
            "multi_instance" => "instance",
            "instances_remaining" => length(siblings)
          })
        end

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
        complete_when_last(resources, ctx, outcome, scope)

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

  # The engine giving up, which the token lifecycle spells `:dead` and the instance `:failed`.
  # The token is killed rather than left `:executing` because `:executing` means "a job is
  # running this", and nothing is; `AshBpmn.retry_instance/2` finds it by the `token_id` on
  # the event and brings it back.
  #
  # The instance is re-read because the node may have run for a long time: a cancel that
  # landed meanwhile has already ended it, and `mark_failed` would refuse a non-running one.
  defp mark_instance_failed(resources, instance, token, node_id, error, scope) do
    killed = resources.token.kill!(token, Scope.engine(scope))
    FlightView.token_moved(instance, killed)

    current =
      resources.instance
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(id == ^instance.id)
      |> Ash.read_one!(Scope.engine(scope))

    if current && current.status == :running do
      resources.instance.mark_failed!(current, Scope.engine(scope))
    end

    resources.process_event.create!(
      %{
        instance_id: instance.id,
        token_id: token.id,
        kind: :action_failed,
        node_id: node_id,
        data: %{
          "reason" => "max_attempts_exceeded",
          "attempts" => token.attempts,
          # Bounded: the event is the engine's diagnostic, not a copy of the host's error log.
          "error" => String.slice(error, 0, 500)
        }
      },
      Scope.engine(scope)
    )
  end

  # A child that has finished wakes the token its parent left waiting.
  #
  # Direct, by the id the child was started with, rather than through the correlator. There is
  # nothing to correlate: the parent knows which child it started and the child records which
  # token is waiting. Routing the return through the sweep would add a delay and a delivery
  # guarantee to a reference that cannot be wrong.
  #
  # Nothing happens for an instance with no parent, which is nearly all of them.
  defp wake_parent(_resources, %{parent_token_id: nil}, _outcome, _scope), do: :ok

  defp wake_parent(resources, instance, outcome, scope) do
    parent_scope = Scope.from_record(instance, actor: Map.get(scope, :actor))

    token =
      resources.token
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(id == ^instance.parent_token_id)
      |> Ash.read_one!(Scope.engine(parent_scope))

    with false <- is_nil(token),
         {:ok, token} <- resources.token.claim_waiting(token, Scope.engine(parent_scope)) do
      parent =
        resources.instance
        |> Ash.Query.for_read(:read)
        |> Ash.Query.filter(id == ^token.instance_id)
        |> Ash.read_one!(Scope.engine(parent_scope))

      FlightView.token_moved(parent, token)

      resources.process_event.create!(
        %{
          instance_id: parent.id,
          token_id: token.id,
          node_id: token.node_id,
          kind: :child_completed,
          data: %{"child_instance_id" => instance.id, "outcome" => to_outcome(outcome)}
        },
        Scope.engine(parent_scope)
      )

      continue_parent(resources, parent, token, parent_scope)
    else
      # The parent branch was pruned while the child ran -- a terminate, a cancel, or an
      # interrupting boundary above it. The child still finished, and its work still happened;
      # there is simply nobody left to tell.
      _ -> :ok
    end
  end

  defp continue_parent(resources, parent, token, scope) do
    graph =
      AshBpmn.DefinitionLoader.load!(
        resources.definition,
        parent.definition_id,
        parent,
        scope
      ).graph

    case AshBpmn.Runtime.Routing.outgoing(graph, token.node_id) do
      [flow | _] ->
        consumed = resources.token.consume!(token, Scope.engine(scope))
        FlightView.token_moved(parent, consumed)

        new_token =
          resources.token.create!(
            %{
              instance_id: parent.id,
              node_id: flow["to"],
              status: :active,
              routing: token.routing || %{}
            },
            Scope.engine(scope)
          )

        FlightView.token_moved(parent, new_token)

        AshBpmn.Runtime.Oban.insert(
          AshBpmn.Runtime.AdvanceWorker,
          Scope.to_job_args(scope, %{
            "instance_id" => parent.id,
            "token_id" => new_token.id,
            "node_id" => flow["to"]
          })
        )

      [] ->
        resources.token.consume!(token, Scope.engine(scope))
    end
  end

  # Starts the child a call activity is waiting for, naming the waiting token so the child's
  # completion knows where to go back to.
  #
  # The child is given the same subject as its parent. A call activity is the same work broken
  # out, not work about something else -- and a child whose subject had to be computed would
  # need a mapping vocabulary that nothing has asked for. The depth is inherited so a process
  # that calls itself is bounded by the same counter as everything else.
  defp start_child_instance(resources, ctx, spec, scope) do
    instance = ctx[:instance]

    # The domain arrives in job args as a string -- they are JSON -- so it is normalized the
    # same way the worker normalized it to resolve `resources` in the first place. Passing the
    # raw value reaches `Module.get_attribute` with a binary, which fails somewhere that reads
    # like a bug in Ash rather than a bug here.
    case AshBpmn.start_instance(DomainResolver.module!(scope.domain),
           process: spec.key,
           subject_type: instance.subject_type,
           subject_id: instance.subject_id,
           parent_instance_id: instance.id,
           parent_token_id: ctx[:token] && ctx[:token].id,
           trigger_depth: (instance.trigger_depth || 0) + 1,
           actor: Map.get(scope, :actor),
           tenant: Map.get(scope, :tenant)
         ) do
      {:ok, child} ->
        record_event(resources, ctx, :child_started, %{
          "process_key" => spec.key,
          "child_instance_id" => child.id
        })

      {:error, reason} ->
        # The parent is already parked. Raising sends the job back to Oban, which retries the
        # whole dispatch -- and the park is idempotent under that because the token is no
        # longer `:executing` and the claim fails. Better a retry than a token waiting for a
        # child that was never started.
        raise "call activity #{spec.node_id} could not start #{spec.key}: #{inspect(reason)}"
    end
  end

  # Mints the token the fan-out was holding back, once the last instance has finished.
  #
  # Routing comes from the *joining* token, minus the element key -- which is deliberate. Each
  # instance ran for one element and carrying any single one of them past the join would make
  # the continuation look like it belonged to whichever branch happened to finish last.
  defp continue_from_join(resources, ctx, target_node_id, element_key, scope) do
    routing = Map.drop((ctx[:token] && ctx[:token].routing) || %{}, [element_key])

    new_token =
      resources.token.create!(
        %{
          instance_id: ctx[:instance].id,
          node_id: target_node_id,
          status: :active,
          routing: routing
        },
        Scope.engine(scope)
      )

    AshBpmn.Runtime.Oban.insert(
      AshBpmn.Runtime.AdvanceWorker,
      Scope.to_job_args(scope, %{
        "instance_id" => ctx[:instance].id,
        "token_id" => new_token.id,
        "node_id" => target_node_id
      })
    )
  end

  # An end event ends *its branch*. The instance is finished when the last branch reaches one.
  #
  # This used to complete unconditionally, and the interpreter's own comment claimed
  # `complete_instance` was "idempotent about that". It was not: the first branch to reach an
  # end completed the instance and the second failed `StatusIsRunning`, so an ordinary
  # parallel fork whose branches have their own end events -- legal BPMN, and what every
  # non-interrupting boundary produces -- could not run at all. The job then retried and
  # failed the same way until `max_attempts`.
  #
  # The current token has already been consumed by the `consume_token` effect, which is
  # applied earlier in the same list, so "are any live tokens left?" is the whole question.
  # `:waiting` counts as live: a branch parked on an approval has not finished, and completing
  # the instance around it would strand it exactly as a cancel used to.
  defp complete_when_last(resources, ctx, outcome, scope) do
    remaining =
      resources.token
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(
        instance_id == ^ctx[:instance].id and status in [:active, :executing, :waiting]
      )
      |> Ash.read!(Scope.engine(scope))

    if remaining == [] do
      resources.instance.mark_completed!(ctx[:instance], to_outcome(outcome), Scope.engine(scope))
      record_event(resources, ctx, :instance_completed, %{"outcome" => outcome})
      wake_parent(resources, ctx[:instance], outcome, scope)
    else
      # Recorded, because "this branch finished and the process did not" is a fact somebody
      # reading the log will want, and its absence is what makes a stuck parallel process hard
      # to reason about.
      record_event(resources, ctx, :branch_completed, %{
        "outcome" => outcome,
        "branches_remaining" => length(remaining)
      })
    end
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
      killed = resources.token.kill!(token, Scope.engine(scope))
      FlightView.token_moved(ctx[:instance], killed)
      killed
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
