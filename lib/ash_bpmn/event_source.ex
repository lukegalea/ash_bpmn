# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.EventSource do
  @moduledoc """
  The seam between the engine's event sweep and the host's event log.

  The library must not depend on `ash_events` — or on any particular log. It depends on this
  behaviour, and the adapter owns every coupling to the host's log; the engine never sees
  `ash_events` types (or any other log's). Configure it:

      config :ash_bpmn, event_source: MyApp.Audit.EventSource

  (default `nil`; the triggers extension refuses to start without one.)

  ## The adapter's three obligations

  They are the whole contract:

  1. **Stream.** `c:stream/3` returns the log's events above a sequence, ascending, bounded —
     the cursor protocol. The engine walks each tenant's log with it, one batch at a time,
     and records how far it got; nothing else is ever asked about position.

  2. **Context.** `c:context/1` reshapes each event into the published context map that
     guards, subject resolution and correlation keys all read. Resource names use the short
     form people type and guards compare against (`MyApp.Finance.Payout` becomes
     `"payout"`) — the adapter is where the module atom becomes the short string.

  3. **Declare the ordering guarantee per chain.** `c:order_guarantee/1` is a declaration,
     not a measurement. A `:commit_order` return claims that within the tenant, sequence
     order equals commit order — which, for an ash_events-backed adapter, is an
     *implementation detail inherited from the log's write path*: a per-tenant
     `pg_advisory_xact_lock` taken immediately before the event insert (see the event-dimension
     design notes, `event-triggered-processes.md` §2, where the property was measured and its
     reach bounded). It is not a contract ash_events makes, and the NULL-tenant chain shares
     no lock space with anything at all, so it is `:best_effort`, full stop. A consumer that
     silently depends on an upstream detail is a consumer that breaks silently when it
     changes — so an adapter claiming `:commit_order` states that property, and its
     provenance, in its own moduledoc. The engine treats `:best_effort` chains accordingly:
     dispatch, but never promise per-subject ordering on them.

  ## Not a change feed

  The behaviour streams events that went through audited actions. Raw SQL writes produce
  nothing, and a subscription watching for one waits forever without erroring — which is why
  `c:audited?/1` exists and why publish-time refusals (FR-3.4) call it: a subscription cannot
  ship against a resource that carries no audit hook.
  """

  @doc """
  Streams at most `limit` events with a sequence above `after_sequence`, ascending.

  The returned tuple carries the batch and the last sequence in it (nil when the batch is
  empty), so the engine's cursor can resume exactly where the batch ended. Reading past the
  end of the log returns an empty batch and keeps the cursor where it is.
  """
  @callback stream(tenant :: term(), after_sequence :: integer(), limit :: pos_integer()) ::
              {:ok, {[event :: term()], last_sequence :: integer() | nil}}

  @doc """
  Builds the published context contract for `event`.

  A map with string keys — `event` (id, sequence, occurred_at, resource short-name, action,
  action_type, record_id, version), `actor`, `tenant`, `data`, `changed`, `metadata`. This is
  what guards evaluate against and what correlation keys are computed from.
  """
  @callback context(event :: term()) :: %{optional(String.t()) => term()}

  @doc "The event's position in its tenant's log."
  @callback sequence(event :: term()) :: integer()

  @doc "When the event happened — the watermark lookback windows are measured against."
  @callback occurred_at(event :: term()) :: DateTime.t()

  @doc """
  The ordering guarantee the log makes for `tenant`'s chain: `:commit_order` or
  `:best_effort`. See the moduledoc's third obligation before returning `:commit_order`.
  """
  @callback order_guarantee(tenant :: term()) :: :commit_order | :best_effort

  @doc """
  Whether `resource` writes into the log this adapter reads. Called at publish time, so a
  subscription watching an unaudited resource is refused with the resource named rather than
  silently waiting forever.
  """
  @callback audited?(resource :: module()) :: boolean()
end
