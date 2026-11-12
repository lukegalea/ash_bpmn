# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.RecipesDeliveryTest do
  @moduledoc """
  The delivery claims a subscription makes, each pinned by the case that used to break it:

    * a funnel that raises leaves a `:failed` row, and the cursor passes the event only once
      that row exists;
    * publishing version 2 retires version 1 in the same transaction, so one event starts one
      process, whichever side of the publish it committed on;
    * a process that writes the resource its own subscription watches stops at
      `trigger_max_depth`, and a signal's depth reaches the correlator;
    * a `:failed` row does not occupy the dispatch identity, so the event can be re-driven.

  The refusals come first in each describe, because that is where the claims were false.
  """

  use AshBpmn.DataCase, async: false

  require Ash.Query

  alias AshBpmn.Runtime.DomainResolver
  alias AshBpmn.Scope
  alias AshBpmn.TenantTest.{Cursor, Definition, Dispatch, Instance, Subscription}
  alias AshBpmn.Triggers.Correlator

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

    Cursor.create!(%{last_sequence: 0}, engine_scope(@acme))
    Cursor.create!(%{last_sequence: 0}, engine_scope(@globex))

    on_exit(fn ->
      restore_env(:event_source, previous_source)
      restore_env(:decision_resolver, previous_resolver)
      TriggerTest.DecisionResolver.set_decide(:default)
    end)

    :ok
  end

  # ── a. A funnel that raises ───────────────────────────────────────────

  describe "a funnel that raises" do
    test "an event whose funnel aborts leaves a failed row" do
      publish_definition!(@acme, "onboarding_sweep")

      sub =
        subscribe!(@acme, "routed", %{
          process_key: nil,
          route_kind: :decision,
          decision_key: "routing"
        })

      # The resolver raises for one event, which nothing in the funnel rescues: the event's
      # transaction aborts. The other event routes normally.
      TriggerTest.DecisionResolver.set_decide(fn _ref, inputs, _ctx ->
        if get_in(inputs, ["data", "boom"]) == true do
          raise "the routing table could not be read"
        else
          {:ok, %{outputs: %{"process_key" => "onboarding_sweep"}}}
        end
      end)

      aborted = TriggerTest.EventSource.append!(@acme, %{data: %{"boom" => true}})
      fine = TriggerTest.EventSource.append!(@acme)

      assert :ok = sweep!(@acme)

      rows = dispatches!(@acme, sub.id)

      assert [failed] = Enum.filter(rows, &(&1.event_id == aborted.id)),
             "the aborted event must leave a row, not vanish behind the cursor"

      assert failed.status == :failed
      assert failed.reason == :funnel_error
      assert failed.error =~ "the routing table could not be read"
      assert failed.instance_id == nil
      assert failed.event_sequence == aborted.sequence

      assert [%{status: :started}] = Enum.filter(rows, &(&1.event_id == fine.id))
      assert cursor!(@acme).last_sequence == fine.sequence
    end

    test "a context that cannot be built fails every subscription the event could have reached" do
      publish_definition!(@acme, "onboarding_sweep")
      one = subscribe!(@acme, "first", %{process_key: "onboarding_sweep"})
      two = subscribe!(@acme, "second", %{process_key: "onboarding_sweep"})

      poisoned = TriggerTest.EventSource.append!(@acme)
      TriggerTest.EventSource.poison_context!(poisoned)

      assert :ok = sweep!(@acme)

      for sub <- [one, two] do
        assert [%{status: :failed, reason: :funnel_error, error: error}] =
                 dispatches!(@acme, sub.id)

        assert error =~ "poisoned context"
      end

      assert instance_ids!(@acme) == []
      assert cursor!(@acme).last_sequence == poisoned.sequence
    end

    test "the cursor does not pass an aborted event whose failed row cannot be written" do
      publish_definition!(@acme, "onboarding_sweep")
      subscribe!(@acme, "unrecordable", %{process_key: "onboarding_sweep"})

      # No id: the context raises, and there is nothing to name the event by, so no row can
      # be written for it. Moving on would lose it; the sweep must fail instead.
      unnamed = TriggerTest.EventSource.append!(@acme, %{id: nil})
      TriggerTest.EventSource.poison_context!(unnamed)

      assert_raise RuntimeError, ~r/could not record/, fn -> sweep!(@acme) end
      assert cursor!(@acme).last_sequence == 0
    end
  end

  # ── b. Version 2 retires version 1 ────────────────────────────────────

  describe "publishing a second version" do
    test "one event starts one process after v2 is published" do
      publish_definition!(@acme, "onboarding_sweep")
      v1 = subscribe!(@acme, "rule", %{process_key: "onboarding_sweep"})

      # Committed while v1 was in force, not yet swept.
      before_publish = TriggerTest.EventSource.append!(@acme)

      v2 = subscribe!(@acme, "rule", %{process_key: "onboarding_sweep"})
      assert v2.version == v1.version + 1

      v1 = Subscription.by_key_version!("rule", v1.version, engine_scope(@acme))
      assert v1.status == :retired, "publishing v2 must retire v1 in the same transaction"
      assert v1.retired_sequence == before_publish.sequence
      assert v2.effective_sequence == before_publish.sequence

      after_publish = TriggerTest.EventSource.append!(@acme)

      sweep!(@acme)

      # Each event once, under the version in force when it committed.
      assert [%{status: :started, event_id: id_one}] = dispatches!(@acme, v1.id)
      assert id_one == before_publish.id
      assert [%{status: :started, event_id: id_two}] = dispatches!(@acme, v2.id)
      assert id_two == after_publish.id
      assert length(instance_ids!(@acme)) == 2

      # A replay of the earlier event offered to v2 starts nothing: it is not v2's.
      replay!(@acme, before_publish, [v2])
      assert [_] = dispatches!(@acme, v2.id)
      assert length(instance_ids!(@acme)) == 2
    end

    # The trigger index lists published, enabled subscriptions only. A superseded version
    # still finishing its window is not among them, and its backlog must not be skipped
    # behind that gate.
    test "v1's backlog is dispatched when v2 no longer matches the event" do
      start_supervised!(AshBpmn.Triggers.Index)
      publish_definition!(@acme, "onboarding_sweep")
      v1 = subscribe!(@acme, "rule", %{})
      backlog = TriggerTest.EventSource.append!(@acme)

      # v2 narrows the action type: the index now lists only (Payout, update).
      _v2 = subscribe!(@acme, "rule", %{match_action_type: :update})
      assert :ok = AshBpmn.Triggers.Index.reload!()
      refute AshBpmn.Triggers.Index.interested?("TriggerTest.Payout", "create")

      sweep!(@acme)

      assert [%{status: :started, event_id: event_id}] = dispatches!(@acme, v1.id)
      assert event_id == backlog.id
    end

    test "v1's backlog is dispatched when v2 has been disabled" do
      start_supervised!(AshBpmn.Triggers.Index)
      publish_definition!(@acme, "onboarding_sweep")
      v1 = subscribe!(@acme, "rule", %{})
      backlog = TriggerTest.EventSource.append!(@acme)

      v2 = subscribe!(@acme, "rule", %{})
      Subscription.disable!(v2, engine_scope(@acme))
      assert :ok = AshBpmn.Triggers.Index.reload!()
      refute AshBpmn.Triggers.Index.interested?("TriggerTest.Payout", "create")

      sweep!(@acme)

      assert [%{status: :started, event_id: event_id}] = dispatches!(@acme, v1.id)
      assert event_id == backlog.id
    end

    test "a funnel error in v1's backlog leaves a failed row when the index has moved on" do
      start_supervised!(AshBpmn.Triggers.Index)
      publish_definition!(@acme, "onboarding_sweep")

      v1 =
        subscribe!(@acme, "routed", %{
          process_key: nil,
          route_kind: :decision,
          decision_key: "routing"
        })

      TriggerTest.DecisionResolver.set_decide(fn _ref, _inputs, _ctx ->
        raise "the routing table could not be read"
      end)

      backlog = TriggerTest.EventSource.append!(@acme)

      _v2 =
        subscribe!(@acme, "routed", %{
          process_key: nil,
          route_kind: :decision,
          decision_key: "routing",
          match_action_type: :update
        })

      assert :ok = AshBpmn.Triggers.Index.reload!()

      assert :ok = sweep!(@acme)

      assert [%{status: :failed, reason: :funnel_error, event_id: event_id}] =
               dispatches!(@acme, v1.id)

      assert event_id == backlog.id
    end

    test "a later version in another tenant leaves this tenant's version live" do
      publish_definition!(@acme, "onboarding_sweep")
      acme_v1 = subscribe!(@acme, "shared_key", %{process_key: "onboarding_sweep"})
      _globex_v1 = subscribe!(@globex, "shared_key", %{process_key: "onboarding_sweep"})

      acme_v1 = Subscription.by_key_version!("shared_key", acme_v1.version, engine_scope(@acme))
      assert acme_v1.status == :published
      assert acme_v1.retired_sequence == nil
    end
  end

  # ── c. Depth ──────────────────────────────────────────────────────────

  describe "trigger depth" do
    test "a process whose service task writes its watched resource stops at trigger_max_depth" do
      max = AshBpmn.Config.trigger_max_depth()
      publish_definition!(@acme, "loop", "test/fixtures/ash_call_loop.bpmn")
      sub = subscribe!(@acme, "loops", %{process_key: "loop"})

      # A person's write, at depth zero.
      TriggerTest.EventSource.append!(@acme)

      for _ <- 1..(max + 2), do: sweep!(@acme)

      rows = dispatches!(@acme, sub.id)

      assert Enum.map(rows, & &1.depth) == Enum.to_list(1..(max + 1)),
             "each lap is one hop deeper, and the lap past the bound is the last"

      {started, [refused]} = Enum.split(rows, max)
      assert Enum.all?(started, &(&1.status == :started))
      assert refused.status == :failed
      assert refused.reason == :depth_exceeded
      assert refused.instance_id == nil

      # The instance records the hop it was started at.
      for row <- started do
        assert instance!(row.instance_id).trigger_depth == row.depth
      end

      assert length(instance_ids!(@acme)) == max
    end

    test "a signal's depth reaches the correlator" do
      publish_definition!(@acme, "onboarding_sweep")
      max = AshBpmn.Config.trigger_max_depth()

      sub =
        Subscription.create!(
          %{
            key: "heard",
            kind: :signal,
            signal_name: "ping",
            match_resource:
              AshBpmn.Resources.Subscription.ResourceName.short(AshBpmn.TenantTest.Signal),
            process_key: "onboarding_sweep"
          },
          engine_scope(@acme)
        )

      # A signal thrown by an instance at the bound carries depth max + 1 on its row.
      too_deep =
        TriggerTest.EventSource.append!(@acme, %{
          resource: AshBpmn.TenantTest.Signal,
          action: :emit,
          data: %{"name" => "ping", "depth" => max + 1}
        })

      shallow =
        TriggerTest.EventSource.append!(@acme, %{
          resource: AshBpmn.TenantTest.Signal,
          action: :emit,
          data: %{"name" => "ping", "depth" => 2}
        })

      replay!(@acme, too_deep, [sub])
      replay!(@acme, shallow, [sub])

      rows = dispatches!(@acme, sub.id)

      assert [%{status: :failed, reason: :depth_exceeded, depth: deep}] =
               Enum.filter(rows, &(&1.event_id == too_deep.id))

      assert deep == max + 1

      assert [%{status: :started, depth: 2, instance_id: instance_id}] =
               Enum.filter(rows, &(&1.event_id == shallow.id))

      assert instance!(instance_id).trigger_depth == 2
    end
  end

  # ── d. Re-drive ───────────────────────────────────────────────────────

  describe "re-drive" do
    test "a failed row can be re-driven" do
      sub = subscribe!(@acme, "redriven", %{process_key: "not_yet_published"})
      event = TriggerTest.EventSource.append!(@acme)

      sweep!(@acme)
      assert [%{status: :failed, reason: :no_definition}] = dispatches!(@acme, sub.id)

      # An ordinary replay of the batch does not retry a failure: the row is the record.
      replay!(@acme, event, [sub])
      assert [_] = dispatches!(@acme, sub.id)

      # The cause is fixed, and the event is driven again on purpose.
      publish_definition!(@acme, "not_yet_published")
      redrive!(@acme, event, [sub])

      rows = dispatches!(@acme, sub.id) |> Enum.sort_by(&{&1.inserted_at, &1.status})
      assert [:failed, :started] == rows |> Enum.map(& &1.status) |> Enum.sort()
      assert length(instance_ids!(@acme)) == 1

      # Driving it again finds the start and does nothing: at most one start per event.
      redrive!(@acme, event, [sub])
      assert length(dispatches!(@acme, sub.id)) == 2
      assert length(instance_ids!(@acme)) == 1
    end

    test "the dispatch identity admits a started row beside a failed one, and refuses a second start" do
      sub = subscribe!(@acme, "identity", %{process_key: "onboarding_sweep"})
      event_id = Ash.UUID.generate()

      row = fn status ->
        Dispatch.create(
          %{
            subscription_id: sub.id,
            event_id: event_id,
            event_sequence: 1,
            event_occurred_at: DateTime.utc_now(),
            kind: :start,
            status: status,
            reason: if(status == :failed, do: :no_definition)
          },
          engine_scope(@acme)
        )
      end

      assert {:ok, _} = row.(:failed)
      assert {:ok, _} = row.(:failed)
      assert {:ok, _} = row.(:started)
      assert {:error, _} = row.(:started)
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────────

  defp engine_scope(tenant), do: Scope.engine(%Scope{tenant: tenant})

  defp sweep!(tenant),
    do: AshBpmn.Triggers.SweepWorker.perform(%Oban.Job{args: %{"tenant" => tenant}})

  defp correlator_ctx(tenant) do
    domain = AshBpmn.TenantTest.Domain
    resources = DomainResolver.resolve!("Elixir.AshBpmn.TenantTest.Domain")

    %{
      scope: %Scope{tenant: tenant, actor: AshBpmn.SystemActor.sweep(), domain: domain},
      tenant: tenant,
      domain: domain,
      resources: resources,
      event_source: TriggerTest.EventSource
    }
  end

  # The sweep's own shape for one event: its own transaction.
  defp replay!(tenant, event, subscriptions) do
    AshBpmn.TestRepo.transaction(fn ->
      Correlator.dispatch_event(event, subscriptions, correlator_ctx(tenant))
    end)
  end

  defp redrive!(tenant, event, subscriptions) do
    AshBpmn.TestRepo.transaction(fn ->
      Correlator.dispatch_event(event, subscriptions, correlator_ctx(tenant), redrive: true)
    end)
  end

  defp publish_definition!(tenant, key, fixture \\ "test/fixtures/linear.bpmn") do
    xml = File.read!(fixture)

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
    |> Ash.Query.sort(event_sequence: :asc, inserted_at: :asc)
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
  end

  defp restore_env(key, nil), do: Application.delete_env(:ash_bpmn, key)
  defp restore_env(key, value), do: Application.put_env(:ash_bpmn, key, value)
end
