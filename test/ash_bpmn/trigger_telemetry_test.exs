# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.TriggerTelemetryTest do
  @moduledoc """
  The trigger sweep reports, by itself, how far behind each tenant's log it is
  (`[:ash_bpmn, :triggers, :sweep]`, `lag`) and how long an event waited for the process it
  started (`[:ash_bpmn, :triggers, :dispatch, :start]`, `latency`). See
  `AshBpmn.Triggers.Telemetry`.
  """

  use AshBpmn.DataCase, async: false

  import ExUnit.CaptureLog

  alias AshBpmn.Scope
  alias AshBpmn.TenantTest.{Cursor, Definition, Subscription}

  @acme Ecto.UUID.generate()

  @sweep [:ash_bpmn, :triggers, :sweep]
  @dispatch_start [:ash_bpmn, :triggers, :dispatch, :start]

  setup do
    previous_source = Application.get_env(:ash_bpmn, :event_source)
    previous_resolver = Application.get_env(:ash_bpmn, :decision_resolver)

    Application.put_env(:ash_bpmn, :decision_resolver, TriggerTest.DecisionResolver)
    TriggerTest.DecisionResolver.set_exists?(true)
    TriggerTest.DecisionResolver.set_decide(:default)
    TriggerTest.EventSource.reset!()
    TriggerTest.LatestEventSource.reset!()

    Cursor.create!(%{last_sequence: 0}, engine_scope(@acme))

    handler = "trigger-telemetry-test-#{System.unique_integer([:positive])}"
    :telemetry.attach_many(handler, [@sweep, @dispatch_start], &__MODULE__.relay/4, self())

    on_exit(fn ->
      :telemetry.detach(handler)
      TriggerTest.LatestEventSource.reset!()
      restore_env(:event_source, previous_source)
      restore_env(:decision_resolver, previous_resolver)
    end)

    :ok
  end

  @doc false
  def relay(event, measurements, metadata, pid), do: send(pid, {event, measurements, metadata})

  describe "sweep lag" do
    test "the sweep reports how far behind the tenant's log it is" do
      use_source(TriggerTest.LatestEventSource)
      TriggerTest.EventSource.append!(@acme)
      TriggerTest.EventSource.append!(@acme)

      assert :ok = sweep!(@acme)

      assert_received {@sweep, %{lag: 0, events: 2}, %{tenant: @acme, last_sequence: 2}}

      # Three events committed after the batch was read: the next sweep is three behind.
      TriggerTest.LatestEventSource.ahead!(3)
      assert :ok = sweep!(@acme)

      assert_received {@sweep, %{lag: 3, events: 0}, %{tenant: @acme, last_sequence: 2}}
    end

    test "an adapter without latest_sequence/1 reports no lag" do
      use_source(TriggerTest.EventSource)
      TriggerTest.EventSource.append!(@acme)

      assert :ok = sweep!(@acme)

      assert_received {@sweep, measurements, %{tenant: @acme, last_sequence: 1}}
      assert %{events: 1, duration_ms: _} = measurements
      refute Map.has_key?(measurements, :lag)
    end

    test "a lag read that raises leaves the lag out and the sweep done" do
      use_source(TriggerTest.LatestEventSource)
      TriggerTest.EventSource.append!(@acme)
      TriggerTest.LatestEventSource.ahead!(:raise)

      log = capture_log(fn -> assert :ok = sweep!(@acme) end)

      assert log =~ "sweep lag not reported"
      assert_received {@sweep, measurements, %{tenant: @acme, last_sequence: 1}}
      refute Map.has_key?(measurements, :lag)
      assert cursor!(@acme).last_sequence == 1
    end
  end

  describe "dispatch latency" do
    test "a dispatch that starts a process reports how long its event waited" do
      use_source(TriggerTest.EventSource)
      publish_definition!(@acme, "onboarding_sweep")
      sub = subscribe!(@acme, "waited", %{process_key: "onboarding_sweep"})

      occurred_at = DateTime.add(DateTime.utc_now(), -3_600, :second)
      TriggerTest.EventSource.append!(@acme, %{occurred_at: occurred_at})

      assert :ok = sweep!(@acme)

      assert_received {@dispatch_start, %{latency: latency}, metadata}
      assert metadata == %{tenant: @acme, kind: :start, subscription_id: sub.id}

      waited = DateTime.diff(DateTime.utc_now(), occurred_at, :microsecond)
      latency = System.convert_time_unit(latency, :native, :microsecond)
      assert latency >= 3_600_000_000
      assert latency <= waited
    end

    test "a dispatch that starts nothing reports nothing" do
      use_source(TriggerTest.EventSource)
      subscribe!(@acme, "unstartable", %{process_key: "not_published"})
      TriggerTest.EventSource.append!(@acme)

      assert :ok = sweep!(@acme)

      assert_received {@sweep, _, _}
      refute_received {@dispatch_start, _, _}
    end
  end

  defp use_source(source), do: Application.put_env(:ash_bpmn, :event_source, source)

  defp engine_scope(tenant), do: Scope.engine(%Scope{tenant: tenant})

  defp sweep!(tenant),
    do: AshBpmn.Triggers.SweepWorker.perform(%Oban.Job{args: %{"tenant" => tenant}})

  defp publish_definition!(tenant, key) do
    xml = File.read!("test/fixtures/linear.bpmn")
    defn = Definition.create!(%{key: key, name: "Test #{key}", xml: xml}, engine_scope(tenant))

    AshBpmn.TestRepo.query!(
      "UPDATE tenant_bpmn_definitions SET status = 'published' WHERE id = '#{defn.id}'"
    )

    defn
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

  defp cursor!(tenant) do
    Cursor
    |> Ash.Query.for_read(:read)
    |> Ash.read_one!(engine_scope(tenant))
  end

  defp restore_env(key, nil), do: Application.delete_env(:ash_bpmn, key)
  defp restore_env(key, value), do: Application.put_env(:ash_bpmn, key, value)
end
