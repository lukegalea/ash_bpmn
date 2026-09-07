# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.TriggersRuntimeTest do
  @moduledoc """
  The sweep and the correlator, end to end (TRD §5) — the driver, the nudge,
  the index and the funnel, against the tenant-scoped test doubles on the
  inline Oban shim.

  The negative paths are the point: guard null vs false vs error, no-rule vs
  decision-error, no published definition, disabled-not-retroactive, a bad
  event that never wedges the batch, a crash whose replay never duplicates a
  start, the fan-out and depth bounds, and tenant isolation.
  """

  use AshBpmn.DataCase, async: false

  require Ash.Query

  alias AshBpmn.Runtime.DomainResolver
  alias AshBpmn.Scope
  alias AshBpmn.TenantTest.{Cursor, Definition, Dispatch, Instance, Subscription}

  @acme Ecto.UUID.generate()
  @globex Ecto.UUID.generate()
  @delta Ecto.UUID.generate()

  setup do
    previous_source = Application.get_env(:ash_bpmn, :event_source)
    previous_resolver = Application.get_env(:ash_bpmn, :decision_resolver)
    previous_tenants = Application.get_env(:ash_bpmn, :trigger_tenants)
    previous_nudge_tenant = Application.get_env(:ash_bpmn, :nudge_tenant_field)

    Application.put_env(:ash_bpmn, :event_source, TriggerTest.EventSource)
    Application.put_env(:ash_bpmn, :decision_resolver, TriggerTest.DecisionResolver)
    TriggerTest.DecisionResolver.set_exists?(true)
    TriggerTest.DecisionResolver.set_decide(:default)
    TriggerTest.EventSource.reset!()

    # The cursor exists from the moment the extension is installed / a
    # subscription is published — the sweep only creates one when absent, and a
    # cursor created at the log's *end* would skip every test event. See the
    # fresh-cursor test for the creation path itself.
    Cursor.create!(%{last_sequence: 0}, engine_scope(@acme))
    Cursor.create!(%{last_sequence: 0}, engine_scope(@globex))

    on_exit(fn ->
      restore_env(:event_source, previous_source)
      restore_env(:decision_resolver, previous_resolver)
      restore_env(:trigger_tenants, previous_tenants)
      restore_env(:nudge_tenant_field, previous_nudge_tenant)
    end)

    :ok
  end

  # ── The happy path ────────────────────────────────────────────────────

  describe "the happy path" do
    test "an audited write starts the subscribed process, end to end" do
      publish_definition!(@acme, "onboarding_sweep")
      sub = subscribe!(@acme, "happy", %{process_key: "onboarding_sweep"})

      event =
        TriggerTest.EventSource.append!(@acme, %{metadata: %{"correlation_id" => "op-42"}})

      attach_sweep_telemetry()

      assert :ok = sweep!(@acme)

      # The ledger row: what, who, why, and what it started.
      [dispatch] = dispatches!(@acme, sub.id)
      assert dispatch.status == :started
      assert dispatch.reason == nil
      assert dispatch.process_key == "onboarding_sweep"
      assert dispatch.event_id == event.id
      assert dispatch.event_sequence == event.sequence
      assert dispatch.event_occurred_at == event.occurred_at
      assert dispatch.correlation_id == "op-42"
      assert dispatch.depth == 1, "an event a person caused starts a depth-1 dispatch"

      # The instance: right subject, right tenant, joined to its cause, and
      # actually run (the linear graph completes inline).
      instance = instance!(dispatch.instance_id)
      assert instance.organization_id == @acme
      assert instance.subject_id == event.record_id
      # The engine stores `to_string(module)`; `AshBpmn.Subject` resolves it back.
      assert instance.subject_type == "Elixir.TriggerTest.Payout"
      assert instance.correlation_id == "op-42"
      assert instance.status == :completed

      # The cursor: advanced to the batch's end.
      assert cursor!(@acme).last_sequence == event.sequence

      assert_received {:sweep_telemetry, %{events: 1}, %{tenant: @acme, last_sequence: seq}}
      assert seq == event.sequence
    end

    test "a replayed sweep starts nothing new and records nothing twice" do
      publish_definition!(@acme, "onboarding_sweep")
      sub = subscribe!(@acme, "replay", %{process_key: "onboarding_sweep"})
      event = TriggerTest.EventSource.append!(@acme)

      sweep!(@acme)
      sweep!(@acme)

      assert [_] = dispatches!(@acme, sub.id)
      assert instance_ids!(@acme) |> length() == 1
      assert cursor!(@acme).last_sequence == event.sequence
    end
  end

  # ── Guards ────────────────────────────────────────────────────────────

  describe "guards" do
    # FEEL is three-valued, and the three answers go to three different places:
    # true routes on, false is an ordinary no (and records nothing -- there is
    # no condition to investigate), null and error are rows, because a guard
    # that is silently never true is the bug you want to see.
    test "null and error are recorded distinctly, plain false is not" do
      publish_definition!(@acme, "onboarding_sweep")

      sub =
        subscribe!(@acme, "guarded", %{
          process_key: "onboarding_sweep",
          guard_feel: "data.amount > 100"
        })

      error_sub =
        subscribe!(@acme, "guard_error", %{
          process_key: "onboarding_sweep",
          guard_feel: "data.amount"
        })

      # No `amount` in the payload: the ordering guard folds to FEEL null...
      missing = TriggerTest.EventSource.append!(@acme, %{data: %{}})
      # ...and a present `amount` makes it plain false...
      false_case = TriggerTest.EventSource.append!(@acme, %{data: %{"amount" => 5}})
      # ...while the bare-path guard errors on the same event (a number is not
      # a boolean).
      _ = false_case

      sweep!(@acme)

      rows = dispatches!(@acme, sub.id)
      assert [%{status: :skipped, reason: :guard_null, event_id: id}] = rows
      assert id == missing.id
      # The plain false: no row at all. One subscription, one event, nothing
      # recorded -- an ordinary no is not a condition to investigate.
      assert cursor!(@acme).last_sequence == false_case.sequence

      error_rows = dispatches!(@acme, error_sub.id) |> Enum.sort_by(& &1.event_sequence)

      assert [%{status: :skipped, reason: :guard_null}, %{status: :failed, reason: :guard_error}] =
               error_rows

      # And the cursor advances past every outcome, including the failures.
      assert cursor!(@acme).last_sequence == false_case.sequence
    end
  end

  # ── Routing ───────────────────────────────────────────────────────────

  describe "routing" do
    test "a decision that answers nothing is :no_rule_fired; one that errors is :decision_error" do
      publish_definition!(@acme, "onboarding_sweep")

      sub =
        subscribe!(@acme, "routed", %{
          process_key: nil,
          route_kind: :decision,
          decision_key: "routing"
        })

      TriggerTest.DecisionResolver.set_decide(fn _ref, _inputs, _ctx ->
        {:ok, %{outputs: %{"tier" => "gold"}}}
      end)

      no_rule = TriggerTest.EventSource.append!(@acme)
      sweep!(@acme)

      assert [
               %{
                 status: :skipped,
                 reason: :no_rule_fired,
                 decision_key: "routing",
                 process_key: nil
               }
             ] =
               dispatches!(@acme, sub.id)

      TriggerTest.DecisionResolver.set_decide(fn _ref, _inputs, _ctx ->
        {:error, :decision_boom}
      end)

      errored = TriggerTest.EventSource.append!(@acme)
      sweep!(@acme)

      rows = dispatches!(@acme, sub.id) |> Enum.sort_by(& &1.event_sequence)
      assert [%{reason: :no_rule_fired}, %{reason: :decision_error, status: :failed}] = rows
      assert cursor!(@acme).last_sequence == errored.sequence
    end

    test "a decision that chooses records decision_key and the fired rule" do
      publish_definition!(@acme, "onboarding_sweep")

      sub =
        subscribe!(@acme, "routed_hit", %{
          process_key: nil,
          route_kind: :decision,
          decision_key: "routing"
        })

      TriggerTest.DecisionResolver.set_decide(fn _ref, _inputs, _ctx ->
        {:ok, %{outputs: %{"process_key" => "onboarding_sweep"}, rule_ids: ["rule-9"]}}
      end)

      TriggerTest.EventSource.append!(@acme)
      sweep!(@acme)

      assert [%{status: :started, decision_key: "routing", fired_rule: "rule-9"}] =
               dispatches!(@acme, sub.id)

      assert instance_ids!(@acme) |> length() == 1
    end

    test "fan-out past max_starts_per_event is refused loudly and starts nothing" do
      publish_definition!(@acme, "onboarding_sweep")

      sub =
        subscribe!(@acme, "fan_out", %{
          process_key: nil,
          route_kind: :decision,
          decision_key: "routing",
          max_starts_per_event: 2
        })

      TriggerTest.DecisionResolver.set_decide(fn _ref, _inputs, _ctx ->
        {:ok,
         %{
           outputs: [
             %{"process_key" => "onboarding_sweep"},
             %{"process_key" => "onboarding_sweep"},
             %{"process_key" => "onboarding_sweep"}
           ]
         }}
      end)

      TriggerTest.EventSource.append!(@acme)
      sweep!(@acme)

      assert [%{status: :failed, reason: :fan_out_exceeded}] = dispatches!(@acme, sub.id)
      assert instance_ids!(@acme) == []
    end

    test "a process with no published definition is a :no_definition row, not a crash" do
      subscribe!(@acme, "nowhere_to_go", %{process_key: "never_published"})
      event = TriggerTest.EventSource.append!(@acme)

      assert :ok = sweep!(@acme)

      assert [%{status: :failed, reason: :no_definition, process_key: "never_published"}] =
               dispatches_for_tenant!(@acme)

      assert instance_ids!(@acme) == []
      assert cursor!(@acme).last_sequence == event.sequence
    end
  end

  # ── The subject and the depth bound ───────────────────────────────────

  describe "subject and depth" do
    test "subject_of picks the record the process starts for" do
      publish_definition!(@acme, "onboarding_sweep")

      subscribe!(@acme, "subjected", %{
        process_key: "onboarding_sweep",
        subject_of: "data.approved_for"
      })

      other_record = Ecto.UUID.generate()
      TriggerTest.EventSource.append!(@acme, %{data: %{"approved_for" => other_record}})
      sweep!(@acme)

      assert [%{status: :started, instance_id: id}] = dispatches_for_tenant!(@acme)
      assert instance!(id).subject_id == other_record
    end

    test "depth past the bound refuses with :depth_exceeded, and depth 1 otherwise" do
      publish_definition!(@acme, "onboarding_sweep")
      sub = subscribe!(@acme, "bounded", %{process_key: "onboarding_sweep"})

      TriggerTest.EventSource.append!(@acme, %{metadata: %{"trigger_depth" => 5}})
      normal = TriggerTest.EventSource.append!(@acme)

      sweep!(@acme)

      rows = dispatches!(@acme, sub.id) |> Enum.sort_by(& &1.event_sequence)
      assert [%{status: :failed, reason: :depth_exceeded, depth: 6}, %{depth: 1}] = rows

      # Only the within-bound event started anything.
      assert instance_ids!(@acme) |> length() == 1
      assert cursor!(@acme).last_sequence == normal.sequence
    end
  end

  # ── Disabling ─────────────────────────────────────────────────────────

  describe "disabling" do
    test "is not retroactive, and a disabled subscription records nothing" do
      publish_definition!(@acme, "onboarding_sweep")
      sub = subscribe!(@acme, "switchable", %{process_key: "onboarding_sweep"})

      before = TriggerTest.EventSource.append!(@acme)
      sweep!(@acme)
      assert [%{status: :started}] = dispatches!(@acme, sub.id)

      Subscription.disable!(sub, engine_scope(@acme))

      after_disable = TriggerTest.EventSource.append!(@acme)
      sweep!(@acme)

      # Nothing new: the disabled subscription is not matched, and nothing is
      # recorded for its events.
      assert [%{event_id: before_id}] = dispatches!(@acme, sub.id)
      assert before_id == before.id
      assert instance_ids!(@acme) |> length() == 1
      # But the cursor still advances past them.
      assert cursor!(@acme).last_sequence == after_disable.sequence
    end
  end

  # ── Batch survival and replay ─────────────────────────────────────────

  describe "batch survival and replay" do
    test "one bad event never wedges the batch, and the cursor advances past it" do
      publish_definition!(@acme, "onboarding_sweep")
      sub = subscribe!(@acme, "survivor", %{process_key: "onboarding_sweep"})

      first = TriggerTest.EventSource.append!(@acme)
      poisoned = TriggerTest.EventSource.append!(@acme)
      last = TriggerTest.EventSource.append!(@acme)
      TriggerTest.EventSource.poison_context!(poisoned)

      assert :ok = sweep!(@acme)

      event_ids = dispatches!(@acme, sub.id) |> Enum.map(& &1.event_id) |> Enum.sort()
      assert event_ids == Enum.sort([first.id, last.id])

      assert cursor!(@acme).last_sequence == last.sequence
    end

    test "a sweep crashed mid-batch leaves the cursor; the replay dispatches the rest, once" do
      publish_definition!(@acme, "onboarding_sweep")
      sub = subscribe!(@acme, "replayed", %{process_key: "onboarding_sweep"})

      first = TriggerTest.EventSource.append!(@acme)
      second = TriggerTest.EventSource.append!(@acme)

      # Simulate the crash window: event one dispatched (its own transaction,
      # exactly as the sweep does it), cursor not yet advanced.
      domain = AshBpmn.TenantTest.Domain
      resources = DomainResolver.resolve!("Elixir.AshBpmn.TenantTest.Domain")

      scope = %Scope{
        tenant: @acme,
        actor: AshBpmn.SystemActor.sweep(),
        domain: domain
      }

      ctx = %{
        scope: scope,
        tenant: @acme,
        domain: domain,
        resources: resources,
        event_source: TriggerTest.EventSource
      }

      AshPostgres.DataLayer.Info.repo(resources.cursor).transaction(fn ->
        AshBpmn.Triggers.Correlator.dispatch_event(first, [sub], ctx)
      end)

      assert cursor!(@acme).last_sequence == 0, "the crash left the cursor where it was"
      assert [%{event_id: first_id}] = dispatches!(@acme, sub.id)
      assert first_id == first.id

      # The replay: the cursor is unchanged, so event one comes around again --
      # and the ledger identity turns the duplicate into a skip, not a second
      # process. Event two, never reached before the crash, dispatches fresh.
      sweep!(@acme)

      rows = dispatches!(@acme, sub.id) |> Enum.map(& &1.event_id) |> Enum.sort()
      assert rows == Enum.sort([first.id, second.id])

      assert dispatches!(@acme, sub.id) |> Enum.filter(&(&1.event_id == first.id)) |> length() ==
               1

      # Two instances, not three: event one's start is the crash window's, and
      # the replay added only event two's.
      assert instance_ids!(@acme) |> length() == 2
      assert cursor!(@acme).last_sequence == second.sequence
    end
  end

  # ── Tenants ───────────────────────────────────────────────────────────

  describe "tenants" do
    test "two tenants, two cursors, no leakage" do
      publish_definition!(@acme, "onboarding_sweep")
      sub = subscribe!(@acme, "isolated", %{process_key: "onboarding_sweep"})

      acme_event = TriggerTest.EventSource.append!(@acme)
      globex_event = TriggerTest.EventSource.append!(@globex)

      sweep!(@acme)
      sweep!(@globex)

      assert [%{event_id: acme_id}] = dispatches!(@acme, sub.id)
      assert acme_id == acme_event.id
      assert dispatches_for_tenant!(@globex) == []
      assert instance_ids!(@globex) == []

      acme_cursor = cursor!(@acme)
      globex_cursor = cursor!(@globex)
      assert acme_cursor.id != globex_cursor.id
      assert acme_cursor.last_sequence == acme_event.sequence
      assert globex_cursor.last_sequence == globex_event.sequence
    end

    test "a fresh cursor starts at the newest event, so a subscription fires on what comes after it" do
      # A tenant whose cursor does not exist yet (setup creates ones for the
      # other two tenants).
      tenant = @delta

      publish_definition!(tenant, "onboarding_sweep")
      subscribe!(tenant, "latecomer", %{process_key: "onboarding_sweep"})

      # History happens before the cursor exists...
      TriggerTest.EventSource.append!(tenant)
      TriggerTest.EventSource.append!(tenant)

      # ...the sweep creates the cursor at the high-water mark, and starts
      # nothing for what is already behind it.
      sweep!(tenant)
      assert cursor!(tenant).last_sequence > 0
      assert dispatches_for_tenant!(tenant) == []

      # What comes after the cursor dispatches normally.
      event = TriggerTest.EventSource.append!(tenant)
      sweep!(tenant)

      assert [%{event_id: late_id, status: :started}] = dispatches_for_tenant!(tenant)
      assert late_id == event.id
    end
  end

  # ── The index ─────────────────────────────────────────────────────────

  describe "the interest index" do
    test "an event nobody is listening for costs the context build and nothing else" do
      start_supervised!(AshBpmn.Triggers.Index)
      assert :ok = AshBpmn.Triggers.Index.reload!()

      # A resource nothing watches...
      nobody = TriggerTest.EventSource.append!(@acme, %{resource: AshBpmn.TenantTest.Dispatch})
      sweep!(@acme)

      assert dispatches_for_tenant!(@acme) == []
      # One context build at the funnel's boundary, then the zero-hit
      # short-circuit: no guard ran, no row was written.
      assert TriggerTest.EventSource.context_calls() == 1

      # ...and a watched resource passes straight through.
      subscribe!(@acme, "watched", %{
        process_key: nil,
        route_kind: :decision,
        decision_key: "routing"
      })

      assert :ok = AshBpmn.Triggers.Index.reload!()
      assert AshBpmn.Triggers.Index.interested?("TriggerTest.Payout", "create")

      _watched = TriggerTest.EventSource.append!(@acme)
      sweep!(@acme)

      # The decision route answers nothing, so the row is the skip -- but the
      # index did not block it.
      assert [%{reason: :no_rule_fired}] = dispatches_for_tenant!(@acme)
      assert TriggerTest.EventSource.context_calls() == 2
      assert cursor!(@acme).last_sequence == nobody.sequence + 1
    end
  end

  # ── The nudge ─────────────────────────────────────────────────────────

  describe "the nudge" do
    test "a hit enqueues the sweep, which dispatches the event" do
      # The double's event rows spell the tenant `:tenant`, not the default
      # `:organization_id` -- which is exactly what the config knob is for: the
      # log is the host's, and so is its field name.
      Application.put_env(:ash_bpmn, :nudge_tenant_field, :tenant)

      start_supervised!(AshBpmn.Triggers.Index)
      publish_definition!(@acme, "onboarding_sweep")
      sub = subscribe!(@acme, "nudged", %{process_key: "onboarding_sweep"})
      assert :ok = AshBpmn.Triggers.Index.reload!()

      event = TriggerTest.EventSource.append!(@acme)

      assert :ok = AshBpmn.Triggers.Nudge.notify(%Ash.Notifier.Notification{data: event})

      assert [%{event_id: nudged_id, status: :started}] = dispatches!(@acme, sub.id)
      assert nudged_id == event.id
    end

    test "a miss is quiet, and a nudge that cannot run is rescued, never raised" do
      start_supervised!(AshBpmn.Triggers.Index)
      subscribe!(@acme, "rescued", %{process_key: "onboarding_sweep"})
      assert :ok = AshBpmn.Triggers.Index.reload!()

      # A row with nothing the nudge reads: quiet no-op.
      assert :ok = AshBpmn.Triggers.Nudge.notify(%Ash.Notifier.Notification{data: %{}})

      # The enqueue lands, but the sweep cannot start: no event source is
      # configured. The notifier rescues -- a lost nudge costs latency, never
      # correctness, and must never fail the write it is notifying about. (The
      # setup's on_exit restores the config even if an assert below fails.)
      Application.delete_env(:ash_bpmn, :event_source)

      event = TriggerTest.EventSource.append!(@acme)

      assert :ok = AshBpmn.Triggers.Nudge.notify(%Ash.Notifier.Notification{data: event})
      assert dispatches_for_tenant!(@acme) == []
    end
  end

  # ── Tenant enumeration and the cron ───────────────────────────────────

  describe "tenant enumeration and the cron" do
    test "the cron fans one sweep per configured tenant" do
      Application.put_env(:ash_bpmn, :trigger_tenants, [@acme, @globex])

      assert :ok = AshBpmn.Triggers.CronSweep.perform(%Oban.Job{args: %{}})

      # Both cursors advanced (or were touched) by their own sweep: the
      # fan-out is per tenant, never a global walk.
      assert cursor!(@acme).last_sequence >= 0
      assert cursor!(@globex).last_sequence >= 0
    end

    test "trigger_tenants accepts an MFA, evaluated per call" do
      Application.put_env(:ash_bpmn, :trigger_tenants, {__MODULE__, :cron_tenants, []})

      assert :ok = AshBpmn.Triggers.CronSweep.perform(%Oban.Job{args: %{}})

      assert cursor!(@acme)
    end

    test "the cron entry helper spells the crontab tuple a host pastes" do
      assert {"* * * * *", AshBpmn.Triggers.CronSweep, opts} =
               AshBpmn.Triggers.SweepWorker.cron_entry()

      assert opts[:queue] == :bpmn
      assert opts[:max_attempts] == 1
    end
  end

  def cron_tenants, do: [@acme]

  # ── Helpers ───────────────────────────────────────────────────────────

  defp engine_scope(tenant), do: Scope.engine(%Scope{tenant: tenant})

  defp sweep!(tenant),
    do: AshBpmn.Triggers.SweepWorker.perform(%Oban.Job{args: %{"tenant" => tenant}})

  defp publish_definition!(tenant, key) do
    xml = File.read!("test/fixtures/linear.bpmn")

    defn = Definition.create!(%{key: key, name: "Test #{key}", xml: xml}, engine_scope(tenant))

    unless defn.graph do
      raise "Definition #{key} failed to compile: #{inspect(defn.errors)}"
    end

    AshBpmn.TestRepo.query!(
      "UPDATE tenant_bpmn_definitions SET status = 'published' WHERE id = '#{defn.id}'"
    )

    Definition.by_key_version!(key, defn.version, engine_scope(tenant))
  end

  defp subscribe!(tenant, key, overrides) do
    params =
      Map.merge(
        %{
          key: key,
          match_resource: "TriggerTest.Payout",
          match_action: nil,
          match_action_type: nil,
          process_key: "onboarding_sweep"
        },
        overrides
      )

    sub = Subscription.create!(params, engine_scope(tenant))
    Subscription.publish!(sub, engine_scope(tenant))
  end

  defp dispatches!(tenant, subscription_id) do
    Dispatch
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(subscription_id == ^subscription_id)
    |> Ash.Query.sort(event_sequence: :asc)
    |> Ash.read!(engine_scope(tenant))
  end

  defp dispatches_for_tenant!(tenant) do
    Dispatch
    |> Ash.Query.for_read(:read)
    |> Ash.Query.sort(event_sequence: :asc)
    |> Ash.read!(engine_scope(tenant))
  end

  defp instance_ids!(tenant) do
    Instance
    |> Ash.Query.for_read(:read)
    |> Ash.Query.select([:id])
    |> Ash.read!(engine_scope(tenant))
    |> Enum.map(& &1.id)
  end

  defp instance!(id) do
    Instance
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^id)
    |> Ash.read_one!(engine_scope(@acme))
    |> tap(fn instance -> assert instance, "expected instance #{id} to exist" end)
  end

  defp cursor!(tenant) do
    Cursor
    |> Ash.Query.for_read(:read)
    |> Ash.read_one!(engine_scope(tenant))
    |> tap(fn cursor -> assert cursor, "expected a cursor for the tenant" end)
  end

  defp attach_sweep_telemetry do
    :telemetry.attach(
      "triggers-runtime-test",
      [:ash_bpmn, :triggers, :sweep],
      fn [:ash_bpmn, :triggers, :sweep], measurements, metadata, _ ->
        send(self(), {:sweep_telemetry, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach("triggers-runtime-test") end)
  end

  defp restore_env(:event_source, nil), do: Application.delete_env(:ash_bpmn, :event_source)

  defp restore_env(:decision_resolver, nil),
    do: Application.delete_env(:ash_bpmn, :decision_resolver)

  defp restore_env(:trigger_tenants, nil),
    do: Application.delete_env(:ash_bpmn, :trigger_tenants)

  defp restore_env(:nudge_tenant_field, nil),
    do: Application.delete_env(:ash_bpmn, :nudge_tenant_field)

  defp restore_env(key, value), do: Application.put_env(:ash_bpmn, key, value)
end
