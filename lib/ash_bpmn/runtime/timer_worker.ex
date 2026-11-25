# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.Runtime.TimerWorker do
  @moduledoc """
  Oban worker that fires task timers (remind, escalate, expire).

  Job args: `%{"task_id" => id, "kind" => "remind" | "escalate" | "expire", "index" => n}`,
  and `"signal"` on an escalation that throws one.

  - `remind` -- records `:timer_fired` and delivers a `:remind` notice.
  - `escalate` -- with `signal`, throws it. Otherwise asks the resolver's `escalate/2` whom to
    add, writes them as candidates minus the task's exclusions (DESIGN.md §11.6), and
    delivers an `:escalated` notice.
  - `expire` -- force-completes the task with outcome `:expired`, routes the token, and
    delivers an `:expired` notice when a notifier is configured.

  Every firing has a key, `"<task id>/<node id>/<timer index>/<repetition>"`, the same on
  every retry. Notices go through `AshBpmn.Runtime.Notices` after the firing's writes have
  committed; a delivery that fails returns `{:error, _}` so Oban retries the job, and the
  retry finds its writes already made under the same key and adds none.
  """

  use Oban.Worker, max_attempts: 3

  require Ash.Query

  alias AshBpmn.Config
  alias AshBpmn.FlightView
  alias AshBpmn.Runtime.DomainResolver
  alias AshBpmn.Runtime.Notices
  alias AshBpmn.Runtime.Routing
  alias AshBpmn.Runtime.Step
  alias AshBpmn.Runtime.TimerLedger
  alias AshBpmn.Scope

  def queue, do: Config.queue()

  @impl true
  def perform(%Oban.Job{args: args} = job) do
    task_id = args["task_id"]
    kind = args["kind"]

    scope = Scope.from_job(args, :timer)
    resources = DomainResolver.resolve!(scope.domain)

    task =
      resources.human_task
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(id == ^task_id)
      |> Ash.read_one!(Scope.engine(scope))

    cond do
      is_nil(task) ->
        {:ok, :skipped}

      # Nothing fires for work that is over (DESIGN.md §11.4) -- except the retry of an expiry
      # whose own completion is what ended the task, and whose notice has not gone yet.
      task.status in [:completed, :cancelled] and kind == "expire" ->
        resume_expired_notice(resources, task, scope, job)

      task.status in [:completed, :cancelled] ->
        {:ok, :skipped}

      # A start deadline that escaped the claim's cancel (it was already running). The claim
      # recorded the ledger row's end; this firing is the one that must not happen.
      args["until"] == "claimed" and task.status != :open ->
        {:ok, :skipped}

      # A firing whose ledger row was cancelled (rescheduled, claimed, ended with its task)
      # escaped Oban's cancel; the row is the record that it must not fire.
      TimerLedger.cancelled?(resources, args, scope) ->
        {:ok, :skipped}

      true ->
        fire_timer(resources, task, kind, scope, job)
    end
  end

  # What every firing's event carries beside its kind: the stable key a host deduplicates on
  # (DESIGN.md §11.4), the repetition, the instant it was due and whether it was already past
  # when armed. Absent from jobs armed before §11, which carry none of it.
  @doc false
  def firing_data(args) do
    args
    |> Map.take(["key", "repetition", "due_at", "late", "timer_job_id"])
  end

  # ── remind ────────────────────────────────────────────────────────────────

  # A reminder's writes are one step: its event, its ledger row and, for a cycle, the next
  # repetition commit together, so a redelivery that finds them written adds nothing (no
  # second next repetition). The notice goes after the step commits; a retry whose delivery
  # failed finds the writes made and only delivers, under the same key.
  defp fire_timer(resources, task, "remind", scope, job) do
    timer = timer_info(resources, task, job.args, scope)
    fun = fn -> remind(resources, task, timer, scope, job.args) end

    case task.instance_id do
      nil -> Step.transaction(resources, fun)
      id -> Step.transaction(resources, fn _locked -> fun.() end, lock: {id, scope})
    end
    |> case do
      {:ok, :reminded} -> deliver_remind(resources, task, timer, scope, job, :reminded)
      {:ok, :already_fired} -> deliver_remind(resources, task, timer, scope, job, :already_fired)
      {:error, :instance_gone} -> {:ok, :skipped}
      {:error, reason} -> {:error, reason}
    end
  end

  # ── escalate ──────────────────────────────────────────────────────────────

  # An escalation that names a signal throws it instead of calling the resolver.
  #
  # That is the difference between notifying somebody and starting something: a resolver's
  # `escalate/2` reaches a person through whatever the host wired up, and a signal reaches
  # every process listening for that name. A modeller who wants the second should not have to
  # ask an Elixir developer for it.
  defp fire_timer(resources, task, "escalate", scope, %Oban.Job{args: %{"signal" => name} = args})
       when is_binary(name) and name != "" do
    instance = load_instance(resources, task, scope)

    case AshBpmn.emit_signal(name,
           instance: instance,
           node_id: task.node_id,
           payload: %{"task_id" => task.id, "escalated" => true},
           actor: Map.get(scope, :actor),
           tenant: Map.get(scope, :tenant)
         ) do
      {:ok, _signal} ->
        record_task_event(
          resources,
          task,
          :timer_fired,
          scope,
          Map.merge(firing_data(args), %{
            "timer_kind" => "escalate",
            "handler" => "signal",
            "signal_name" => name
          })
        )

        record_fire(resources, task, :escalate, scope, args)
        {:ok, :escalated}

      {:error, reason} ->
        record_task_event(
          resources,
          task,
          :escalation_failed,
          scope,
          Map.merge(firing_data(args), %{"timer_kind" => "escalate", "error" => inspect(reason)})
        )

        record_fire(resources, task, :escalate, scope, args)
        {:error, inspect(reason)}
    end
  end

  # Escalation adds people; the engine keeps the exclusions (DESIGN.md §11.6). The resolver
  # answers whom to add, `{:ok, [principal]}`. The engine subtracts the task's exclusions,
  # writes the rest as candidate rows in the task's tenant, never removes a candidate or the
  # assignee, records `:task_escalated`, and only then -- after that commits -- hands the
  # notice to the notifier, so a failed delivery never undoes the escalation.
  #
  # An answer that is empty, or that the exclusions empty, reached nobody: recorded as
  # `:escalation_reached_nobody` and not retried, because the same organization gives the same
  # answer. An error, a raise or any other shape (a bare `:ok` from the old contract included)
  # is `:escalation_failed` and returned, so Oban retries.
  #
  # A host with no `escalate/2` (possible only for a definition published before the
  # publish-time check) reaches nobody too, and says so, rather than recording a firing that
  # told no one.
  defp fire_timer(resources, task, "escalate", scope, job) do
    resolver = Config.assignment_resolver!()
    timer = timer_info(resources, task, job.args, scope)

    if Code.ensure_loaded?(resolver) and function_exported?(resolver, :escalate, 2) do
      ctx = escalation_ctx(resources, task, scope, timer)

      case invoke_escalation(resolver, task, ctx) do
        {:ok, principals} ->
          escalated(resources, task, principals, timer, scope, job, ctx)

        {:failed, message} ->
          record_task_event(resources, task, :escalation_failed, scope, %{
            "timer_kind" => "escalate",
            "key" => timer.key,
            "error" => message
          })

          {:error, message}
      end
    else
      record_reached_nobody(resources, task, timer, scope, job.args, %{
        "reason" => "no_escalate_callback"
      })

      {:ok, :no_escalation_handler}
    end
  end

  # ── expire ────────────────────────────────────────────────────────────────

  # The expiry is one step, under the instance's lock: the forced completion, its events, the
  # wake and the token's next move commit together. An expiry that died after forcing the
  # task complete used to leave an `:expired` task on a token still parked for it.
  #
  # The notice goes after the step commits. Expiry routes the graph whether or not anyone is
  # told, so a notifier that fails retries the job, and the retry finds the task already
  # expired and only delivers (`resume_expired_notice/4`).
  defp fire_timer(resources, task, "expire", scope, job) do
    fun = fn -> expire(resources, task, scope, job.args) end

    case task.instance_id do
      nil -> Step.transaction(resources, fun)
      id -> Step.transaction(resources, fn _locked -> fun.() end, lock: {id, scope})
    end
    |> case do
      {:ok, {:ok, :expired}} -> deliver_expired(resources, task, scope, job)
      {:ok, result} -> result
      {:error, :instance_gone} -> {:ok, :skipped}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fire_timer(_resources, _task, kind, _scope, _job) do
    {:error, "unknown timer kind: #{kind}"}
  end

  defp remind(resources, task, timer, scope, args) do
    already? =
      match?(%{status: :fired}, TimerLedger.own_row(resources, args, scope)) or
        fired?(resources, task, timer.key, scope)

    if already? do
      :already_fired
    else
      resources.process_event.create!(
        %{
          instance_id: task.instance_id,
          token_id: task.token_id,
          node_id: task.node_id,
          task_id: task.id,
          kind: :timer_fired,
          data: Map.merge(firing_data(args), %{"timer_kind" => "remind", "key" => timer.key})
        },
        Scope.engine(scope)
      )

      record_fire(resources, task, :remind, scope, args)
      arm_next_repetition(resources, task, scope, args)
      :reminded
    end
  end

  # A redelivery of a firing whose writes and notice both happened does nothing. One whose
  # delivery failed delivers again, under the same key; with no notifier, the first delivery
  # already recorded `:notice_undelivered`, and a redelivery does not record it twice.
  defp deliver_remind(resources, task, timer, scope, job, result) do
    if result == :already_fired and
         (is_nil(Config.task_notifier()) or
            Notices.delivered?(resources, task, timer.key, scope)) do
      {:ok, :already_fired}
    else
      case Notices.deliver(resources, task, :remind, timer, [], scope, job, notice_opts(job)) do
        :ok -> {:ok, :reminded}
        {:error, message} -> {:error, message}
      end
    end
  end

  # One repetition is armed at a time, by the firing of the one before (DESIGN.md §11.3). The
  # new job joins the task's timer ids, so completing the task cancels it like the rest.
  defp arm_next_repetition(resources, task, scope, %{"cycle" => _} = args) do
    case TimerLedger.arm_next(resources, {:task, task}, __MODULE__, args, scope) do
      nil ->
        :ok

      job_id ->
        task = reload_task(resources, task, scope)

        resources.human_task.attach_timers!(
          task,
          Enum.uniq((task.timer_job_ids || []) ++ [job_id]),
          Scope.engine(scope)
        )
    end
  end

  defp arm_next_repetition(_resources, _task, _scope, _args), do: :ok

  defp reload_task(resources, task, scope) do
    resources.human_task
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^task.id)
    |> Ash.read_one!(Scope.engine(scope))
  end

  # `task` is the row as it was before it expired: the assignee it had is who is told.
  defp deliver_expired(resources, task, scope, job) do
    timer = timer_info(resources, task, job.args, scope)

    case Notices.deliver(resources, task, :expired, timer, [], scope, job, notice_opts(job)) do
      :ok -> {:ok, :expired}
      {:error, message} -> {:error, message}
    end
  end

  defp resume_expired_notice(resources, task, scope, job) do
    timer = timer_info(resources, task, job.args, scope)

    if task.outcome == "expired" and not is_nil(Config.task_notifier()) and
         expired_by_timer?(resources, task, scope) and
         not Notices.delivered?(resources, task, timer.key, scope) do
      deliver_expired(resources, task, scope, job)
    else
      {:ok, :skipped}
    end
  end

  defp expired_by_timer?(resources, task, scope) do
    resources.process_event
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(task_id == ^task.id and kind == :task_expired)
    |> Ash.read!(Scope.engine(scope))
    |> Enum.any?()
  end

  defp expire(resources, task, scope, args) do
    # Force complete the task with :expired outcome
    resources.human_task.force_complete!(task, :expired, Scope.engine(scope))

    # Record the expiration event
    resources.process_event.create!(
      %{
        instance_id: task.instance_id,
        token_id: task.token_id,
        node_id: task.node_id,
        task_id: task.id,
        kind: :task_expired,
        data: firing_data(args)
      },
      Scope.engine(scope)
    )

    # And the firing itself, so a reader counting `:timer_fired` keys sees every timer that
    # fired, the expiry included (DESIGN.md §11.4).
    resources.process_event.create!(
      %{
        instance_id: task.instance_id,
        token_id: task.token_id,
        node_id: task.node_id,
        task_id: task.id,
        kind: :timer_fired,
        data: Map.merge(firing_data(args), %{"timer_kind" => "expire"})
      },
      Scope.engine(scope)
    )

    record_fire(resources, task, :expire, scope, args)

    # If this is a process task (has token_id), advance the token
    if task.token_id do
      token =
        resources.token
        |> Ash.Query.for_read(:read)
        |> Ash.Query.filter(id == ^task.token_id)
        |> Ash.read_one!(Scope.engine(scope))

      # Same wake-as-guard as the completion path: a timer firing on a task someone has just
      # completed must lose, and a status read cannot arbitrate that.
      case resources.token.claim_waiting(
             token,
             # Losing is ordinary here; it must not roll the expiry back with it.
             Keyword.put(Scope.engine(scope), :rollback_on_error?, false)
           ) do
        {:error, _} ->
          :ok

        {:ok, token} ->
          if task.instance_id do
            instance =
              resources.instance
              |> Ash.Query.for_read(:read)
              |> Ash.Query.filter(id == ^task.instance_id)
              |> Ash.read_one!(Scope.engine(scope))

            FlightView.token_moved(instance, token)

            definition =
              AshBpmn.DefinitionLoader.load!(
                resources.definition,
                instance.definition_id,
                instance,
                scope
              )

            graph = definition.graph

            # Expiry evaluates its conditions like any other transition out of the node.
            #
            # It used to take the first outgoing flow, on the reasoning that a timeout has no
            # outcome to route on. That was wrong twice over: `force_complete` writes
            # `outcome: :expired` onto the task, so `task.outcome = "expired"` is exactly the
            # condition a modeller writes for this; and taking "the first flow" out of a node
            # with two of them is the engine choosing a branch the diagram did not.
            #
            # `fallback: :single_unconditioned` is the same fallback the completion path uses,
            # so a task with one plain outgoing flow still expires down it without needing a
            # condition written for a case with only one answer.
            expr_ctx = %{
              "task" => %{"outcome" => "expired"},
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

            case expiry_flow(graph, task.node_id, expr_ctx) do
              [first_flow | _] ->
                next_node_id = first_flow["to"]

                # Consume the executing token and create a new one
                consumed = resources.token.consume!(token, Scope.engine(scope))
                FlightView.token_moved(instance, consumed)

                new_token =
                  resources.token.create!(
                    %{
                      instance_id: instance.id,
                      node_id: next_node_id,
                      status: :active
                    },
                    Scope.engine(scope)
                  )

                FlightView.token_moved(instance, new_token)

                # Enqueue advance for the new token
                AshBpmn.Runtime.Oban.insert(
                  AshBpmn.Runtime.AdvanceWorker,
                  Scope.to_job_args(scope, %{
                    "instance_id" => instance.id,
                    "token_id" => new_token.id,
                    "node_id" => next_node_id
                  })
                )

              [] ->
                :ok
            end
          end
      end
    end

    {:ok, :expired}
  end

  # ── escalation, the engine's half ─────────────────────────────────────────

  defp escalated(resources, task, principals, timer, scope, job, ctx) do
    fun = fn -> escalate_step(resources, task.id, principals, timer, scope, job.args) end

    case task.instance_id do
      nil -> Step.transaction(resources, fun)
      id -> Step.transaction(resources, fn _locked -> fun.() end, lock: {id, scope})
    end
    |> case do
      {:ok, {:added, current, added}} ->
        opts = Keyword.put(notice_opts(job), :instance, ctx.instance)

        case Notices.deliver(resources, current, :escalated, timer, added, scope, job, opts) do
          :ok -> {:ok, :escalated}
          {:error, message} -> {:error, message}
        end

      {:ok, :reached_nobody} ->
        {:ok, :escalation_reached_nobody}

      {:ok, :over} ->
        {:ok, :skipped}

      {:error, :instance_gone} ->
        {:ok, :skipped}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Inside the step. The task is re-read: a completion or cancel that won meanwhile ends the
  # escalation with nothing written. A retry of the same key finds its `:task_escalated` (or
  # `:escalation_reached_nobody`) already written and reuses it, so a replayed firing adds one
  # set of rows, not two.
  defp escalate_step(resources, task_id, principals, timer, scope, args) do
    task =
      resources.human_task
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(id == ^task_id)
      |> Ash.read_one!(Scope.engine(scope))

    cond do
      is_nil(task) or task.status in [:completed, :cancelled] ->
        :over

      previous = keyed_event(resources, task, :task_escalated, timer.key, scope) ->
        {:added, task, Enum.map(previous.data["added"] || [], &principal_from_data/1)}

      keyed_event(resources, task, :escalation_reached_nobody, timer.key, scope) ->
        :reached_nobody

      true ->
        add_candidates(resources, task, principals, timer, scope, args)
    end
  end

  defp add_candidates(resources, task, principals, timer, scope, args) do
    excluded = task.excluded_principal_ids || []
    requested = Enum.uniq_by(principals, &{&1.type, &1.id})
    {refused, remaining} = Enum.split_with(requested, &(&1.id in excluded))

    if remaining == [] do
      record_reached_nobody(resources, task, timer, scope, args, %{
        "requested" => length(requested),
        "refused" => Enum.map(refused, & &1.id)
      })

      :reached_nobody
    else
      existing = Notices.candidates(resources, task, scope)
      added = Enum.reject(remaining, &(&1 in existing))

      # In the task's tenant, whatever the job carried: a candidate row in another tenant
      # would be a person who cannot see the task they were given.
      tenant_scope = %{scope | tenant: Map.get(task, :organization_id) || scope.tenant}

      Enum.each(added, fn principal ->
        resources.task_candidate.create!(
          %{task_id: task.id, principal_type: principal.type, principal_id: principal.id},
          Scope.engine(tenant_scope)
        )
      end)

      record_task_event(resources, task, :task_escalated, scope, %{
        "key" => timer.key,
        "repetition" => timer.repetition,
        "added" => Enum.map(added, &principal_data/1),
        "already_candidates" => Enum.map(remaining -- added, & &1.id),
        "refused" => Enum.map(refused, & &1.id)
      })

      record_task_event(
        resources,
        task,
        :timer_fired,
        scope,
        Map.merge(firing_data(args), %{
          "timer_kind" => "escalate",
          "handler" => "resolver",
          "key" => timer.key
        })
      )

      record_fire(resources, task, :escalate, scope, args)

      {:added, task, added}
    end
  end

  defp record_reached_nobody(resources, task, timer, scope, args, extra) do
    record_task_event(
      resources,
      task,
      :escalation_reached_nobody,
      scope,
      Map.merge(
        %{
          "key" => timer.key,
          "timer_kind" => "escalate",
          "candidates" => length(Notices.candidates(resources, task, scope)),
          "excluded" => task.excluded_principal_ids || []
        },
        extra
      )
    )

    record_fire(resources, task, :escalate, scope, args)
  end

  # `{:ok, principals}` when the answer is a list of declared principals; `{:failed, message}`
  # for anything else, including the old contract's bare `:ok`.
  defp invoke_escalation(resolver, task, ctx) do
    case resolver.escalate(task, ctx) do
      {:ok, principals} when is_list(principals) ->
        if Enum.all?(principals, &principal?/1) do
          {:ok, principals}
        else
          {:failed,
           "escalate/2 returned principals of an undeclared shape: " <>
             inspect(principals, limit: 5)}
        end

      {:error, reason} ->
        {:failed, inspect(reason, limit: 5)}

      other ->
        {:failed,
         "escalate/2 returned an undeclared shape: #{inspect(other, limit: 5)}; " <>
           "it answers {:ok, [principal]} or {:error, reason}"}
    end
  rescue
    # Narrow by construction: this wraps the host's callback and nothing else, so what it
    # catches is a handler that blew up and never a failure of ours.
    e -> {:failed, Exception.message(e)}
  end

  defp principal?(%{type: type, id: id}) when type in [:user, :team] and is_binary(id), do: true
  defp principal?(_), do: false

  defp principal_data(%{type: type, id: id}), do: %{"type" => to_string(type), "id" => id}

  defp principal_from_data(%{"type" => "team", "id" => id}), do: %{type: :team, id: id}
  defp principal_from_data(%{"id" => id}), do: %{type: :user, id: id}

  defp keyed_event(resources, task, kind, key, scope) do
    resources.process_event
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(task_id == ^task.id and kind == ^kind)
    |> Ash.read!(Scope.engine(scope))
    |> Enum.find(&(&1.data["key"] == key))
  end

  defp fired?(resources, task, key, scope),
    do: keyed_event(resources, task, :timer_fired, key, scope) != nil

  defp record_task_event(resources, task, kind, scope, data) do
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
  end

  defp notice_opts(%Oban.Job{args: args}), do: [late: args["late"] == true]

  # Returns the chosen flow as a one-element list, or `[]` when nothing was selected -- the
  # shape the call site already handled.
  #
  # An expression that cannot answer is not survivable by guessing: raising sends the job back
  # to Oban, which is the same treatment the completion path gives it. A gateway that silently
  # picks a branch because a condition errored is the bug `Routing` was extracted to end, and
  # it would be no less a bug for happening on a timeout.
  defp expiry_flow(graph, node_id, expr_ctx) do
    case Routing.choose(graph, node_id, expr_ctx, fallback: :single_unconditioned) do
      {:error, reason} ->
        raise "routing from #{node_id} on expiry failed: #{reason}"

      {:ok, %{flow: nil}} ->
        []

      {:ok, %{flow: flow}} ->
        [flow]
    end
  end

  # What `escalate/2` is handed (DESIGN.md §11.6): the tenant to resolve in, the instance and
  # its subject (loaded with the node's `ash:load`, as a gateway at that node would see it), the
  # task's current candidates and its exclusions, and which timer fired.
  defp escalation_ctx(resources, task, scope, timer) do
    instance = load_instance(resources, task, scope)
    node = instance && node_config(resources, instance, task, scope)

    %{
      tenant: scope.tenant || Map.get(task, :organization_id),
      instance: instance,
      subject: AshBpmn.Subject.load(instance || task, scope, (node && node["load"]) || []),
      task: task,
      candidates: Notices.candidates(resources, task, scope),
      exclusions: task.excluded_principal_ids || [],
      timer: timer,
      actor: scope.actor,
      assigns: %{}
    }
  end

  # The firing's identity (DESIGN.md §11.4). "index" is the timer's position in its node's
  # `ash:timers`, carried in the job args since timers had keys. A job armed before then has
  # none: it is the first timer of its kind on the node, and an approval's escalation is its
  # first timer.
  defp timer_info(resources, task, args, scope) do
    kind = args["kind"]

    index =
      case args["index"] do
        index when is_integer(index) ->
          index

        _ ->
          instance = load_instance(resources, task, scope)
          node = instance && node_config(resources, instance, task, scope)
          legacy_index(node, kind)
      end

    repetition = args["repetition"] || 1

    %{
      kind: timer_kind(kind),
      index: index,
      repetition: repetition,
      # A job that carries its key was armed with it; one armed before keys is given the same
      # shape, `<task id>/<node id>/<timer index>/<repetition>`.
      key: args["key"] || "#{task.id}/#{task.node_id}/#{index}/#{repetition}"
    }
  end

  defp legacy_index(%{"timers" => timers}, kind) when is_list(timers),
    do: Enum.find_index(timers, &(&1["kind"] == kind)) || 0

  defp legacy_index(_node, _kind), do: 0

  defp timer_kind("remind"), do: :remind
  defp timer_kind("escalate"), do: :escalate
  defp timer_kind("expire"), do: :expire
  defp timer_kind(_), do: :unknown

  defp node_config(resources, instance, task, scope) do
    resources.definition
    |> AshBpmn.DefinitionLoader.load!(instance.definition_id, instance, scope)
    |> Map.get(:graph)
    |> get_in(["nodes", task.node_id])
  end

  defp load_instance(_resources, %{instance_id: nil}, _scope), do: nil

  defp load_instance(resources, task, scope) do
    resources.instance
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^task.instance_id)
    |> Ash.read_one!(Scope.engine(scope))
  end

  # Terminates the ledger row for a timer that has just fired.
  #
  # A job armed since §11 carries its row's id, and is recorded by it: a task may have two
  # timers of the same kind (two reminders, or the repetitions of one), and a lookup by kind
  # cannot tell them apart. A job armed before carries no id and is looked up by (task, kind),
  # earliest due first.
  #
  # Losing is ordinary: a redelivered worker finds the row already terminal, and the firing it
  # is re-running has already happened.
  defp record_fire(resources, task, kind, scope, args) do
    if resources.timer_job do
      row =
        case args["timer_job_id"] do
          # A job with a key but no row id names its row by the key; only a job from before
          # §11 has neither, and takes the earliest of its kind.
          nil ->
            resources.timer_job
            |> Ash.Query.for_read(:read)
            |> Ash.Query.filter(task_id == ^task.id and kind == ^kind and status == :scheduled)
            |> Ash.Query.sort(due_at: :asc)
            |> Ash.read!(Scope.engine(scope))
            |> Enum.find(&(is_nil(args["key"]) or &1.data["key"] == args["key"]))

          _id ->
            TimerLedger.own_row(resources, args, scope)
        end

      TimerLedger.record_fired(resources, row, scope)
    end

    :ok
  end
end
