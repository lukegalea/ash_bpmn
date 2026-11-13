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

  @doc "Every event in `tenant`'s log, in sequence order."
  def all(tenant) do
    {:ok, {events, _}} = stream(tenant, 0, 1_000_000)
    events
  end

  @doc "Forgets one event, the shape of a log that no longer has it."
  def forget!(event) do
    ensure_tables()
    :ets.delete(@log, {event.tenant, event.sequence})
    :ok
  end

  @doc "The newest sequence appended to `tenant`'s log, `0` when it has none."
  def newest(tenant) do
    ensure_tables()

    case :ets.lookup(@counters, {:sequence, tenant}) do
      [{_key, n}] -> n
      [] -> 0
    end
  end

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

  defp set_flag(key) do
    ensure_tables()
    :ets.insert(@counters, {key, true})
  end
end

defmodule TriggerTest.LatestEventSource do
  @moduledoc """
  `TriggerTest.EventSource` with the optional callbacks implemented, for the paths that
  use them when an adapter has them.

  `event/2` finds the event in the double's log, and tells the calling process it was
  asked. `latest_sequence/1` answers from the double's log. `ahead!/1` makes it answer `n` more
  than the sweep can read (events committed after the batch was read), and `ahead!(:raise)`
  makes it raise, the shape of a log that cannot be read.
  """

  @behaviour AshBpmn.EventSource

  @ahead {__MODULE__, :ahead}

  @doc "How far the log runs ahead of what `stream/3` returns: a count, or `:raise`."
  def ahead!(value), do: :persistent_term.put(@ahead, value)

  @doc "Back to a log that reports exactly what it streams."
  def reset!, do: :persistent_term.erase(@ahead)

  @impl true
  defdelegate stream(tenant, after_sequence, limit), to: TriggerTest.EventSource

  @impl true
  defdelegate context(event), to: TriggerTest.EventSource

  @impl true
  defdelegate sequence(event), to: TriggerTest.EventSource

  @impl true
  defdelegate occurred_at(event), to: TriggerTest.EventSource

  @impl true
  defdelegate order_guarantee(tenant), to: TriggerTest.EventSource

  @impl true
  defdelegate audited?(resource), to: TriggerTest.EventSource

  @impl true
  def event(tenant, id) do
    send(self(), {:event_source_event, tenant, id})

    case Enum.find(TriggerTest.EventSource.all(tenant), &(&1.id == id)) do
      nil -> {:error, :not_found}
      event -> {:ok, event}
    end
  end

  @impl true
  def latest_sequence(tenant) do
    case :persistent_term.get(@ahead, 0) do
      :raise -> raise "the log could not be read"
      n -> TriggerTest.EventSource.newest(tenant) + n
    end
  end
end

defmodule TriggerTest.RedriveAuthority do
  @moduledoc """
  The host's authority check for a re-drive, whose answer the test sets. Records what it
  was called with, so a test can see it ran with the version and the tenant.
  """

  @answer {__MODULE__, :answer}

  @doc "Sets the answer: `:ok` or `{:error, reason}`."
  def answer!(value), do: :persistent_term.put(@answer, value)

  @doc "Back to `:ok`."
  def reset!, do: :persistent_term.erase(@answer)

  def check(subscription, tenant, tag) do
    send(self(), {:redrive_authority, subscription.id, tenant, tag})
    :persistent_term.get(@answer, :ok)
  end
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
