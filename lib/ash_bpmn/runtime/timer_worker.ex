# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.Runtime.TimerWorker do
  @moduledoc """
  Oban worker that fires task timers (remind, escalate, expire).

  Job args: `%{"task_id" => id, "kind" => "remind" | "escalate" | "expire"}`

  - `remind` — records :timer_fired event
  - `escalate` — calls resolver.escalate/2 + records event
  - `expire` — force-completes task with :expired outcome, advances token
  """

  use Oban.Worker, max_attempts: 3

  require Ash.Query

  alias AshBpmn.Config
  alias AshBpmn.FlightView
  alias AshBpmn.Runtime.DomainResolver
  alias AshBpmn.Runtime.Routing
  alias AshBpmn.Scope

  def queue, do: Config.queue()

  @impl true
  def perform(%Oban.Job{args: args}) do
    task_id = args["task_id"]
    kind = args["kind"]

    scope = Scope.from_job(args, :timer)
    resources = DomainResolver.resolve!(scope.domain)

    # Load the task
    task =
      resources.human_task
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(id == ^task_id)
      |> Ash.read_one!(Scope.engine(scope))

    # Skip if already completed or cancelled
    if task.status in [:completed, :cancelled] do
      {:ok, :skipped}
    else
      fire_timer(resources, task, kind, scope, args)
    end
  end

  defp fire_timer(resources, task, "remind", scope, _args) do
    resources.process_event.create!(
      %{
        instance_id: task.instance_id,
        token_id: task.token_id,
        node_id: task.node_id,
        task_id: task.id,
        kind: :timer_fired,
        data: %{"timer_kind" => "remind"}
      },
      Scope.engine(scope)
    )

    record_fire(resources, task, :remind, scope)

    {:ok, :reminded}
  end

  # Escalation had a clause-level `rescue _ -> {:ok, :escalated}`, which reported success for
  # every possible failure. That was not a hypothetical: `escalate/2` is an optional callback
  # and this repository's own test resolver does not implement it, so every escalation in the
  # suite raised `UndefinedFunctionError`, was swallowed, and wrote no event -- while the test
  # named "escalation timer fires" passed, because all it asserted was that the task was still
  # open, which is true precisely when nothing happens.
  #
  # Three outcomes, told apart without a rescue where possible:
  #
  #   * the host did not implement the optional callback -- a configuration fact, not a
  #     failure, and detectable with `function_exported?/3` rather than by raising;
  #   * the handler ran;
  #   * the handler failed.
  #
  # Only the third is an error, and it is a *survivable* one: escalation is a notification and
  # never touches task state, so the process carries on regardless. It returns `{:error, _}`
  # so Oban retries the notification -- which is the whole point of having armed it -- and the
  # append-only log gets one row per attempt, which is a fair record of three attempts rather
  # than a duplicate.
  # An escalation that names a signal throws it instead of calling the resolver.
  #
  # That is the difference between notifying somebody and starting something: a resolver's
  # `escalate/2` reaches a person through whatever the host wired up, and a signal reaches
  # every process listening for that name. A modeller who wants the second should not have to
  # ask an Elixir developer for it.
  defp fire_timer(resources, task, "escalate", scope, %{"signal" => name})
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
        record_escalation(resources, task, {:signal, name}, scope)
        record_fire(resources, task, :escalate, scope)
        {:ok, :escalated}

      {:error, reason} ->
        record_escalation(resources, task, {:failed, inspect(reason)}, scope)
        record_fire(resources, task, :escalate, scope)
        {:error, inspect(reason)}
    end
  end

  defp fire_timer(resources, task, "escalate", scope, _args) do
    resolver = Config.assignment_resolver!()

    ctx = %{
      task: task,
      instance: nil,
      subject: nil,
      actor: scope.actor,
      assigns: %{}
    }

    outcome = invoke_escalation(resolver, task, ctx)

    # Outside any rescue, and unconditional. The old code wrapped this write too, so a failure
    # to record the escalation also reported success -- strictly worse than the handler case,
    # because the row that would let anyone notice is the thing that went missing.
    record_escalation(resources, task, outcome, scope)
    record_fire(resources, task, :escalate, scope)

    case outcome do
      :ok -> {:ok, :escalated}
      :no_handler -> {:ok, :no_escalation_handler}
      {:failed, message} -> {:error, message}
    end
  end

  defp fire_timer(resources, task, "expire", scope, _args) do
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
        data: %{}
      },
      Scope.engine(scope)
    )

    record_fire(resources, task, :expire, scope)

    # If this is a process task (has token_id), advance the token
    if task.token_id do
      token =
        resources.token
        |> Ash.Query.for_read(:read)
        |> Ash.Query.filter(id == ^task.token_id)
        |> Ash.read_one!(Scope.engine(scope))

      # Same wake-as-guard as the completion path: a timer firing on a task someone has just
      # completed must lose, and a status read cannot arbitrate that.
      case resources.token.claim_waiting(token, Scope.engine(scope)) do
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

  defp fire_timer(_resources, _task, kind, _scope, _args) do
    {:error, "unknown timer kind: #{kind}"}
  end

  defp invoke_escalation(resolver, task, ctx) do
    if Code.ensure_loaded?(resolver) and function_exported?(resolver, :escalate, 2) do
      case resolver.escalate(task, ctx) do
        :ok -> :ok
        {:ok, _} -> :ok
        {:error, reason} -> {:failed, inspect(reason)}
        other -> {:failed, "escalate/2 returned an undeclared shape: #{inspect(other)}"}
      end
    else
      :no_handler
    end
  rescue
    # Narrow by construction: this wraps the host's callback and nothing else, so what it
    # catches is a handler that blew up and never a failure of ours.
    e -> {:failed, Exception.message(e)}
  end

  defp record_escalation(resources, task, outcome, scope) do
    {kind, data} =
      case outcome do
        :ok ->
          {:timer_fired, %{"timer_kind" => "escalate", "handler" => "resolver"}}

        {:signal, name} ->
          {:timer_fired,
           %{"timer_kind" => "escalate", "handler" => "signal", "signal_name" => name}}

        :no_handler ->
          {:timer_fired, %{"timer_kind" => "escalate", "handler" => "none"}}

        {:failed, msg} ->
          {:escalation_failed, %{"timer_kind" => "escalate", "error" => msg}}
      end

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

  # Terminates the ledger row for a timer that has just fired.
  #
  # Looked up by (task, kind, scheduled) rather than carried in the job args, because the
  # args predate the ledger and a job armed before this shipped still has to be recordable.
  #
  # Non-bang, and losing is ordinary: a redelivered worker finds the row already terminal,
  # and the firing it is re-running has already happened. A retry that cannot re-record its
  # own firing must still be allowed to complete, or Oban retries it until max_attempts over
  # a bookkeeping write.
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

  defp load_instance(_resources, %{instance_id: nil}, _scope), do: nil

  defp load_instance(resources, task, scope) do
    resources.instance
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^task.instance_id)
    |> Ash.read_one!(Scope.engine(scope))
  end

  defp record_fire(resources, task, kind, scope) do
    if resources.timer_job do
      row =
        resources.timer_job
        |> Ash.Query.for_read(:read)
        |> Ash.Query.filter(task_id == ^task.id and kind == ^kind and status == :scheduled)
        |> Ash.read_one!(Scope.engine(scope))

      row && resources.timer_job.record_fired(row, Scope.engine(scope))
    end

    :ok
  end
end
