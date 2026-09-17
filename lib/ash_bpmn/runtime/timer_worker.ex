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
      fire_timer(resources, task, kind, scope)
    end
  end

  defp fire_timer(resources, task, "remind", scope) do
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

    {:ok, :reminded}
  end

  defp fire_timer(resources, task, "escalate", scope) do
    resolver = Config.assignment_resolver!()

    ctx = %{
      task: task,
      instance: nil,
      subject: nil,
      actor: scope.actor,
      assigns: %{}
    }

    _ = resolver.escalate(task, ctx)

    resources.process_event.create!(
      %{
        instance_id: task.instance_id,
        token_id: task.token_id,
        node_id: task.node_id,
        task_id: task.id,
        kind: :timer_fired,
        data: %{"timer_kind" => "escalate"}
      },
      Scope.engine(scope)
    )

    {:ok, :escalated}
  rescue
    _ -> {:ok, :escalated}
  end

  defp fire_timer(resources, task, "expire", scope) do
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

            definition =
              AshBpmn.DefinitionLoader.load!(
                resources.definition,
                instance.definition_id,
                instance,
                scope
              )

            graph = definition.graph

            # Through the shared router, which injects the flow id and sorts by it. The local
            # version filtered `Map.values(graph["flows"])` -- flows with no `"id"`, in whatever
            # order the map happened to yield -- and called the head of that "typically the
            # default path". It is not: it is an arbitrary branch, stable only by luck, and a
            # task with two outgoing flows expired down a different one depending on the map.
            case Routing.outgoing(graph, task.node_id) do
              [first_flow | _] ->
                # Still the first flow, not an evaluated one: expiry is a timeout, and a
                # timeout has no task outcome to route on. Now at least "first" means the
                # lowest flow id rather than a map's internal order.
                next_node_id = first_flow["to"]

                # Consume the executing token and create a new one
                resources.token.consume!(token, Scope.engine(scope))

                new_token =
                  resources.token.create!(
                    %{
                      instance_id: instance.id,
                      node_id: next_node_id,
                      status: :active
                    },
                    Scope.engine(scope)
                  )

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

  defp fire_timer(_resources, _task, kind, _scope) do
    {:error, "unknown timer kind: #{kind}"}
  end
end
