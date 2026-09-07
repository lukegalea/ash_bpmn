# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

# Test doubles and fixtures for the triggers extension resources
# (`Subscription`, `Cursor`, `Dispatch`).
#
# The `TriggerTest.Payout` and `TriggerTest.Unaudited` fixtures are
# deliberately **not** under the `AshBpmn.*` namespace: the subscription's
# publish-time cycle invariant refuses any `match_resource` under `AshBpmn.`
# or `AshDecisions.`, so a fixture used to prove the audited-resource check
# *passes* must live outside the refused prefixes. (`AshBpmn.TenantTest.Dispatch`
# is audited-by-fiat in the double below for the mirror reason: the
# signal-exception test needs a resource that is both audited and cyclic, so
# the cycle check — not the audit check — is what the assertion exercises.)

defmodule TriggerTest.Payout do
  @moduledoc "An audited stand-in for a host resource a subscription could watch."

  use Ash.Resource, domain: nil, data_layer: Ash.DataLayer.Ets

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id

    attribute :amount, :integer do
      default 0
      public? true
    end
  end

  actions do
    defaults [:create, :read, :update, :destroy]
  end
end

defmodule TriggerTest.Unaudited do
  @moduledoc "Exists and is loadable, and writes no events -- the silent-never-fires case."

  use Ash.Resource, domain: nil, data_layer: Ash.DataLayer.Ets

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id
  end

  actions do
    defaults [:create, :read]
  end
end

defmodule TriggerTest.Event do
  @moduledoc """
  A synthetic event-log row for the sweep double.

  Deliberately its own shape (not an `ash_events` row): the library only ever
  sees adapter events opaquely, through `TriggerTest.EventSource`, which is
  exactly the seam a host adapter sits behind.
  """

  defstruct [
    :id,
    :sequence,
    :tenant,
    :resource,
    :action,
    :action_type,
    :record_id,
    :occurred_at,
    :data,
    :metadata
  ]
end

defmodule TriggerTest.EventSource do
  @moduledoc """
  An in-memory `AshBpmn.EventSource` double.

  For the publish-time checks only `audited?/1` carries state that matters. For
  the sweep it is a small log: tests append events per tenant
  (`append!/2`), the worker streams them back in sequence order through the
  behaviour contract, and `context/1` builds the published contract the
  reference adapter builds.

  Two test aids ride along, both driven through ETS so the inline sweep (which
  runs in the test process anyway) sees them:

    * `context_calls/0` counts `context/1` builds — the funnel's boundary step,
      and therefore the cheapest observable for "the zero-hit short-circuit
      did no work".
    * `poison_context!/1` makes `context/1` raise for one event — the shape of
      an adapter blowing up mid-batch, which the sweep must survive without
      wedging.
  """

  @behaviour AshBpmn.EventSource

  @log :trigger_test_event_log
  @counters :trigger_test_event_source_counters

  # `Dispatch` is audited by fiat, so the signal-exception test can prove the
  # *cycle* check is what passes for it, not the audit check. See the file
  # comment above.
  @audited [TriggerTest.Payout, AshBpmn.TenantTest.Dispatch]

  ## The log

  def reset! do
    ensure_tables()
    :ets.delete_all_objects(@log)
    :ets.delete_all_objects(@counters)
    :ok
  end

  @doc """
  Appends one event to the log. `overrides` fills the struct; sensible
  defaults for everything else (including a per-tenant sequence and a fresh
  `record_id`).
  """
  def append!(tenant, overrides \\ %{}) do
    ensure_tables()

    event =
      struct!(
        TriggerTest.Event,
        Map.merge(
          %{
            id: Ash.UUID.generate(),
            resource: TriggerTest.Payout,
            action: :approve,
            action_type: :create,
            record_id: Ash.UUID.generate(),
            occurred_at: DateTime.utc_now(),
            data: %{},
            metadata: %{}
          },
          Map.put(overrides, :tenant, tenant)
        )
      )

    sequence = next_sequence(tenant)
    event = %{event | sequence: sequence}
    :ets.insert(@log, {{tenant, sequence}, event})
    event
  end

  @doc "Whether the context for this event would raise (see `poison_context!/1`)."
  def poisoned?(event), do: flag({:poison, event.id})

  @doc "Makes `context/1` raise for `event` — an adapter blowing up mid-batch."
  def poison_context!(event), do: set_flag({:poison, event.id})

  @doc "How many times `context/1` has built a context since the last `reset!/0`."
  def context_calls, do: counter(:context_calls)

  ## The behaviour

  @impl true
  def stream(tenant, after_sequence, limit) do
    ensure_tables()

    events =
      @log
      |> :ets.tab2list()
      |> Enum.flat_map(fn {{t, _seq}, event} -> if t == tenant, do: [event], else: [] end)
      |> Enum.filter(&(&1.sequence > after_sequence))
      |> Enum.sort_by(& &1.sequence)
      |> Enum.take(limit)

    {:ok, {events, last_sequence(events)}}
  end

  @impl true
  def context(event) do
    bump(:context_calls)

    if poisoned?(event) do
      raise "poisoned context for event #{event.id}"
    end

    %{
      "event" => %{
        "id" => event.id,
        "sequence" => event.sequence,
        "occurred_at" => event.occurred_at,
        # The short name, so a guard reads `event.resource = "TriggerTest.Payout"`
        # rather than carrying the `Elixir.` prefix into a business rule.
        "resource" => AshBpmn.Resources.Subscription.ResourceName.canonical(event.resource),
        "action" => to_string(event.action),
        "action_type" => to_string(event.action_type),
        "record_id" => event.record_id,
        "version" => 1
      },
      "actor" => %{
        "user_id" => event.metadata["user_id"],
        "system_actor" => event.metadata["system_actor"]
      },
      "tenant" => %{"organization_id" => event.tenant},
      "data" => event.data || %{},
      "changed" => %{},
      "metadata" => event.metadata || %{}
    }
  end

  @impl true
  def sequence(event), do: event.sequence

  @impl true
  def occurred_at(event), do: event.occurred_at

  @impl true
  def order_guarantee(_tenant), do: :commit_order

  @impl true
  def audited?(resource), do: resource in @audited

  ## Internals

  defp ensure_tables do
    unless :ets.whereis(@log) != :undefined do
      :ets.new(@log, [:named_table, :public, :set, read_concurrency: true])
    end

    unless :ets.whereis(@counters) != :undefined do
      :ets.new(@counters, [:named_table, :public, :set])
    end

    :ok
  end

  # Sequences are per tenant: the ordering guarantee the cursor relies on is
  # per tenant, so the double hands out each tenant's chain independently.
  defp next_sequence(tenant) do
    :ets.update_counter(@counters, {:sequence, tenant}, 1, {{:sequence, tenant}, 0})
  end

  defp last_sequence([]), do: nil
  defp last_sequence(events), do: List.last(events).sequence

  defp counter(key) do
    ensure_tables()

    case :ets.lookup(@counters, key) do
      [{^key, n}] -> n
      [] -> 0
    end
  end

  defp bump(key), do: :ets.update_counter(@counters, key, 1, {key, 0})

  defp flag(key) do
    ensure_tables()

    case :ets.lookup(@counters, key) do
      [{^key, true}] -> true
      [] -> false
    end
  end

  defp set_flag(key), do: (ensure_tables() && :ets.insert(@counters, {key, true})) || :ok
end

defmodule TriggerTest.DecisionResolver do
  @moduledoc """
  A decision resolver double whose `exists?/1` and `decide/3` answers the test
  flips.

  Publish-time decision verification only ever calls `exists?/1`; the
  correlator calls `decide/3` when routing through a decision. Both answers
  live in persistent terms the test sets per case.
  """

  @behaviour AshBpmn.DecisionResolver

  @impl true
  def decide(ref, inputs, context) do
    case :persistent_term.get({__MODULE__, :decide}, :default) do
      :default -> {:ok, %{outputs: %{}}}
      fun when is_function(fun, 3) -> fun.(ref, inputs, context)
      result -> result
    end
  end

  @impl true
  def exists?(_ref), do: :persistent_term.get({__MODULE__, :exists?}, true)

  def set_exists?(value), do: :persistent_term.put({__MODULE__, :exists?}, value)

  @doc """
  Sets the `decide/3` answer: `:default`, a `{:ok, _} | {:error, _}` result, or
  a three-arity function of `(ref, inputs, context)`.
  """
  def set_decide(value), do: :persistent_term.put({__MODULE__, :decide}, value)
end
