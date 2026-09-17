# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.Runtime.BoundaryTimerWorker do
  @moduledoc """
  Fires an interrupting timer boundary event: cancels the activity and routes out through the
  boundary's own flow.

  Job args: `%{"instance_id" => id, "token_id" => id, "boundary_id" => binary,
  "attached_to" => binary}`.

  ## The order of operations is the whole design

  The task is cancelled **before** the token is claimed, and reversing those two loses human
  decisions.

  `AshBpmn.complete_task/2` writes `human_task.complete!` first and claims the token
  afterwards, so there is a window in which the task row says `:completed` and carries a
  `decided_by_id` while its token is still `:waiting`. A boundary that claimed the token first
  would win that window: it would route down the escalation path while a real approval, made
  by a real person, sat in the database unacted upon. Cancelling the task first means the
  boundary loses that race instead -- `:cancel` will not apply to a completed task -- which is
  the right way round, because a decision that was actually made should beat a deadline.

  The interrupted task is **cancelled, never force-completed**. `outcome` is what reporting
  and post-task FEEL conditions read, so inventing one for a task nobody decided makes an
  undecided task indistinguishable from a decided one.
  """

  use Oban.Worker, max_attempts: 3

  require Ash.Query

  alias AshBpmn.Config
  alias AshBpmn.Runtime.DomainResolver
  alias AshBpmn.Scope

  def queue, do: Config.queue()

  @impl true
  def perform(%Oban.Job{args: args}) do
    scope = Scope.from_job(args, :timer)
    resources = DomainResolver.resolve!(scope.domain)

    token =
      resources.token
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(id == ^args["token_id"])
      |> Ash.read_one!(Scope.engine(scope))

    cond do
      is_nil(token) ->
        {:cancel, :token_gone}

      # A dead or consumed token has no branch to run beside. The interrupting path finds this
      # out at the claim; the non-interrupting path never claims, so it has to ask.
      token.status not in [:waiting, :executing, :active] ->
        {:ok, :not_live}

      true ->
        interrupt(resources, token, args, scope)
    end
  end

  defp interrupt(resources, token, args, scope) do
    if args["interrupting"] == false do
      spawn_branch(resources, token, args, scope)
    else
      do_interrupt(resources, token, args, scope)
    end
  end

  # Non-interrupting: the activity keeps running and a *second* branch starts at the boundary.
  #
  # Nothing is claimed and nothing is cancelled, which is what makes it non-interrupting --
  # the attached token stays exactly as it was, parked on its approval, and the new token is
  # an ordinary live branch beside it. The instance now waits for both, which it could not do
  # until completion moved from the first branch to the last.
  #
  # `parent_token_id` records where the branch came from. There is no join that reunites them
  # and BPMN does not expect one: a non-interrupting branch runs to its own end.
  defp spawn_branch(resources, token, args, scope) do
    boundary_id = args["boundary_id"]

    resources.process_event.create!(
      record(resources, token, boundary_id, :activity_interrupted, %{
        "timer_kind" => "boundary",
        "interrupting" => false,
        "attached_to" => args["attached_to"]
      }),
      Scope.engine(scope)
    )

    new_token =
      resources.token.create!(
        %{
          instance_id: token.instance_id,
          node_id: boundary_id,
          status: :active,
          parent_token_id: token.id,
          routing: token.routing || %{}
        },
        Scope.engine(scope)
      )

    AshBpmn.Runtime.Oban.insert(
      AshBpmn.Runtime.AdvanceWorker,
      Scope.to_job_args(scope, %{
        "instance_id" => token.instance_id,
        "token_id" => new_token.id,
        "node_id" => boundary_id
      })
    )

    {:ok, :branch_started}
  end

  defp do_interrupt(resources, token, args, scope) do
    task = find_task(resources, token, args["attached_to"], scope)

    with :ok <- cancel_task(resources, task, scope),
         {:ok, token} <- resources.token.claim_waiting(token, Scope.engine(scope)) do
      route(resources, token, task, args, scope)
    else
      # Both losses are ordinary. `:lost_to_completion` means somebody decided the task
      # between this job being promoted and this line running; `:not_waiting` means the
      # branch was already pruned by a terminate, a cancel, or a redelivery of this job.
      {:error, :task_not_cancellable} -> {:ok, :lost_to_completion}
      {:error, _} -> {:ok, :not_waiting}
    end
  end

  defp find_task(resources, token, attached_to, scope) do
    resources.human_task
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(token_id == ^token.id and node_id == ^attached_to)
    |> Ash.read!(Scope.engine(scope))
    |> List.first()
  end

  # A boundary on a user task with no task row is not a shape the compiler allows, but a
  # definition published by an older version could produce one. Nothing to cancel is not a
  # reason to refuse to interrupt.
  defp cancel_task(_resources, nil, _scope), do: :ok

  defp cancel_task(resources, task, scope) do
    case resources.human_task.cancel(task, Scope.engine(scope)) do
      {:ok, _} -> :ok
      {:error, _} -> {:error, :task_not_cancellable}
    end
  end

  defp route(resources, token, task, args, scope) do
    boundary_id = args["boundary_id"]

    # The task's own remind and escalate timers are now pointless -- there is nobody left to
    # remind about a task that no longer exists. Cancelled by owner through the meta index
    # rather than by job id, because the ids live on the task row and the task may not have
    # been reloaded since they were attached.
    AshBpmn.Runtime.Oban.cancel_all(%{"token_id" => token.id})

    if task do
      record(resources, token, task.node_id, :task_cancelled, %{
        "reason" => "boundary_event",
        "boundary_id" => boundary_id
      })
      |> then(&resources.process_event.create!(&1, Scope.engine(scope)))
    end

    resources.process_event.create!(
      record(resources, token, boundary_id, :activity_interrupted, %{
        "timer_kind" => "boundary",
        "interrupted" => args["attached_to"]
      }),
      Scope.engine(scope)
    )

    resources.token.consume!(token, Scope.engine(scope))

    new_token =
      resources.token.create!(
        %{
          instance_id: token.instance_id,
          node_id: boundary_id,
          status: :active,
          routing: token.routing || %{}
        },
        Scope.engine(scope)
      )

    AshBpmn.Runtime.Oban.insert(
      AshBpmn.Runtime.AdvanceWorker,
      Scope.to_job_args(scope, %{
        "instance_id" => token.instance_id,
        "token_id" => new_token.id,
        "node_id" => boundary_id
      })
    )

    {:ok, :interrupted}
  end

  defp record(_resources, token, node_id, kind, data) do
    %{
      instance_id: token.instance_id,
      token_id: token.id,
      node_id: node_id,
      kind: kind,
      data: data
    }
  end
end
