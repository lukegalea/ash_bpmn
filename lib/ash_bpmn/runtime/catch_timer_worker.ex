# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.Runtime.CatchTimerWorker do
  @moduledoc """
  Wakes a token parked on an intermediate timer catch event.

  Job args: `%{"instance_id" => id, "token_id" => id, "node_id" => binary}`.

  ## Why Oban does the waiting and this module does almost nothing

  Everything about scheduling the wake -- holding it durably across restarts, firing it at the
  right time, retrying it if the node dies mid-wake, not firing it twice -- is Oban's, and none
  of it is reimplemented here. `Oban.Stager` promotes the job when `scheduled_at` arrives, and
  it never promotes early. A week-long wait is a row in `oban_jobs`, which is the point: an
  in-memory timer is a wait that a deploy silently cancels.

  What is left for this worker is the part Oban has no opinion about: the token is claimed out
  of `:waiting`, and if that claim loses -- someone cancelled the instance, a terminate end
  event killed the branch, or this job is a redelivery of one that already ran -- the wake is
  simply over. Losing is the normal way for this worker to end and is not an error.
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
    scope = Scope.from_job(args, :timer)
    resources = DomainResolver.resolve!(scope.domain)

    token =
      resources.token
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(id == ^args["token_id"])
      |> Ash.read_one!(Scope.engine(scope))

    if is_nil(token) do
      # The instance was hard-deleted under us. Nothing to wake and nothing to complain about;
      # cancelling stops Oban retrying something that cannot become true.
      {:cancel, :token_gone}
    else
      case resources.token.claim_waiting(token, Scope.engine(scope)) do
        {:error, _} ->
          # Killed, cancelled, or already woken. All three are ordinary.
          {:ok, :not_waiting}

        {:ok, token} ->
          advance(resources, token, args["node_id"], scope)
      end
    end
  end

  defp advance(resources, token, node_id, scope) do
    instance =
      resources.instance
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(id == ^token.instance_id)
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

    resources.process_event.create!(
      %{
        instance_id: instance.id,
        token_id: token.id,
        node_id: node_id,
        kind: :timer_fired,
        data: %{"timer_kind" => "catch"}
      },
      Scope.engine(scope)
    )

    # Terminate the ledger row, looked up by the token rather than by a task -- a catch timer
    # has no task. This runs only on the winning claim path, which is right: a losing claim
    # did not fire anything, and its row is cancelled by whoever pruned the branch.
    #
    # Non-bang, for the same reason as the task timers: the wake has already happened, and a
    # failed bookkeeping write must not fail the job and send it round again.
    if resources.timer_job do
      row =
        resources.timer_job
        |> Ash.Query.for_read(:read)
        |> Ash.Query.filter(token_id == ^token.id and kind == :catch and status == :scheduled)
        |> Ash.read_one!(Scope.engine(scope))

      row && resources.timer_job.record_fired(row, Scope.engine(scope))
    end

    # A catch event has exactly one way out -- it is a point on a path, not a decision -- so
    # this is `:none` rather than the router's condition evaluation. A catch event with two
    # outgoing flows is an implicit gateway, and the compiler's business, not this worker's.
    case Routing.outgoing(graph, node_id) do
      [flow | _] ->
        consumed = resources.token.consume!(token, Scope.engine(scope))
        FlightView.token_moved(instance, consumed)

        new_token =
          resources.token.create!(
            %{
              instance_id: instance.id,
              node_id: flow["to"],
              status: :active,
              routing: token.routing || %{}
            },
            Scope.engine(scope)
          )

        FlightView.token_moved(instance, new_token)

        AshBpmn.Runtime.Oban.insert(
          AshBpmn.Runtime.AdvanceWorker,
          Scope.to_job_args(scope, %{
            "instance_id" => instance.id,
            "token_id" => new_token.id,
            "node_id" => flow["to"]
          })
        )

        {:ok, :fired}

      [] ->
        # The compiler refuses this shape, so reaching it means a definition published by an
        # older version. The token is consumed rather than left waiting for a wake that has
        # already happened.
        resources.token.consume!(token, Scope.engine(scope))
        {:ok, :dead_end}
    end
  end
end
