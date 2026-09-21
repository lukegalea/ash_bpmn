# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn do
  @moduledoc """
  Public facade for the ash_bpmn runtime engine.

  Provides functions for starting process instances, completing tasks,
  claiming tasks, delegating, cancelling, querying, and retrying.
  """

  require Ash.Query
  require Ash.Expr

  alias AshBpmn.Config
  alias AshBpmn.Runtime.{AdvanceWorker, DomainResolver, Oban, Routing}
  alias AshBpmn.Scope

  # ── Instance lifecycle ───────────────────────────────────────────────────

  @doc """
  Starts a new process instance for the given process key.

  Options:
    * `:process` — process key (required)
    * `:subject` — the subject record (required)
    * `:actor` — the user starting the process
    * `:tenant` — organization/tenant id. Set on the instance, its first token
      and its events, and carried in the args of every job this start enqueues —
      so it survives into the advance worker, which runs long after this call
      has returned.
  """
  @spec start_instance!(module(), keyword()) :: map()
  def start_instance!(domain, opts) do
    # Re-raise the original exception rather than letting a `{:ok, _} =` match turn it into a
    # MatchError. The README says the bang variants do this; they did not, and the difference
    # matters -- a MatchError wrapping a RuntimeError hides both the message and the
    # stacktrace of the thing that actually went wrong, which for a failing node is the only
    # information anyone wants.
    case start_instance(domain, opts) do
      {:ok, instance} -> instance
      {:error, %{__exception__: true} = exception} -> raise exception
      {:error, reason} -> raise "AshBpmn.start_instance! failed: #{inspect(reason)}"
    end
  end

  @doc """
  Options beyond `:process` / `:definition` / `:definition_id` and `:subject`:

    * `:actor` — the authority the engine acts with.
    * `:started_by_id` — who is *accountable* for the process existing. Defaults to the
      actor's id, and is worth setting separately whenever the two differ: a process started
      by a trigger runs as a non-human actor but was caused by a person, and a system actor
      has no id to fall back on.
    * `:tenant`, `:correlation_id`.
    * `:subject_type` / `:subject_id` — an alternative to `:subject` for callers that have the
      identity but not the record. A call activity starting a child uses these, because the
      parent already read the subject and re-reading it to hand it over would be a query to
      produce something it has.
    * `:parent_instance_id` / `:parent_token_id` — set by a call activity, so the child's
      completion knows which token is waiting for it.
    * `:trigger_depth` — how many hops produced this instance. Inherited and incremented by
      anything that starts a process from a process; the bound that stops a cycle.
  """
  @spec start_instance(module(), keyword()) :: {:ok, map()} | {:error, term()}
  def start_instance(domain, opts) do
    subject = Keyword.get(opts, :subject)
    actor = Keyword.get(opts, :actor)

    if is_nil(subject) and is_nil(opts[:subject_type]) do
      raise ArgumentError, "start_instance/2 needs either :subject or :subject_type/:subject_id"
    end

    scope = %{Scope.from_opts(opts) | domain: domain}

    {:ok, resources} = AshBpmn.Resources.for_domain(domain)

    case resolve_definition(resources, opts, scope) do
      {:error, reason} ->
        {:error, reason}

      {:ok, definition} ->
        # Create instance
        instance =
          resources.instance.create!(
            %{
              definition_id: definition.id,
              subject_type: (subject && subject.__struct__ |> to_string()) || opts[:subject_type],
              subject_id: (subject && subject.id) || opts[:subject_id],
              parent_instance_id: opts[:parent_instance_id],
              parent_token_id: opts[:parent_token_id],
              trigger_depth: opts[:trigger_depth] || 0,
              # The actor and the person accountable are not the same thing, and conflating
              # them breaks two legitimate cases: an engine or system actor has no `:id` at
              # all and would raise here, and a process started on someone's behalf should
              # name *them* rather than whatever authority started it. So `:started_by_id`
              # can be given explicitly, and the actor is only the fallback.
              #
              # This is the same distinction a host's audit layer already draws between
              # `created_by` and `created_on_behalf_by`.
              started_by_id: Keyword.get(opts, :started_by_id) || actor_id(actor),
              # The instance has carried a `correlation_id` attribute, and its create action
              # has accepted one, since the resource was written -- but nothing ever passed
              # it, so every process was an orphan in the host's trace. A process started by
              # a request, or by an event, belongs to the operation that started it.
              correlation_id: Keyword.get(opts, :correlation_id)
            },
            Scope.engine(scope)
          )

        # Reload instance to get fresh state
        instance =
          resources.instance
          |> Ash.Query.for_read(:read)
          |> Ash.Query.filter(id == ^instance.id)
          |> Ash.read_one!(Scope.engine(scope))

        # Create initial token at the start node
        start_node = definition.graph["start"]

        token =
          resources.token.create!(
            %{
              instance_id: instance.id,
              node_id: start_node,
              status: :active
            },
            Scope.engine(scope)
          )

        # Record instance_started event
        resources.process_event.create!(
          %{
            instance_id: instance.id,
            kind: :instance_started,
            data: %{
              # The definition's own key rather than the caller's argument: a host that passed
              # a definition directly never supplied one, and the key on the row is the
              # authoritative answer either way.
              "process_key" => definition.key,
              "definition_version" => definition.version
            }
          },
          Scope.engine(scope)
        )

        # Enqueue first advance. The tenant rides in the job args because the
        # worker runs in a different process, quite possibly on a different node
        # and after a restart -- there is nothing left for it to infer one from.
        Oban.insert(
          AdvanceWorker,
          Scope.to_job_args(scope, %{
            "instance_id" => instance.id,
            "token_id" => token.id,
            "node_id" => start_node
          })
        )

        # Reload instance to get fresh state
        fresh_instance =
          resources.instance
          |> Ash.Query.for_read(:read)
          |> Ash.Query.filter(id == ^instance.id)
          |> Ash.read_one!(Scope.engine(scope))

        {:ok, fresh_instance}
    end
  rescue
    e -> {:error, e}
  end

  # ── Task operations ──────────────────────────────────────────────────────

  @doc """
  Completes a human task (process-bound or standalone).

  Options:
    * `:outcome` — required outcome (an atom or a string; stored and read back as a string)
    * `:comment` — optional comment
    * `:actor` — required, the user completing the task
  """
  @spec complete_task!(map(), keyword()) :: map()
  def complete_task!(task, opts) do
    task |> complete_task(opts) |> unwrap!()
  end

  # The `{:ok, _} | {:error, _}` functions below rescue and return the exception
  # itself, so the bang variants can re-raise it and callers keep the original
  # error type — an `ArgumentError` from a candidacy check stays an
  # `ArgumentError` rather than becoming a `MatchError`.
  defp unwrap!({:ok, value}), do: value
  defp unwrap!({:error, exception}), do: raise(exception)

  @spec complete_task(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def complete_task(task, opts) do
    outcome = Keyword.fetch!(opts, :outcome)
    comment = Keyword.get(opts, :comment)
    actor = Keyword.fetch!(opts, :actor)

    resources = DomainResolver.resolve!()
    scope = Scope.from_record(task, opts)

    # Reload so we complete against current state, not a struct the caller may
    # have been holding since before the task's timers were attached.
    task = reload_task!(resources, task, scope)

    # A task may be completed without an explicit claim; record the implicit
    # claim so the event log still shows who took it before deciding.
    task =
      if task.status == :open do
        {:ok, claimed} =
          resources.human_task.claim(
            task,
            %{assignee_type: :user, assignee_id: actor.id},
            Scope.engine(scope)
          )

        record_claim_event(resources, claimed, actor, scope)
        claimed
      else
        task
      end

    completed =
      resources.human_task.complete!(
        task,
        %{outcome: outcome, comment: comment, decided_by_id: actor.id},
        Scope.engine(scope)
      )

    record_task_event(
      resources,
      completed,
      :task_completed,
      %{
        "outcome" => outcome,
        "decided_by_id" => actor.id,
        "comment" => comment
      },
      scope
    )

    # Usage rule 6: a completion path cancels the task's outstanding timers.
    # The cancellation is also *recorded*, so the log shows not just that the
    # task was decided but that its escalate/expire clocks were stopped with it.
    cancel_task_timers(resources, completed, :task_decided, scope)

    # If this is a process task, advance the token
    if completed.token_id do
      advance_token_after_task(resources, completed, outcome, scope)
    end

    {:ok, completed}
  rescue
    e -> {:error, e}
  end

  @doc """
  Decides a standalone approval task.

  Identical to complete_task! but also fires the on_complete action ref
  for standalone approvals (where instance_id is nil).
  """
  @spec decide!(map(), keyword()) :: map()
  def decide!(task, opts) do
    task |> decide(opts) |> unwrap!()
  end

  @spec decide(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def decide(task, opts) do
    outcome = Keyword.fetch!(opts, :outcome)
    actor = Keyword.fetch!(opts, :actor)

    case complete_task(task, opts) do
      {:ok, completed} ->
        # Fire on_complete for standalone approvals
        if completed.instance_id == nil && completed.on_complete != nil &&
             completed.on_complete != %{} do
          action_ref = completed.on_complete[to_string(outcome)]

          if action_ref do
            invoker = Config.action_invoker!()
            scope = Scope.from_record(completed, opts)

            subject = AshBpmn.Subject.load(completed, scope)

            ctx = %{
              subject: subject,
              actor: actor,
              instance: nil,
              task: completed,
              assigns: %{"task" => %{"outcome" => outcome}}
            }

            invoker.invoke(action_ref, ctx)
          end
        end

        {:ok, completed}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Claims a human task, asserting the actor is a candidate.

  Raises if the actor's principal id is not in the TaskCandidate rows.
  """
  @spec claim_task!(map(), keyword()) :: map()
  def claim_task!(task, opts) do
    task |> claim_task(opts) |> unwrap!()
  end

  @spec claim_task(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def claim_task(task, opts) do
    actor = Keyword.fetch!(opts, :actor)
    resources = DomainResolver.resolve!()
    scope = Scope.from_record(task, opts)

    # Check candidacy
    candidates =
      resources.task_candidate
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(task_id == ^task.id)
      |> Ash.read!(Scope.engine(scope))

    principal_ids = gather_principal_ids(actor)

    candidate_match =
      Enum.any?(candidates, fn c ->
        c.principal_type == :user && c.principal_id in principal_ids
      end)

    unless candidate_match do
      raise ArgumentError,
            "actor is not a candidate for task #{task.id}. " <>
              "Actor principal ids: #{inspect(principal_ids)}, " <>
              "Candidates: #{inspect(Enum.map(candidates, &{&1.principal_type, &1.principal_id}))}"
    end

    claimed =
      resources.human_task.claim!(
        reload_task!(resources, task, scope),
        %{assignee_type: :user, assignee_id: actor.id},
        Scope.engine(scope)
      )

    record_claim_event(resources, claimed, actor, scope)

    {:ok, claimed}
  rescue
    e -> {:error, e}
  end

  # Events are recorded for standalone approvals too — they have no instance,
  # but "who claimed, who decided" is exactly what the log is for.
  defp record_task_event(resources, task, kind, data, scope) do
    resources.process_event.create!(
      %{
        instance_id: task.instance_id,
        token_id: task.token_id,
        node_id: task.node_id,
        task_id: task.id,
        kind: kind,
        data: data
      },
      Scope.engine(scope)
    )

    :ok
  end

  defp record_claim_event(resources, task, actor, scope) do
    record_task_event(resources, task, :task_claimed, %{"assignee_id" => actor.id}, scope)
  end

  # Cancels every outstanding timer job on a task and records a
  # `:timer_cancelled` event for it. A timer cancelled with its task is a fact
  # about the task's history: the audit log should show that the escalation
  # clock stopped *because* the task was decided, not leave a reader to infer
  # it.
  #
  # `reason` is why, and it is the whole point. Oban can be told to cancel a job and cannot
  # be told why; the Pruner then deletes the row entirely. So without this, "the escalation
  # never fired" and "the escalation stopped because somebody decided at 14:07" are the same
  # absence a week later.
  defp cancel_task_timers(resources, task, reason, scope) do
    # Cancelling the Oban jobs still depends on having their ids, because that is what a
    # cancel addresses. The ledger sweep below deliberately does NOT -- a task whose ids were
    # never persisted (the window between insert and attach) is exactly the case the ledger
    # exists to cover, and gating it on the same empty list would blind it there.
    case task.timer_job_ids || [] do
      [] ->
        :ok

      job_ids ->
        Enum.each(job_ids, &AshBpmn.Runtime.Oban.cancel_job/1)

        record_task_event(resources, task, :timer_cancelled, %{"job_ids" => job_ids}, scope)
    end

    cancel_boundary_timers(resources, task, scope)
    cancel_ledger_rows(resources, task, reason, scope)
  end

  # A boundary timer belongs to the token, not to the task, so its id is not in
  # `task.timer_job_ids` and it survives everything that cancellation loop does. Left armed,
  # it fires hours after the approval was decided and tries to interrupt an activity that has
  # already finished -- it would lose at the claim, but only after cancelling a completed
  # task's siblings and writing a misleading row.
  #
  # Cancelled by owner through the meta index rather than by id, which is what
  # `AshBpmn.Runtime.Oban.cancel_all/1` was built for.
  defp cancel_boundary_timers(resources, task, scope) do
    if task.token_id do
      case AshBpmn.Runtime.Oban.cancel_all(%{"token_id" => task.token_id, "kind" => "boundary"}) do
        {:ok, 0} ->
          :ok

        {:ok, count} ->
          record_task_event(
            resources,
            task,
            :timer_cancelled,
            %{"kind" => "boundary", "cancelled" => count},
            scope
          )
      end
    end

    :ok
  end

  defp cancel_ledger_rows(resources, task, reason, scope) do
    if resources.timer_job do
      resources.timer_job
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(task_id == ^task.id and status == :scheduled)
      |> Ash.read!(Scope.engine(scope))
      |> Enum.each(fn row ->
        # Non-bang. A losing race -- the timer fired between the read and the write -- is
        # ordinary, and failing to record a cancellation must not fail the decision that
        # caused it.
        resources.timer_job.record_cancelled(row, reason, Scope.engine(scope))
      end)
    end

    :ok
  end

  defp reload_task!(resources, task, scope) do
    resources.human_task
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^task.id)
    |> Ash.read_one!(Scope.engine(scope))
  end

  @doc "Delegates a claimed task to another principal."
  @spec delegate_task!(map(), keyword()) :: map()
  def delegate_task!(task, opts) do
    task |> delegate_task(opts) |> unwrap!()
  end

  @spec delegate_task(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def delegate_task(task, opts) do
    to_principal = Keyword.fetch!(opts, :to_principal)
    actor = Keyword.fetch!(opts, :actor)
    resources = DomainResolver.resolve!()
    scope = Scope.from_record(task, opts)

    # The action's RecordDelegatedFrom change captures the outgoing assignee as
    # `delegated_from_id` — the accountability trail delegation exists for.
    delegated =
      resources.human_task.delegate!(
        reload_task!(resources, task, scope),
        to_principal.type,
        to_principal.id,
        Scope.engine(scope)
      )

    record_task_event(
      resources,
      delegated,
      :task_delegated,
      %{
        "from_id" => actor.id,
        "to_type" => to_principal.type,
        "to_id" => to_principal.id
      },
      scope
    )

    {:ok, delegated}
  rescue
    e -> {:error, e}
  end

  # ── Instance operations ─────────────────────────────────────────────────

  @doc """
  Cancels a running instance.

  `opts` may carry `:actor` and `:tenant`. Without a `:tenant` the instance's own
  `organization_id` is used, which is the right answer whenever the caller loaded
  the instance in the first place.
  """
  @spec cancel_instance!(map(), keyword()) :: map()
  def cancel_instance!(instance, opts \\ []) do
    {:ok, cancelled} = cancel_instance(instance, opts)
    cancelled
  end

  @spec cancel_instance(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def cancel_instance(instance, opts \\ []) do
    resources = DomainResolver.resolve!()
    scope = Scope.from_record(instance, opts)

    halt_instance_work(resources, instance, :instance_cancelled, scope)

    cancelled = resources.instance.cancel!(instance, Scope.engine(scope))

    resources.process_event.create!(
      %{
        instance_id: instance.id,
        kind: :instance_cancelled,
        data: %{}
      },
      Scope.engine(scope)
    )

    {:ok, cancelled}
  rescue
    e -> {:error, e}
  end

  @doc false
  # Stops an instance doing anything further: every live token killed, every open task closed,
  # every clock attached to those tasks defused. The half of `cancel_instance/2` that is not
  # about the word "cancelled".
  #
  # Shared with `AshBpmn.Migration.Restart`, because a superseded instance has to stop exactly
  # as hard as a cancelled one. A parked token left behind by either is not merely untidy: the
  # correlator finds waiting tokens by signature and knows nothing about instance status, so an
  # event arriving afterwards would wake it and resume a process nobody is running any more.
  # That was found for cancellation by the one test Phase 3's exit criterion names for it, and
  # a restart that reimplemented this would have had to find it a second time.
  #
  # `reason` is what the timer ledger records, and it is a parameter rather than a constant so
  # a cancelled clock and a restarted one stay distinguishable in the ledger.
  #
  # What this deliberately does not chase is a *catch* timer, which belongs to a token rather
  # than to a task and so is not in any task's job list. It is left armed and loses when it
  # fires: `claim_waiting` admits only a `:waiting` token, and this has just killed it. That is
  # a wasted job rather than a wrong one, and chasing it would mean a second index of job ids
  # with the window that motivated `AshBpmn.Runtime.Oban.cancel_all/1` in the first place.
  @spec halt_instance_work(map(), map(), atom(), Scope.t()) :: :ok
  def halt_instance_work(resources, instance, reason, scope) do
    # Every live token, `:waiting` included. It used to be `:active` and `:executing` only,
    # which was complete when those were the only live states.
    live_tokens =
      resources.token
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(instance_id == ^instance.id)
      |> Ash.Query.filter(status in [:active, :executing, :waiting])
      |> Ash.read!(Scope.engine(scope))

    Enum.each(live_tokens, fn token ->
      resources.token.kill!(token, Scope.engine(scope))
    end)

    open_tasks =
      resources.human_task
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(instance_id == ^instance.id)
      |> Ash.Query.filter(status in [:open, :claimed])
      |> Ash.read!(Scope.engine(scope))

    Enum.each(open_tasks, fn task ->
      resources.human_task.cancel!(task, Scope.engine(scope))
      cancel_task_timers(resources, task, reason, scope)
    end)

    :ok
  end

  @doc """
  Restarts a running instance under another definition, superseding the old one.

  The answer to `AshBpmn.Migration.Classifier`'s `needs_restart` verdict. See
  `AshBpmn.Migration.Restart` for what "restart" was decided to mean, what is carried across
  and what is deliberately not.

  Returns `{:ok, %{superseded: old, successor: new, decision: record}}`.
  """
  @spec restart_instance(map(), keyword()) :: {:ok, map()} | {:error, term()}
  defdelegate restart_instance(instance, opts \\ []), to: AshBpmn.Migration.Restart, as: :restart

  @doc """
  `restart_instance/2`, raising instead of returning `{:error, reason}`.
  """
  @spec restart_instance!(map(), keyword()) :: map()
  defdelegate restart_instance!(instance, opts \\ []),
    to: AshBpmn.Migration.Restart,
    as: :restart!

  @doc """
  Returns tasks where the given principal is a candidate.

  Options:
    * `:principal_ids` — list of UUIDs (required)
    * `:actor`, `:tenant` — see `AshBpmn.Scope`. On a tenant-scoped install
      `:tenant` is what stops this returning another organization's work.
  """
  @spec my_tasks(module(), keyword()) :: [map()]
  def my_tasks(domain, opts) do
    principal_ids = Keyword.fetch!(opts, :principal_ids)
    scope = Scope.from_opts(opts)

    {:ok, resources} = AshBpmn.Resources.for_domain(domain)

    # Usage rule 2: candidates are rows, and a task list is **one** indexed
    # query joined on those rows. The join is an unrelated exists over
    # `TaskCandidate` -- the candidate resource is resolved from the host's
    # domain at runtime, so the exists is built as a value rather than written
    # as a literal module in an expression.
    candidate_is_mine = %Ash.Query.Exists{
      path: [],
      resource: resources.task_candidate,
      at_path: [],
      related?: false,
      expr:
        Ash.Expr.expr(
          task_id == parent(id) and principal_type == :user and
            principal_id in ^principal_ids
        )
    }

    resources.human_task
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(status in [:open, :claimed])
    |> Ash.Query.filter(^candidate_is_mine)
    |> Ash.read!(Scope.engine(scope))
  end

  @doc "Returns a full report of an instance (tokens, tasks, events)."
  @spec instance_report(map(), keyword()) :: %{
          instance: map(),
          tokens: [map()],
          tasks: [map()],
          events: [map()]
        }
  def instance_report(instance, opts \\ []) do
    resources = DomainResolver.resolve!()
    scope = Scope.from_record(instance, opts)

    tokens =
      resources.token
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(instance_id == ^instance.id)
      |> Ash.read!(Scope.engine(scope))

    tasks =
      resources.human_task
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(instance_id == ^instance.id)
      |> Ash.read!(Scope.engine(scope))

    events =
      resources.process_event
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(instance_id == ^instance.id)
      |> Ash.Query.sort(recorded_at: :asc)
      |> Ash.read!(Scope.engine(scope))

    %{
      instance: instance,
      tokens: tokens,
      tasks: tasks,
      events: events
    }
  end

  @doc """
  Throws a signal: a broadcast every catch event listening for `name` will receive.

  Unlike a message, which is addressed to one waiting token by a correlation key, a signal is
  consumed by nobody and delivered to everybody. Throwing one into an empty room is not an
  error — it is the ordinary case, and a signal nothing catches is a fact that happened.

  Hosts call this directly; a signal throw node calls it through the engine. Both write a row
  through the host's audited base, so the throw *is* an event in the host's log rather than a
  message beside it — which is what makes delivery replayable and "who caught this?" a query.

  ## Options

    * `:payload` — the signal's own data. Not the subject's; a catch reads that live.
    * `:instance` — the instance throwing, when a process is. Its `trigger_depth` is
      inherited and incremented, which is what bounds a signal that starts a process that
      throws a signal.
    * `:tenant` / `:actor` — as everywhere else.

  Returns `{:error, :signals_not_installed}` when the host has not registered a signal
  resource. That is a configuration answer rather than a failure: the kind is optional, and a
  host that throws no signals carries no table for them.
  """
  @spec emit_signal(String.t(), keyword()) :: {:ok, struct()} | {:error, term()}
  def emit_signal(name, opts \\ []) when is_binary(name) do
    resources = DomainResolver.resolve!()
    instance = opts[:instance]
    scope = Scope.from_record(instance || %{}, opts)

    if resources.signal do
      resources.signal.emit(
        name,
        %{
          payload: opts[:payload] || %{},
          instance_id: instance && instance.id,
          node_id: opts[:node_id],
          # The lap counter. A host throwing a signal from its own code starts at one, because
          # its call is the first hop; a process inherits the depth it was started at.
          depth: ((instance && instance.trigger_depth) || 0) + 1
        },
        Scope.engine(scope)
      )
    else
      {:error, :signals_not_installed}
    end
  end

  @doc "Retries a failed instance by reactivating dead tokens."
  @spec retry_instance!(map(), keyword()) :: map()
  def retry_instance!(instance, opts \\ []) do
    {:ok, retried} = retry_instance(instance, opts)
    retried
  end

  @spec retry_instance(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def retry_instance(instance, opts \\ []) do
    resources = DomainResolver.resolve!()
    scope = Scope.from_record(instance, opts)

    # Retrying reactivates every dead token and re-enqueues it, which is right for `:failed` --
    # the engine gave up and the work is still owed. It is wrong for `:errored`: that instance
    # ended the way its diagram says it should, and its dead tokens are branches an error end
    # event killed on purpose. Resurrecting them would restart a process that already produced
    # its answer, and the answer was no.
    if instance.status == :errored do
      {:error,
       "instance #{instance.id} ended at an error end event, which is a designed outcome " <>
         "rather than a failure. Retrying would restart branches the process killed on " <>
         "purpose. Start a new instance instead"}
    else
      do_retry_instance(resources, instance, scope)
    end
  end

  defp do_retry_instance(resources, instance, scope) do
    dead_tokens =
      resources.token
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(instance_id == ^instance.id)
      |> Ash.Query.filter(status == :dead)
      |> Ash.read!(Scope.engine(scope))

    Enum.each(dead_tokens, fn token ->
      reactivated = resources.token.reactivate!(token, Scope.engine(scope))

      Oban.insert(
        AdvanceWorker,
        Scope.to_job_args(scope, %{
          "instance_id" => instance.id,
          "token_id" => reactivated.id,
          "node_id" => reactivated.node_id
        })
      )
    end)

    # Reload
    fresh =
      resources.instance
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(id == ^instance.id)
      |> Ash.read_one!(Scope.engine(scope))

    {:ok, fresh}
  rescue
    e -> {:error, e}
  end

  # ── Private helpers ─────────────────────────────────────────────────────

  # An actor need not be a record. A system actor is a struct with a name and no id, and
  # `actor.id` on one raises -- which surfaced as a process that could not start at all when
  # the engine was handed one.
  defp actor_id(nil), do: nil
  defp actor_id(actor) when is_map(actor), do: Map.get(actor, :id)
  defp actor_id(_actor), do: nil

  # Which definition an instance runs is **host policy**, not engine policy -- the same
  # arrangement as who a task is for and what an action does.
  #
  # By default this is "the latest published definition for this key, in this tenant", which is
  # what a single-tenant install wants and what every existing caller gets. But a host that
  # ships baseline processes centrally and lets a tenant diverge from them needs to answer the
  # question itself: the tenant has no row for the key, and the definition it should run lives
  # somewhere this package has no business knowing about. Passing `:definition` or
  # `:definition_id` is how it says so.
  #
  # Everything downstream is unchanged: the instance pins whatever definition it was given, for
  # life, and never consults this again.
  defp resolve_definition(resources, opts, scope) do
    cond do
      definition = Keyword.get(opts, :definition) ->
        {:ok, definition}

      definition_id = Keyword.get(opts, :definition_id) ->
        case Ash.get(resources.definition, definition_id, Scope.engine(scope)) do
          {:ok, definition} -> {:ok, definition}
          {:error, _} -> {:error, "no definition with id #{inspect(definition_id)}"}
        end

      process_key = Keyword.get(opts, :process) ->
        # Read through the same scope as everything below it: a definition is tenant-scoped
        # too when the host asked for that, and reading it globally would let one organization
        # start another's process.
        case resources.definition.latest_published!(process_key, Scope.engine(scope)) do
          [] -> {:error, "no published definition found for process: #{process_key}"}
          [definition | _] -> {:ok, definition}
        end

      true ->
        {:error, "start_instance requires one of :process, :definition or :definition_id"}
    end
  end

  defp advance_token_after_task(resources, task, outcome, scope) do
    token =
      resources.token
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(id == ^task.token_id)
      |> Ash.read_one!(Scope.engine(scope))

    # The wake *is* the guard. This was a read-only `token.status == :executing` check, which
    # told you the token looked advanceable a moment ago and nothing about whether anyone else
    # was advancing it; two deliveries of the same completion both passed it. `claim_waiting`
    # re-reads the row inside the transaction and admits exactly one winner, so a redelivery
    # loses here rather than routing the token twice.
    with true <- !is_nil(task.instance_id),
         {:ok, token} <- resources.token.claim_waiting(token, Scope.engine(scope)) do
      instance =
        resources.instance
        |> Ash.Query.for_read(:read)
        |> Ash.Query.filter(id == ^task.instance_id)
        |> Ash.read_one!(Scope.engine(scope))

      definition =
        AshBpmn.DefinitionLoader.load!(
          resources.definition,
          instance.definition_id,
          instance,
          scope
        )

      graph = definition.graph

      # Routing after a human task. The subject is loaded rather than left nil so a
      # post-approval gateway can route on the record as well as on the outcome --
      # `subject.amount > 50000 and task.outcome = "approved"` is the shape every approval
      # chain reaches for eventually.
      expr_ctx = %{
        "task" => %{"outcome" => to_string(outcome)},
        # The task's own node declares what its outgoing conditions need loaded, exactly as
        # it would for any other transition. Routing after a human task used to read a
        # starved subject here while the same node's entry read a loaded one.
        "subject" =>
          AshBpmn.Feel.to_feel_value(
            AshBpmn.Subject.load(
              instance,
              scope,
              get_in(graph, ["nodes", task.node_id, "load"]) || []
            )
          ),
        "routing" => AshBpmn.Feel.to_feel_value(token.routing || %{})
      }

      # Through `AshBpmn.Runtime.Routing`, the same router the interpreter's gateways use.
      # This path had its own evaluator, and it was wrong in three ways that only showed up in
      # production shapes: `_ -> false` collapsed FEEL null *and* engine errors into "branch
      # not taken", so a condition that could not answer silently picked a branch and no
      # `:condition_null` was ever recorded after a human task; the declared `default=` was
      # looked up against flows read straight out of `Map.values(graph["flows"])`, which carry
      # no `"id"`, so it never matched anything; and the last resort was `List.first(flows)`,
      # which is the engine choosing a branch the diagram did not.
      case Routing.choose(graph, task.node_id, expr_ctx, fallback: :single_unconditioned) do
        {:error, reason} ->
          # Not survivable by guessing: an expression that failed to evaluate is not a `false`.
          raise "routing from #{task.node_id} after task completion failed: #{reason}"

        {:ok, %{flow: nil, nulls: nulls, outgoing: []}} ->
          # A task with no outgoing flow is a modelling shape the compiler allows on an end
          # path; nothing to advance to, and nothing wrong.
          _ = nulls
          :ok

        {:ok, %{flow: nil, nulls: nulls}} ->
          record_null_conditions(resources, task, nulls, scope)

          raise "no outgoing flow selected from #{task.node_id} after task completion" <>
                  Routing.null_summary(nulls)

        {:ok, %{flow: target_flow, nulls: nulls}} ->
          record_null_conditions(resources, task, nulls, scope)
          follow_flow(resources, instance, token, graph, target_flow, outcome, scope)
      end
    else
      # Either the task is not part of a process instance -- standalone approvals use the same
      # task table -- or someone else already woke this token. Both are ordinary, and neither
      # is this caller's to fix.
      _ -> :ok
    end
  end

  # Null-valued conditions are recorded on this path too, which they never were before. A
  # condition that is silently never true looks exactly like one that is legitimately false,
  # and is the worse bug of the two.
  defp record_null_conditions(_resources, _task, [], _scope), do: :ok

  defp record_null_conditions(resources, task, nulls, scope) do
    Enum.each(nulls, fn flow ->
      record_task_event(
        resources,
        task,
        :condition_null,
        %{
          "flow_id" => flow["id"],
          "expression" => AshBpmn.Feel.print(flow["condition"])
        },
        scope
      )
    end)
  end

  defp follow_flow(resources, instance, token, graph, flow, outcome, scope) do
    next_node_id = flow["to"]
    next_node = graph["nodes"][next_node_id]

    if next_node do
      # Check if this is a join — handle join semantics
      join_info = graph["joins"][next_node_id]

      if join_info do
        handle_join(resources, instance, token, graph, next_node_id, join_info, outcome, scope)
      else
        consume_token!(resources, token, scope)

        new_token =
          resources.token.create!(
            %{
              instance_id: instance.id,
              node_id: next_node_id,
              status: :active
            },
            Scope.engine(scope)
          )

        Oban.insert(
          AshBpmn.Runtime.AdvanceWorker,
          Scope.to_job_args(scope, %{
            "instance_id" => instance.id,
            "token_id" => new_token.id,
            "node_id" => next_node_id,
            "task_outcome" => outcome && to_string(outcome)
          })
        )
      end
    end
  end

  defp handle_join(resources, instance, token, graph, join_node_id, join_info, _outcome, scope) do
    consume_token!(resources, token, scope)

    # Count how many tokens have been consumed at this join node
    waits_for = join_info["waits_for"] || []

    _consumed_at_join =
      resources.token
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(instance_id == ^instance.id)
      |> Ash.Query.filter(node_id == ^join_node_id)
      |> Ash.Query.filter(status == :consumed)
      |> Ash.read!(Scope.engine(scope))

    if length(waits_for) <= 1 do
      # Non-parallel join — always advance
      advance_through_join(resources, instance, token, graph, join_node_id, scope)
    else
      # Parallel join — check if remaining sibling tokens exist.
      # If any sibling still has active/executing tokens, wait. Otherwise advance.
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
        :ok
      else
        advance_through_join(resources, instance, token, graph, join_node_id, scope)
      end
    end
  end

  defp advance_through_join(resources, instance, _token, graph, join_node_id, scope) do
    outgoing =
      graph["flows"]
      |> Map.values()
      |> Enum.filter(fn flow -> flow["from"] == join_node_id end)

    case outgoing do
      [flow | _] ->
        next_node_id = flow["to"]

        new_token =
          resources.token.create!(
            %{
              instance_id: instance.id,
              node_id: next_node_id,
              status: :active
            },
            Scope.engine(scope)
          )

        Oban.insert(
          AshBpmn.Runtime.AdvanceWorker,
          Scope.to_job_args(scope, %{
            "instance_id" => instance.id,
            "token_id" => new_token.id,
            "node_id" => next_node_id
          })
        )

      _ ->
        :ok
    end
  end

  defp gather_principal_ids(%{id: id} = actor) do
    base = [id]

    # Check for team_ids on the actor struct
    base ++
      case Map.get(actor, :team_ids) do
        ids when is_list(ids) -> ids
        _ -> []
      end
  end

  defp gather_principal_ids(ctx) when is_map(ctx) do
    case Map.get(ctx, :id) do
      nil -> []
      id -> [id]
    end
  end

  defp gather_principal_ids(_), do: []

  # Consumes a token through its own action, which is the only way the claim/consume state
  # machine means anything.
  #
  # This was raw `update_all` SQL for a long time, with a comment blaming Ash's
  # change-before-validation ordering for making `StatusIsExecuting` unusable here. That
  # justification had gone stale: the validation reads `changeset.data.status` (token.ex, and
  # the comment there explains why -- `get_attribute/2` would return the value the action is
  # about to write and make the guard self-satisfying), so it sees `:executing` correctly.
  #
  # What the SQL cost, every time this ran: no audit row, no notifier, no tenant predicate on
  # the update, and a `{1, _} = ` match that raised a bare `MatchError` when the row was not in
  # the state it assumed. The timer worker's expiry path already used the action, so the two
  # completion paths disagreed about whether consuming a token was an auditable event.
  defp consume_token!(resources, token, scope) do
    resources.token.consume!(token, Scope.engine(scope))
    :ok
  end
end
