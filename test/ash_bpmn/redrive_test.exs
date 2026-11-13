# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.RedriveTest do
  @moduledoc """
  An operator re-drives a tenant's failed trigger dispatches (`AshBpmn.Resources.Redrive`),
  each under the subscription version on its row, with the host's authority check run again
  now. The failure is the one the sweep records when a subscription names a process with no
  published definition; publishing it is the fix the operator re-drives after.
  """

  use AshBpmn.DataCase, async: false

  require Ash.Query

  alias AshBpmn.Scope
  alias AshBpmn.TenantTest.{Cursor, Definition, Dispatch, Instance, Redrive, Subscription}

  @acme Ecto.UUID.generate()
  @globex Ecto.UUID.generate()

  setup do
    previous_source = Application.get_env(:ash_bpmn, :event_source)
    previous_resolver = Application.get_env(:ash_bpmn, :decision_resolver)

    Application.put_env(:ash_bpmn, :event_source, TriggerTest.EventSource)
    Application.put_env(:ash_bpmn, :decision_resolver, TriggerTest.DecisionResolver)
    TriggerTest.DecisionResolver.set_exists?(true)
    TriggerTest.DecisionResolver.set_decide(:default)
    TriggerTest.EventSource.reset!()
    TriggerTest.RedriveAuthority.reset!()

    Cursor.create!(%{last_sequence: 0}, engine_scope(@acme))
    Cursor.create!(%{last_sequence: 0}, engine_scope(@globex))

    on_exit(fn ->
      TriggerTest.RedriveAuthority.reset!()
      restore_env(:event_source, previous_source)
      restore_env(:decision_resolver, previous_resolver)
    end)

    %{operator: %{id: Ecto.UUID.generate(), operator?: true}}
  end

  describe "a re-drive under the version on the row" do
    test "a successful re-drive starts once", %{operator: operator} do
      {sub, event, failed} = failure!(@acme)
      publish_definition!(@acme, "onboarding")

      assert {:ok, [redrive]} = redrive(event, operator, @acme)

      assert redrive.outcome == :started
      assert redrive.reason == nil
      assert redrive.failed_dispatch_id == failed.id
      assert redrive.subscription_id == sub.id
      assert redrive.event_id == event.id
      assert redrive.event_sequence == event.sequence
      assert redrive.redriven_by_id == operator.id

      sub_id = sub.id
      assert_received {:redrive_authority, ^sub_id, @acme, :standing}

      assert [dispatch] = started(@acme)
      assert dispatch.id == redrive.dispatch_id
      assert dispatch.subscription_id == sub.id
      assert [instance_id] = instance_ids(@acme)
      assert dispatch.instance_id == instance_id
    end

    test "a second re-drive does not start twice", %{operator: operator} do
      {_sub, event, _failed} = failure!(@acme)
      publish_definition!(@acme, "onboarding")

      assert {:ok, [%{outcome: :started} = first]} = redrive(event, operator, @acme)
      assert {:ok, [second]} = redrive(event, operator, @acme)

      assert second.outcome == :already_started
      assert second.dispatch_id == first.dispatch_id
      assert [_one] = started(@acme)
      assert [_one] = instance_ids(@acme)
      assert length(redrives(@acme)) == 2
    end

    test "the authority check runs now: refused, no start and no_authority", %{
      operator: operator
    } do
      {_sub, event, _failed} = failure!(@acme)
      publish_definition!(@acme, "onboarding")
      TriggerTest.RedriveAuthority.answer!({:error, :no_start_grant})

      assert {:ok, [redrive]} = redrive(event, operator, @acme)

      assert redrive.outcome == :no_authority
      assert redrive.reason == "no_start_grant"
      assert redrive.dispatch_id == nil
      assert started(@acme) == []
      assert instance_ids(@acme) == []
    end

    test "a disabled version is not driven, and its authority is not asked", %{
      operator: operator
    } do
      {sub, event, _failed} = failure!(@acme)
      publish_definition!(@acme, "onboarding")
      Subscription.disable!(sub, engine_scope(@acme))

      assert {:ok, [%{outcome: :not_started, reason: "disabled"}]} =
               redrive(event, operator, @acme)

      refute_received {:redrive_authority, _, _, _}
      assert started(@acme) == []
    end

    test "a cause that persists records the new reason, and the event is driven once later",
         %{operator: operator} do
      {sub, event, _failed} = failure!(@acme)

      assert {:ok, [%{outcome: :not_started, reason: "no_definition", dispatch_id: nil}]} =
               redrive(event, operator, @acme)

      # The funnel wrote a second failed row for the same event.
      assert [%{status: :failed}, %{status: :failed}] = dispatches(@acme, sub.id)

      # Two failed rows, one event: driven once, from the newest.
      publish_definition!(@acme, "onboarding")
      assert {:ok, [%{outcome: :started}]} = redrive(event, operator, @acme)
      assert [_one] = instance_ids(@acme)
    end

    test "a superseded version drives its own failed event", %{operator: operator} do
      {v1, event, _failed} = failure!(@acme)
      v2 = subscribe!(@acme, "rule", %{process_key: "onboarding"})

      assert Subscription.by_key_version!("rule", v1.version, engine_scope(@acme)).status ==
               :retired

      publish_definition!(@acme, "onboarding")

      assert {:ok, [redrive]} = redrive(event, operator, @acme)
      assert redrive.outcome == :started
      assert redrive.subscription_id == v1.id

      assert [%{subscription_id: subscription_id}] = started(@acme)
      assert subscription_id == v1.id
      assert dispatches(@acme, v2.id) == []
    end

    test "an event the log no longer has is not driven", %{operator: operator} do
      {_sub, event, _failed} = failure!(@acme)
      publish_definition!(@acme, "onboarding")
      TriggerTest.EventSource.forget!(event)

      assert {:ok, [%{outcome: :not_started, reason: "event_not_found"}]} =
               redrive(event, operator, @acme)

      assert started(@acme) == []
    end

    test "an adapter with event/2 is asked for the event", %{operator: operator} do
      Application.put_env(:ash_bpmn, :event_source, TriggerTest.LatestEventSource)
      {_sub, event, _failed} = failure!(@acme)
      publish_definition!(@acme, "onboarding")

      assert {:ok, [%{outcome: :started}]} = redrive(event, operator, @acme)

      event_id = event.id
      assert_received {:event_source_event, @acme, ^event_id}
    end

    test "a re-driven start reports how long its event waited", %{operator: operator} do
      handler = "redrive-test-#{System.unique_integer([:positive])}"
      start = [:ash_bpmn, :triggers, :dispatch, :start]
      :telemetry.attach(handler, start, &__MODULE__.relay/4, self())
      on_exit(fn -> :telemetry.detach(handler) end)

      occurred_at = DateTime.add(DateTime.utc_now(), -7_200, :second)
      {sub, event, _failed} = failure!(@acme, %{occurred_at: occurred_at})
      publish_definition!(@acme, "onboarding")

      assert {:ok, [%{outcome: :started}]} = redrive(event, operator, @acme)

      assert_received {^start, %{latency: latency}, %{subscription_id: subscription_id}}
      assert subscription_id == sub.id
      assert System.convert_time_unit(latency, :native, :second) >= 7_200
    end

    test "other tenants' dispatches are not touched", %{operator: operator} do
      {_sub, ours, _failed} = failure!(@acme)
      {_their_sub, theirs, _their_failed} = failure!(@globex)
      publish_definition!(@acme, "onboarding")
      publish_definition!(@globex, "onboarding")

      # Every sequence there is, in our tenant: only our failure is ours to drive.
      assert {:ok, [redrive]} =
               Redrive.redrive_failed(%{from_sequence: 0}, actor: operator, tenant: @acme)

      assert redrive.event_id == ours.id
      assert redrives(@globex) == []
      assert started(@globex) == []

      assert [%{status: :failed, event_id: event_id}] =
               Ash.read!(Dispatch, authorize?: false, tenant: @globex)

      assert event_id == theirs.id
    end

    test "a range is required", %{operator: operator} do
      assert {:error, error} = Redrive.redrive_failed(%{}, actor: operator, tenant: @acme)
      assert Exception.message(error) =~ "give a range"
    end

    test "a tenant is required", %{operator: operator} do
      assert {:error, error} = Redrive.redrive_failed(%{from_sequence: 0}, actor: operator)
      assert Exception.message(error) =~ "needs a tenant"
    end

    test "only a failed start dispatch can be re-driven", %{operator: operator} do
      {_sub, event, _failed} = failure!(@acme)
      publish_definition!(@acme, "onboarding")
      assert {:ok, [%{dispatch_id: dispatch_id}]} = redrive(event, operator, @acme)

      assert {:error, %Ash.Error.Invalid{} = error} =
               Redrive.record(dispatch_id, actor: operator, tenant: @acme)

      assert Exception.message(error) =~ "is not a failed start dispatch"

      assert {:error, %Ash.Error.Invalid{} = error} =
               Redrive.record(Ecto.UUID.generate(), actor: operator, tenant: @acme)

      assert Exception.message(error) =~ "names no dispatch"
    end
  end

  describe "a re-drive is the host's to authorize" do
    test "an actor the host's policy refuses is Forbidden" do
      {_sub, event, _failed} = failure!(@acme)
      publish_definition!(@acme, "onboarding")
      reader = %{id: Ecto.UUID.generate(), operator?: false}

      assert {:error, %Ash.Error.Forbidden{}} = redrive(event, reader, @acme)

      assert {:error, %Ash.Error.Forbidden{}} =
               Redrive.redrive_failed(
                 %{from_sequence: event.sequence},
                 engine_scope(@acme)
               )

      assert redrives(@acme) == []
      assert started(@acme) == []
    end

    test "the engine's mark opens nothing: the macro generates no bypass" do
      assert Ash.Policy.Info.policies(Redrive)
             |> Enum.all?(fn policy ->
               Enum.all?(policy.condition, fn
                 {AshBpmn.Checks.AshBpmnInteraction, _opts} -> false
                 _check -> true
               end)
             end)
    end
  end

  @doc false
  def relay(event, measurements, metadata, pid), do: send(pid, {event, measurements, metadata})

  # ── Helpers ───────────────────────────────────────────────────────────

  # A subscription to a process nobody has published, an event it matches, and the failed
  # row the sweep writes for it.
  defp failure!(tenant, event_attrs \\ %{}) do
    sub = subscribe!(tenant, "rule", %{process_key: "onboarding"})
    event = TriggerTest.EventSource.append!(tenant, event_attrs)
    :ok = sweep!(tenant)

    assert [%{status: :failed, reason: :no_definition} = failed] = dispatches(tenant, sub.id)
    {sub, event, failed}
  end

  defp redrive(event, actor, tenant) do
    Redrive.redrive_failed(
      %{from_sequence: event.sequence, to_sequence: event.sequence},
      actor: actor,
      tenant: tenant
    )
  end

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
          match_action_type: nil
        },
        overrides
      )

    sub = Subscription.create!(params, engine_scope(tenant))
    Subscription.publish!(sub, engine_scope(tenant))
  end

  defp dispatches(tenant, subscription_id) do
    Dispatch
    |> Ash.Query.filter(subscription_id == ^subscription_id)
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.read!(authorize?: false, tenant: tenant)
  end

  defp started(tenant) do
    Dispatch
    |> Ash.Query.filter(status == :started)
    |> Ash.read!(authorize?: false, tenant: tenant)
  end

  defp instance_ids(tenant) do
    Instance
    |> Ash.read!(authorize?: false, tenant: tenant)
    |> Enum.map(& &1.id)
  end

  defp redrives(tenant), do: Ash.read!(Redrive, authorize?: false, tenant: tenant)

  defp restore_env(key, nil), do: Application.delete_env(:ash_bpmn, key)
  defp restore_env(key, value), do: Application.put_env(:ash_bpmn, key, value)
end
