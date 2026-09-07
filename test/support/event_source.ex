# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.Test.EventSource do
  @moduledoc """
  Behaviour-conformant test double for `AshBpmn.EventSource`.

  There is no log behind it: `stream/3` walks a fixed list of synthetic events, so the
  cursor protocol can be exercised without Postgres or ash_events. The ordering guarantee
  follows the rule the reference adapter will implement — real tenants are `:commit_order`,
  the NULL-tenant chain is `:best_effort` — so tests can pin both branches.
  """

  @behaviour AshBpmn.EventSource

  @occurred_at ~U[2026-09-07 12:00:00Z]

  @audited [AshBpmn.Test.CallablesResource]

  @events [
    %{
      id: "evt-1",
      sequence: 1,
      occurred_at: @occurred_at,
      resource: "payout",
      action: :approve,
      action_type: :destroy,
      record_id: "rec-1",
      version: 1,
      actor: %{id: "user-1"},
      tenant: "org-1",
      data: %{amount: 500},
      changed: %{amount: {400, 500}},
      metadata: %{}
    },
    %{
      id: "evt-2",
      sequence: 2,
      occurred_at: @occurred_at,
      resource: "payout",
      action: :reject,
      action_type: :update,
      record_id: "rec-2",
      version: 3,
      actor: nil,
      tenant: "org-1",
      data: %{amount: 10},
      changed: %{},
      metadata: %{"source" => "test"}
    }
  ]

  @impl true
  def stream(_tenant, after_sequence, limit) do
    events =
      @events
      |> Enum.filter(&(&1.sequence > after_sequence))
      |> Enum.sort_by(& &1.sequence)
      |> Enum.take(limit)

    last_sequence =
      case Enum.reverse(events) do
        [] -> nil
        [last | _] -> last.sequence
      end

    {:ok, {events, last_sequence}}
  end

  @impl true
  def context(event) do
    %{
      "event" => %{
        "id" => event.id,
        "sequence" => event.sequence,
        "occurred_at" => event.occurred_at,
        "resource" => event.resource,
        "action" => to_string(event.action),
        "action_type" => to_string(event.action_type),
        "record_id" => event.record_id,
        "version" => event.version
      },
      "actor" => event.actor,
      "tenant" => event.tenant,
      "data" => event.data,
      "changed" => event.changed,
      "metadata" => event.metadata
    }
  end

  @impl true
  def sequence(event), do: event.sequence

  @impl true
  def occurred_at(event), do: event.occurred_at

  @impl true
  def order_guarantee(nil), do: :best_effort
  def order_guarantee(_tenant), do: :commit_order

  @impl true
  def audited?(resource), do: resource in @audited
end
