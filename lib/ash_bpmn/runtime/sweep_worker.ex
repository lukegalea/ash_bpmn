# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.Runtime.SweepWorker do
  @moduledoc """
  Oban worker that recovers stuck tokens.

  Finds running instances whose :active tokens have no live Oban job
  and re-enqueues advance workers for them. Idempotent by claim gate.

  In production, queries `oban_jobs` table. In inline test mode, re-enqueues
  all active tokens directly (idempotent by claim).
  """

  use Oban.Worker, max_attempts: 1

  require Ash.Query

  alias AshBpmn.Config
  alias AshBpmn.Scope

  def queue, do: Config.queue()

  @impl true
  def perform(_job) do
    resources = AshBpmn.Runtime.DomainResolver.resolve!()

    # The sweep is deliberately cross-tenant: it recovers work stranded by a
    # restart, and a restart does not respect tenant boundaries. The resource
    # macros declare `global? true`, so this read is legal without a tenant --
    # and each instance's own scope is picked up below, so every *write* the
    # sweep makes lands in the right tenant.
    scope = Scope.system(:sweep)

    # Find all running instances
    running_instances =
      resources.instance
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(status == :running)
      |> Ash.read!(Scope.engine(scope))

    Enum.each(running_instances, fn instance ->
      sweep_instance(resources, instance, Scope.from_record(instance, actor: scope.actor))
    end)

    {:ok, :swept}
  end

  defp sweep_instance(resources, instance, scope) do
    # Find active tokens for this instance
    active_tokens =
      resources.token
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(instance_id == ^instance.id)
      |> Ash.Query.filter(status == :active)
      |> Ash.read!(Scope.engine(scope))

    Enum.each(active_tokens, fn token ->
      re_enqueue_token(resources, token, instance, scope)
    end)
  end

  defp re_enqueue_token(resources, token, instance, scope) do
    # Record sweep recovery event
    resources.process_event.create!(
      %{
        instance_id: instance.id,
        token_id: token.id,
        node_id: token.node_id,
        kind: :sweep_recovered,
        data: %{}
      },
      Scope.engine(scope)
    )

    # Re-enqueue advance
    AshBpmn.Runtime.Oban.insert(
      AshBpmn.Runtime.AdvanceWorker,
      Scope.to_job_args(scope, %{
        "instance_id" => instance.id,
        "token_id" => token.id,
        "node_id" => token.node_id
      })
    )
  end
end
