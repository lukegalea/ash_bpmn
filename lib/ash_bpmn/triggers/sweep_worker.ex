# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.Triggers.SweepWorker do
  @moduledoc """
  Walks one tenant's event chain and starts the processes its subscriptions ask
  for (TRD §5).

  **This is the driver.** `AshBpmn.Triggers.Nudge` only nudges it, and a lost
  nudge costs latency rather than a missed process: the cron sweep
  (`AshBpmn.Triggers.CronSweep`) walks the cursor and reaches the same events
  regardless.

  ## The arbiter, and why the lock is not it

  The event log cannot be marked — it is an append-only audit chain — so there
  is no per-row state to reconcile against, and two writers advancing an
  unmarkable stream need an arbiter. The TRD diagram puts a per-tenant
  `pg_advisory_xact_lock` at the top of the sweep; the reference application
  learned, by running it, that **one transaction around the whole batch cannot
  be the lock's scope**: a Postgres error anywhere in a transaction aborts it,
  so one bad event would take the batch — other events' instances and the
  cursor advance included — leaving no record of having tried.

  So both lessons are kept. The **scope** is per event: each event's funnel runs
  in its own transaction, so one bad event costs one event's work, never the
  batch. The **lock** remains, taken inside each of those transactions and
  inside the cursor advance, keyed `(class, tenant)` — the two-integer form,
  class derived from a fixed name (`:erlang.crc32`, stable across nodes) and
  the tenant hashed the same way, mirroring `ash_events`' two-element key
  discipline so the sweep serializes against concurrent sweeps of the same
  tenant at event granularity.

  The arbiter proper is `Dispatch`'s `[:subscription_id, :event_id]` identity,
  written **in the same transaction as the instance start** — so a racing
  sweep's duplicate insert conflicts and its instance rolls back with it. Two
  concurrent sweeps therefore cost duplicated work, not duplicated processes,
  and the cursor makes completeness independent of either: an event a racing
  sweep missed is still behind some cursor and gets picked up.

  ## The cursor advances past failures

  A subscription whose guard records `:guard_error`, whose decision errors, or
  whose process key has no published definition records a failed dispatch
  **and the cursor still moves**. A broken subscription must never wedge a
  tenant's event stream. The failure is a queryable row rather than a stuck
  queue, which is the difference between a problem someone finds and a problem
  someone reports.

  ## A fresh cursor starts at the newest event

  Starting a new cursor at zero would walk the tenant's entire history and
  start a process for every historical event that matches — the first symptom
  is the queue rather than the mistake. A subscription fires on what happens
  *after* it exists, so a cursor created by the sweep begins at the log's
  current high-water mark. `AshBpmn.EventSource` exposes no "latest sequence"
  callback, so the high-water mark is found by paging `stream/3` once — a
  one-time cost per tenant, paid before anything dispatches. (The publish lane
  may create the cursor earlier; the sweep only creates it when absent.)

  Reading `sequence > cursor` is safe because, within a tenant, sequence order
  is commit order — a guarantee the configured adapter *declares* per chain via
  `order_guarantee/1`; a `:best_effort` chain (the NULL-tenant chain, for an
  `ash_events`-backed adapter) is dispatched with no ordering promise.

  ## Batch and telemetry

  A batch is 500 events, bounded so a large backlog is swept in several passes
  rather than one very long job; the next sweep continues from the cursor. Each
  batch emits `[:ash_bpmn, :triggers, :sweep]` telemetry — measurements
  `:duration_ms` and `:events`, metadata `:tenant` and `:last_sequence` — which
  is what makes the one-sweeper-per-tenant throughput ceiling (TRD §12)
  visible rather than anecdotal.
  """

  use Oban.Worker, max_attempts: 3

  require Ash.Query
  require Logger

  alias AshBpmn.Config
  alias AshBpmn.Runtime.Oban, as: BpmnOban
  alias AshBpmn.Scope
  alias AshBpmn.Triggers.Correlator
  alias AshBpmn.Triggers.Resources

  # Bounded so a tenant with a large backlog is swept in several passes rather
  # than one very long job. The next sweep continues from the cursor.
  @batch 500

  # The lock's class half: a fixed name hashed deterministically (crc32 is
  # node-stable, unlike phash2), so every node derives the same key space. The
  # two-integer form mirrors ash_events' per-tenant key discipline; Postgres
  # treats a one-argument lock as a *different* lock space, so mixing forms
  # would silently un-serialize. Folded into the signed-32 range the two-form
  # `pg_advisory_xact_lock/2` requires.
  @sweep_lock_crc :erlang.crc32("ash_bpmn_triggers_sweep")

  @lock_class if @sweep_lock_crc >= 0x80000000,
                do: @sweep_lock_crc - 0x1_0000_0000,
                else: @sweep_lock_crc

  def queue, do: Config.queue()

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    started = System.monotonic_time(:millisecond)
    tenant = args["tenant"]

    # Refuses, with an instructive message, when no adapter is configured: the
    # sweep is the one caller that cannot work without the host's log.
    event_source = Config.event_source!()
    {domain, resources} = Resources.resolve!(args["domain"])

    scope = %Scope{Scope.from_job(args, :sweep) | domain: domain}
    repo = AshPostgres.DataLayer.Info.repo(resources.cursor)

    cursor = ensure_cursor(resources.cursor, event_source, tenant, scope)

    case event_source.stream(tenant, cursor.last_sequence, @batch) do
      {:ok, {[], _}} ->
        telemetry(started, tenant, cursor.last_sequence, 0)
        :ok

      {:ok, {events, _}} ->
        subscriptions = subscriptions(resources.subscription, scope)
        ctx = %{scope: scope, tenant: tenant, domain: domain, resources: resources, event_source: event_source}

        Enum.each(events, &dispatch_isolated(repo, tenant, &1, subscriptions, ctx))

        last_sequence = event_source.sequence(List.last(events))
        advance(repo, tenant, resources.cursor, cursor, last_sequence, scope)
        telemetry(started, tenant, last_sequence, length(events))

        :ok
    end
  end

  # Each event is dispatched in **its own transaction**, under the per-tenant
  # advisory lock. See the moduledoc for why the lock's scope is the event and
  # not the batch — found by building the batch-sized alternative and watching
  # one bad event take the whole sweep, instance and all.
  defp dispatch_isolated(repo, tenant, event, subscriptions, ctx) do
    repo.transaction(fn ->
      lock(repo, tenant)
      Correlator.dispatch_event(event, subscriptions, ctx)
    end)

    :ok
  rescue
    e ->
      Logger.error(
        "ash_bpmn trigger dispatch for event #{event_id(event)} failed and was rolled back: " <>
          Exception.message(e)
      )

      :ok
  end

  defp advance(repo, tenant, cursor_resource, cursor, last_sequence, scope) do
    repo.transaction(fn ->
      lock(repo, tenant)
      cursor_resource.advance!(cursor, last_sequence, Scope.engine(scope))
    end)

    :ok
  end

  defp lock(repo, tenant) do
    repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [@lock_class, tenant_key(tenant)])
    :ok
  end

  defp signed32(n) when n >= 0x80000000, do: n - 0x1_0000_0000
  defp signed32(n), do: n

  # crc32 is deterministic across nodes and architectures; term_to_binary of a
  # UUID string or an integer is stable for a given tenant value, which is all
  # a lock key needs. The NULL-tenant chain gets a key of its own (`0`), never
  # a shared one.
  defp tenant_key(tenant), do: tenant |> :erlang.term_to_binary() |> :erlang.crc32() |> signed32()

  defp event_id(event) do
    if is_map(event) and is_map_key(event, :id), do: event.id, else: inspect(event)
  end

  # Returns this tenant's cursor, creating it at the **current high-water
  # mark** if absent. Read first, create only when nil: the create is an
  # upsert, so stamping unconditionally would reset an existing cursor to the
  # log's end and silently skip everything in between.
  defp ensure_cursor(cursor_resource, event_source, tenant, scope) do
    cursor_resource
    |> Ash.Query.for_read(:read)
    |> Ash.read_one!(Scope.engine(scope))
    |> case do
      nil ->
        cursor_resource.create!(
          %{last_sequence: high_water(event_source, tenant)},
          Scope.engine(scope)
        )

      cursor ->
        cursor
    end
  end

  # The adapter's contract is forward-only (`stream/3` after a sequence), so
  # the high-water mark is found by paging to the end once. Bounded by the
  # same 500-page batch size; paid once per tenant, before anything dispatches.
  defp high_water(event_source, tenant, after_sequence \\ 0, last \\ nil)

  defp high_water(event_source, tenant, after_sequence, last) do
    case event_source.stream(tenant, after_sequence, @batch) do
      {:ok, {[], _}} ->
        last || 0

      {:ok, {events, _}} ->
        last = event_source.sequence(List.last(events))
        high_water(event_source, tenant, last, last)
    end
  end

  # One read per batch: the funnel's per-event match is in-memory against this
  # list. Published **and enabled**, message kind only — a disabled
  # subscription is not matched, and nothing is recorded for it (which is also
  # why disabling is not retroactive: the rows and instances that predate the
  # switch are history, not pending work).
  defp subscriptions(subscription_resource, scope) do
    subscription_resource
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(status == :published and enabled == true and kind == :message)
    |> Ash.read!(Scope.engine(scope))
  end

  defp telemetry(started, tenant, last_sequence, events) do
    :telemetry.execute([:ash_bpmn, :triggers, :sweep], %{
      duration_ms: System.monotonic_time(:millisecond) - started,
      events: events
    }, %{tenant: tenant, last_sequence: last_sequence})
  end

  @doc """
  Enqueues a sweep for every configured tenant.

  The cron entry's fan-out. Deliberately per tenant rather than one job walking
  everything: the ordering guarantee the cursor relies on holds *within* a
  tenant and nowhere else, so a global sweep would be a global cursor, which
  the design refuses. Tenants come from `config :ash_bpmn, trigger_tenants:` —
  a list or an `{m, f, a}` (the `ash_oban` `list_tenants` pattern), evaluated
  per call, so a host whose tenant list lives in the database plugs its loader
  in here.

  Each insert is `unique` over a five-second window per tenant, so a cron tick
  landing on top of a nudge-driven sweep does not double-enqueue.
  """
  @spec enqueue_all() :: :ok
  def enqueue_all do
    Enum.each(Config.trigger_tenants(), fn tenant ->
      BpmnOban.insert(
        __MODULE__,
        %{"tenant" => tenant},
        unique: [period: 5, keys: [:tenant], states: [:available, :scheduled]]
      )
    end)

    :ok
  end

  @doc """
  The `Oban.Plugins.Cron` entry for the trigger sweep, for a host's crontab:

      {Oban.Plugins.Cron,
       crontab: [
         AshBpmn.Triggers.SweepWorker.cron_entry()
       ]}

  A separate worker fans this out to one `SweepWorker` per tenant every minute
  (`AshBpmn.Triggers.CronSweep`) — the cron entry has to be a single job and
  the sweep has to be per tenant. The queue option is stated here rather than
  left to `AshBpmn.Config.queue/0` because a crontab is evaluated in
  `config/*.exs`, where application env is not yet available to read.
  """
  @spec cron_entry() :: {String.t(), module(), keyword()}
  def cron_entry do
    {"* * * * *", AshBpmn.Triggers.CronSweep, queue: :bpmn, max_attempts: 1}
  end
end
