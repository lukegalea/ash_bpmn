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

  def queue, do: Config.queue()

  @impl true
  def perform(%Oban.Job{args: args}) do
    task_id = args["task_id"]
    kind = args["kind"]

    resources = DomainResolver.resolve!()

    # Load the task
    task =
      resources.human_task
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(id == ^task_id)
      |> Ash.read_one!(authorize?: false)

    # Skip if already completed or cancelled
    if task.status in [:completed, :cancelled] do
      {:ok, :skipped}
    else
      fire_timer(resources, task, kind)
    end
  end

  defp fire_timer(resources, task, "remind") do
    resources.process_event.create!(
      %{
        instance_id: task.instance_id,
        token_id: task.token_id,
        node_id: task.node_id,
        task_id: task.id,
        kind: :timer_fired,
        data: %{"timer_kind" => "remind"}
      },
      authorize?: false
    )

    {:ok, :reminded}
  end

  defp fire_timer(resources, task, "escalate") do
    resolver = Config.assignment_resolver!()

    ctx = %{
      task: task,
      instance: nil,
      subject: nil,
      actor: nil,
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
      authorize?: false
    )

    {:ok, :escalated}
  rescue
    _ -> {:ok, :escalated}
  end

  defp fire_timer(resources, task, "expire") do
    # Force complete the task with :expired outcome
    resources.human_task.force_complete!(task, :expired, authorize?: false)

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
      authorize?: false
    )

    # If this is a process task (has token_id), advance the token
    if task.token_id do
      token =
        resources.token
        |> Ash.Query.for_read(:read)
        |> Ash.Query.filter(id == ^task.token_id)
        |> Ash.read_one!(authorize?: false)

      if token.status == :executing do
        if task.instance_id do
          instance =
            resources.instance
            |> Ash.Query.for_read(:read)
            |> Ash.Query.filter(id == ^task.instance_id)
            |> Ash.read_one!(authorize?: false)

          definition =
            resources.definition
            |> Ash.Query.for_read(:read)
            |> Ash.Query.filter(id == ^instance.definition_id)
            |> Ash.read_one!(authorize?: false)

          graph = definition.graph

          # Find outgoing flows from the task's node
          outgoing =
            graph["flows"]
            |> Map.values()
            |> Enum.filter(fn flow -> flow["from"] == task.node_id end)

          # Follow first outgoing flow (for expiry, typically default path)
          case outgoing do
            [first_flow | _] ->
              next_node_id = first_flow["to"]

              # Consume the executing token and create a new one
              resources.token.consume!(token, authorize?: false)

              new_token =
                resources.token.create!(
                  %{
                    instance_id: instance.id,
                    node_id: next_node_id,
                    status: :active
                  },
                  authorize?: false
                )

              # Enqueue advance for the new token
              AshBpmn.Runtime.Oban.insert(AshBpmn.Runtime.AdvanceWorker, %{
                "instance_id" => instance.id,
                "token_id" => new_token.id,
                "node_id" => next_node_id
              })

            [] ->
              :ok
          end
        end
      end
    end

    {:ok, :expired}
  end

  defp fire_timer(_resources, _task, kind) do
    {:error, "unknown timer kind: #{kind}"}
  end
end
