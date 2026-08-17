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

  def queue, do: Config.queue()

  @impl true
  def perform(_job) do
    resources = AshBpmn.Runtime.DomainResolver.resolve!()

    # Find all running instances
    running_instances =
      resources.instance
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(status == :running)
      |> Ash.read!(authorize?: false)

    Enum.each(running_instances, fn instance ->
      sweep_instance(resources, instance)
    end)

    {:ok, :swept}
  end

  defp sweep_instance(resources, instance) do
    # Find active tokens for this instance
    active_tokens =
      resources.token
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(instance_id == ^instance.id)
      |> Ash.Query.filter(status == :active)
      |> Ash.read!(authorize?: false)

    Enum.each(active_tokens, fn token ->
      re_enqueue_token(resources, token, instance)
    end)
  end

  defp re_enqueue_token(resources, token, instance) do
    # Record sweep recovery event
    resources.process_event.create!(
      %{
        instance_id: instance.id,
        token_id: token.id,
        node_id: token.node_id,
        kind: :sweep_recovered,
        data: %{}
      },
      authorize?: false
    )

    # Re-enqueue advance
    AshBpmn.Runtime.Oban.insert(AshBpmn.Runtime.AdvanceWorker, %{
      "instance_id" => instance.id,
      "token_id" => token.id,
      "node_id" => token.node_id
    })
  end
end
