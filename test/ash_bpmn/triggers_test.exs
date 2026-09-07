# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.TriggersTest do
  @moduledoc """
  The triggers extension resources: `Subscription` (TRD §4.1), `Cursor` (§4.2)
  and `Dispatch` (§4.3).

  These run against the tenant-scoped instantiations
  (`AshBpmn.TenantTest.*`) on purpose: the subscription's version sequence is
  per key *within the tenant*, and the cursor is one row per tenant, so an
  untenanted instantiation would prove nothing worth proving.
  """

  use AshBpmn.DataCase, async: false

  require Ash.Query

  alias AshBpmn.Runtime.DomainResolver
  alias AshBpmn.Scope
  alias AshBpmn.TenantTest.{Cursor, Dispatch, Subscription}

  @acme Ecto.UUID.generate()
  @globex Ecto.UUID.generate()

  setup do
    previous_source = Application.get_env(:ash_bpmn, :event_source)
    previous_resolver = Application.get_env(:ash_bpmn, :decision_resolver)

    Application.put_env(:ash_bpmn, :event_source, TriggerTest.EventSource)
    Application.put_env(:ash_bpmn, :decision_resolver, TriggerTest.DecisionResolver)
    TriggerTest.DecisionResolver.set_exists?(true)

    on_exit(fn ->
      restore_env(:event_source, previous_source)
      restore_env(:decision_resolver, previous_resolver)
    end)

    :ok
  end

  # ── Subscription: lifecycle ───────────────────────────────────────────

  describe "Subscription lifecycle" do
    test "create assigns version 1 and the TRD defaults" do
      sub =
        subscribe!("defaults", @acme)

      assert sub.version == 1
      assert sub.status == :draft
      assert sub.enabled == true
      assert sub.source == :standalone
      assert sub.kind == :message
      assert sub.route_kind == :static
      assert sub.subject_of == "event.record_id"
      assert sub.variable_mapping == %{}
      assert sub.max_starts_per_event == 1
      assert sub.lookback_minutes == 0
      assert sub.definition_id == nil
      assert sub.node_id == nil
      assert sub.signal_name == nil
      assert sub.correlation_key_feel == nil
      assert sub.guard_feel == nil
      assert sub.compiled == nil
    end

    test "versions are a per-key sequence, and per tenant" do
      v1 = subscribe!("sequence", @acme)
      assert v1.version == 1

      publish!(v1)

      # Publish one-way: the draft is gone, so the next draft is version 2.
      v2 = subscribe!("sequence", @acme)
      assert v2.version == 2

      publish!(v2)
      assert subscribe!("sequence", @acme).version == 3

      # Another tenant's sequence starts at 1 -- a version number that means
      # different things to different tenants would be worse than none.
      assert subscribe!("sequence", @globex).version == 1
    end

    test "a second draft for the same key is refused" do
      subscribe!("draft_unique", @acme)

      assert_raise Ash.Error.Invalid, ~r/draft already exists/i, fn ->
        subscribe!("draft_unique", @acme)
      end
    end

    test "publish stamps the compiled form and is one-way" do
      sub =
        subscribe!("stamp", @acme, %{
          guard_feel: "event.amount > 100",
          subject_of: "event.record_id",
          correlation_key_feel: "metadata.correlation_id"
        })

      published = publish!(sub)

      assert published.status == :published

      assert published.compiled["guard"] == %{
               "language" => "feel",
               "text" => "event.amount > 100"
             }

      assert published.compiled["subject_of"]["text"] == "event.record_id"

      assert published.compiled["correlation_key_feel"]["text"] ==
               "metadata.correlation_id"

      # Which engine agreed the expressions were valid at publish time is a
      # fact about the subscription, stamped where an upgrade can be seen.
      assert published.compiled["feel_engine"]["name"] == "boxic_feel"
      assert is_binary(published.compiled["feel_engine"]["version"])

      # One-way.
      assert_raise Ash.Error.Invalid, ~r/draft/i, fn ->
        Subscription.publish!(published, engine_scope(@acme))
      end

      retired = Subscription.retire!(published, engine_scope(@acme))
      assert retired.status == :retired

      assert_raise Ash.Error.Invalid, ~r/published/i, fn ->
        Subscription.retire!(retired, engine_scope(@acme))
      end

      assert_raise Ash.Error.Invalid, ~r/draft/i, fn ->
        Subscription.publish!(retired, engine_scope(@acme))
      end
    end

    test "enable and disable are operational, not deployment acts" do
      published = publish!(subscribe!("switch", @acme))

      disabled = Subscription.disable!(published, engine_scope(@acme))

      # The deployment state is untouched, and the subscription is still what
      # is deployed -- disabling is not retroactive (see the moduledoc): the
      # sweep decides at dispatch time, not by rewriting history.
      assert disabled.status == :published
      assert disabled.enabled == false
      assert [%{enabled: false}] = Subscription.latest_published!("switch", engine_scope(@acme))

      re_enabled = Subscription.enable!(disabled, engine_scope(@acme))
      assert re_enabled.enabled == true
      assert re_enabled.status == :published
    end

    test "by_key_version fetches by identity, latest_published the highest version" do
      v1 = publish!(subscribe!("fetch", @acme))
      v2 = publish!(subscribe!("fetch", @acme))

      assert Subscription.by_key_version!("fetch", 1, engine_scope(@acme)).id == v1.id
      assert Subscription.by_key_version!("fetch", 2, engine_scope(@acme)).id == v2.id

      assert [%{version: 2}] = Subscription.latest_published!("fetch", engine_scope(@acme))

      # A retired version stops being the published answer.
      Subscription.retire!(v2, engine_scope(@acme))
      assert [%{version: 1}] = Subscription.latest_published!("fetch", engine_scope(@acme))
    end

    test "match_resource is accepted in either spelling and stored in the short one" do
      sub =
        subscribe!("normalize", @acme, %{match_resource: "Elixir.TriggerTest.Payout"})

      assert sub.match_resource == "TriggerTest.Payout"
    end
  end

  # ── Subscription: publish refusals ────────────────────────────────────

  describe "Subscription publish refusals" do
    test "a guard that does not parse is refused, naming the guard" do
      sub = subscribe!("guard_parse", @acme, %{guard_feel: "amount >"})

      error = publish_error(sub)
      assert Exception.message(error) =~ ~r/guard.*not valid FEEL/i
      assert still_draft?(sub)
    end

    test "a guard that provably produces a non-boolean is refused" do
      sub = subscribe!("guard_boolean", @acme, %{guard_feel: "1 + 2"})

      error = publish_error(sub)
      assert Exception.message(error) =~ ~r/boolean/i
      assert still_draft?(sub)
    end

    test "a guard over the event context publishes -- null is a runtime fact, not a refusal" do
      # "event.amount > 100" evaluates to FEEL null against the empty publish
      # context: a missing path, not a non-boolean. The dispatch row is where
      # a null guard becomes visible (:guard_null), not the publish action.
      published =
        publish!(subscribe!("guard_null_ok", @acme, %{guard_feel: "event.amount > 100"}))

      assert published.status == :published
    end

    test "a subject_of that does not parse is refused" do
      sub = subscribe!("subject_parse", @acme, %{subject_of: "event.record_id +("})

      error = publish_error(sub)
      assert Exception.message(error) =~ ~r/subject_of/i
    end

    test "a correlation_key_feel that does not parse is refused" do
      sub =
        subscribe!("corr_parse", @acme, %{correlation_key_feel: "1 = "})

      error = publish_error(sub)
      assert Exception.message(error) =~ ~r/correlation_key_feel/i
    end

    test "an unaudited resource is refused, named" do
      sub = subscribe!("unaudited", @acme, %{match_resource: "TriggerTest.Unaudited"})

      error = publish_error(sub)
      assert Exception.message(error) =~ "TriggerTest.Unaudited"
      assert Exception.message(error) =~ ~r/not audited/
    end

    test "a name that is not a loadable resource is refused" do
      sub = subscribe!("not_a_resource", @acme, %{match_resource: "NoSuchResource.Anywhere"})

      error = publish_error(sub)
      assert Exception.message(error) =~ "NoSuchResource.Anywhere"
      assert Exception.message(error) =~ ~r/not a loadable Ash resource/
    end

    test "a missing event source is refused, naming the config" do
      Application.delete_env(:ash_bpmn, :event_source)

      sub = subscribe!("no_source", @acme)

      error = publish_error(sub)
      assert Exception.message(error) =~ "no event source is configured"
      assert Exception.message(error) =~ "config :ash_bpmn, event_source"
    end

    test "a cycle resource is refused, named" do
      sub = subscribe!("cycle", @acme, %{match_resource: "AshBpmn.TenantTest.Instance"})

      error = publish_error(sub)
      assert Exception.message(error) =~ "AshBpmn.TenantTest.Instance"
      assert Exception.message(error) =~ ~r/may not match/
    end

    test "kind :signal is the one exception to the cycle refusal" do
      # Audited by fiat in the double (see test/support/triggers.ex), so this
      # proves the *cycle* check is what passes, not the audit check.
      published =
        publish!(
          subscribe!("signal_exception", @acme, %{
            kind: :signal,
            signal_name: "payout.approved",
            match_resource: "AshBpmn.TenantTest.Dispatch",
            match_action: nil,
            match_action_type: nil
          })
        )

      assert published.status == :published
    end

    test "a :signal subscription without a signal_name is refused" do
      # Enforced at create as well as publish: a :signal subscription that
      # hears nothing should not exist.
      assert_raise Ash.Error.Invalid, ~r/signal_name/, fn ->
        subscribe!("signal_unnamed", @acme, %{
          kind: :signal,
          match_resource: "TriggerTest.Payout"
        })
      end
    end

    test "a decision that does not exist is refused" do
      TriggerTest.DecisionResolver.set_exists?(false)

      sub =
        subscribe!(
          "missing_decision",
          @acme,
          %{route_kind: :decision, decision_key: "pricing.tier", process_key: nil}
        )

      error = publish_error(sub)
      assert Exception.message(error) =~ "pricing.tier"
      assert Exception.message(error) =~ ~r/does not exist/
    end

    test "a missing decision resolver is refused, naming the config" do
      Application.delete_env(:ash_bpmn, :decision_resolver)

      sub =
        subscribe!(
          "no_resolver",
          @acme,
          %{route_kind: :decision, decision_key: "pricing.tier", process_key: nil}
        )

      error = publish_error(sub)
      assert Exception.message(error) =~ "decision_resolver"
    end

    test "a decision that exists publishes" do
      sub =
        subscribe!(
          "decision_ok",
          @acme,
          %{route_kind: :decision, decision_key: "pricing.tier", process_key: nil}
        )

      assert publish!(sub).status == :published
    end

    test "a :static route without a process_key is refused" do
      # Enforced at create as well as publish: a draft that has nothing to do
      # should not exist, not merely fail later.
      assert_raise Ash.Error.Invalid, ~r/process_key/, fn ->
        subscribe!("no_target", @acme, %{process_key: nil})
      end
    end

    defp publish_error(sub) do
      # Refusals accumulate across the ordered validations; the test asserts
      # on the message of the validation it provoked.
      {:error, error} = Subscription.publish(sub, engine_scope(@acme))
      error
    end

    # Whether the constraint surfaces as a mapped identity error or as the raw
    # duplicate-key error depends on how the index is named; what must hold is
    # that the replay is *refused*, with the uniqueness visible in the message.
    defp assert_duplicate_refused!(fun) do
      error = catch_error(fun.())

      assert Exception.message(error) =~ ~r/already been taken|duplicate|unique/i
    end

    defp still_draft?(sub) do
      reloaded = Subscription.by_key_version!(sub.key, sub.version, engine_scope(@acme))
      reloaded.status == :draft and reloaded.compiled == nil
    end
  end

  # ── Dispatch ──────────────────────────────────────────────────────────

  describe "Dispatch" do
    test "records a start dispatch" do
      sub = publish!(subscribe!("dispatch_start", @acme))

      dispatch =
        Dispatch.create!(
          %{
            subscription_id: sub.id,
            event_id: Ash.UUID.generate(),
            event_sequence: 7,
            event_occurred_at: DateTime.utc_now(),
            kind: :start,
            status: :started,
            process_key: "onboarding",
            instance_id: Ash.UUID.generate(),
            depth: 0
          },
          engine_scope(@acme)
        )

      assert dispatch.status == :started
      assert dispatch.reason == nil
      assert dispatch.depth == 0
    end

    test "a replayed event hits :once_per_event -- the identity wins" do
      sub = publish!(subscribe!("dispatch_replay", @acme))
      event_id = Ash.UUID.generate()
      occurred_at = DateTime.utc_now()

      Dispatch.create!(
        %{
          subscription_id: sub.id,
          event_id: event_id,
          event_sequence: 8,
          event_occurred_at: occurred_at,
          kind: :start,
          status: :started
        },
        engine_scope(@acme)
      )

      # A sweep that crashes mid-batch replays it; the identity turns the
      # replay into a refusal rather than a second process.
      assert_duplicate_refused!(fn ->
        Dispatch.create!(
          %{
            subscription_id: sub.id,
            event_id: event_id,
            event_sequence: 8,
            event_occurred_at: occurred_at,
            kind: :start,
            status: :started
          },
          engine_scope(@acme)
        )
      end)
    end

    test "catch delivery dedupes on :once_per_token_event" do
      token_id = Ash.UUID.generate()
      event_id = Ash.UUID.generate()
      occurred_at = DateTime.utc_now()

      Dispatch.create!(
        %{
          waiting_token_id: token_id,
          event_id: event_id,
          event_sequence: 9,
          event_occurred_at: occurred_at,
          kind: :catch,
          status: :delivered
        },
        engine_scope(@acme)
      )

      assert_duplicate_refused!(fn ->
        Dispatch.create!(
          %{
            waiting_token_id: token_id,
            event_id: event_id,
            event_sequence: 9,
            event_occurred_at: occurred_at,
            kind: :catch,
            status: :delivered
          },
          engine_scope(@acme)
        )
      end)

      # A different waiting token may hear the same event.
      Dispatch.create!(
        %{
          waiting_token_id: Ash.UUID.generate(),
          event_id: event_id,
          event_sequence: 9,
          event_occurred_at: occurred_at,
          kind: :catch,
          status: :delivered
        },
        engine_scope(@acme)
      )
    end

    test "one event can be both a start dispatch and a catch dispatch" do
      sub = publish!(subscribe!("both_sides", @acme))
      event_id = Ash.UUID.generate()
      occurred_at = DateTime.utc_now()

      start_dispatch =
        Dispatch.create!(
          %{
            subscription_id: sub.id,
            event_id: event_id,
            event_sequence: 10,
            event_occurred_at: occurred_at,
            kind: :start,
            status: :started
          },
          engine_scope(@acme)
        )

      catch_dispatch =
        Dispatch.create!(
          %{
            waiting_token_id: Ash.UUID.generate(),
            event_id: event_id,
            event_sequence: 10,
            event_occurred_at: occurred_at,
            kind: :catch,
            status: :delivered
          },
          engine_scope(@acme)
        )

      # The partial indexes never overlap: the nil side does not participate.
      assert start_dispatch.id != catch_dispatch.id
    end

    test "a dispatch with neither subscription nor token is refused" do
      error =
        catch_error(
          Dispatch.create!(
            %{
              event_id: Ash.UUID.generate(),
              event_sequence: 11,
              event_occurred_at: DateTime.utc_now(),
              kind: :start,
              status: :failed,
              reason: :no_definition
            },
            engine_scope(@acme)
          )
        )

      assert Exception.message(error) =~ ~r/subscription_id or a waiting_token_id/
    end

    test "the status and reason taxonomy from the TRD table" do
      sub = publish!(subscribe!("taxonomy", @acme))
      now = DateTime.utc_now()

      for {status, reason} <- [
            {:started, nil},
            {:delivered, nil},
            {:skipped, :guard_null},
            {:skipped, :fan_out_exceeded},
            {:skipped, :disabled},
            {:failed, :decision_error},
            {:failed, :no_definition},
            {:failed, :depth_exceeded}
          ] do
        row =
          Dispatch.create!(
            %{
              subscription_id: sub.id,
              event_id: Ash.UUID.generate(),
              event_sequence: 12,
              event_occurred_at: now,
              kind: :start,
              status: status,
              reason: reason
            },
            engine_scope(@acme)
          )

        assert row.status == status
        assert row.reason == reason
      end

      assert_raise Ash.Error.Invalid, fn ->
        Dispatch.create!(
          %{
            subscription_id: sub.id,
            event_id: Ash.UUID.generate(),
            event_sequence: 12,
            event_occurred_at: now,
            kind: :start,
            status: :deleted,
            reason: :because
          },
          engine_scope(@acme)
        )
      end
    end

    test "append-only: there is no update and no destroy" do
      assert Ash.Resource.Info.action(Dispatch, :update) == nil
      assert Ash.Resource.Info.action(Dispatch, :destroy) == nil
      assert Ash.Resource.Info.action(Dispatch, :create) != nil
      assert Ash.Resource.Info.action(Dispatch, :read) != nil
    end
  end

  # ── Cursor ────────────────────────────────────────────────────────────

  describe "Cursor" do
    test "one row per tenant, created by upsert" do
      first = Cursor.create!(%{}, engine_scope(@acme))
      assert first.last_sequence == 0
      assert first.last_dispatched_at == nil

      # "Ensure it exists" is the operation: a second create hands back the
      # row that is already there.
      again = Cursor.create!(%{}, engine_scope(@acme))
      assert again.id == first.id

      # And another tenant gets its own.
      other = Cursor.create!(%{}, engine_scope(@globex))
      assert other.id != first.id

      assert Enum.count(read_cursors!(@acme)) == 1
      assert Enum.count(read_cursors!(@globex)) == 1
    end

    test "advance moves the high-water mark and stamps when" do
      cursor = Cursor.create!(%{last_sequence: 5}, engine_scope(@acme))

      advanced = Cursor.advance!(cursor, 42, engine_scope(@acme))

      assert advanced.last_sequence == 42
      assert advanced.last_dispatched_at != nil
    end

    test "lag_seconds is nil before the first advance, seconds after" do
      cursor = Cursor.create!(%{}, engine_scope(@acme))
      assert Ash.load!(cursor, :lag_seconds).lag_seconds == nil

      advanced = Cursor.advance!(cursor, 1, engine_scope(@acme))
      lag = Ash.load!(advanced, :lag_seconds).lag_seconds

      # A stalled dispatcher should be a detected condition; this is what a
      # health check reads.
      assert is_integer(lag)
      assert lag >= 0
      assert lag < 60
    end
  end

  # ── Catalogue and domain discovery ────────────────────────────────────

  describe "catalogue and domain discovery" do
    test "kind/1 knows the trigger kinds" do
      assert AshBpmn.Resources.kind(AshBpmn.TenantTest.Subscription) == :subscription
      assert AshBpmn.Resources.kind(AshBpmn.TenantTest.Cursor) == :cursor
      assert AshBpmn.Resources.kind(AshBpmn.TenantTest.Dispatch) == :dispatch
    end

    test "for_domain/1 returns the trigger kinds when a domain installs them" do
      assert {:ok, mapping} = AshBpmn.Resources.for_domain(AshBpmn.TenantTest.Domain)

      assert mapping.subscription == AshBpmn.TenantTest.Subscription
      assert mapping.cursor == AshBpmn.TenantTest.Cursor
      assert mapping.dispatch == AshBpmn.TenantTest.Dispatch

      # The core six are still what they always were.
      assert mapping.definition == AshBpmn.TenantTest.Definition
      assert mapping.instance == AshBpmn.TenantTest.Instance
    end

    test "for_domain/1 stays satisfied by the core six alone" do
      # The triggers extension is optional: a domain without it resolves
      # exactly as before, with the trigger keys nil. This is what keeps the
      # DomainResolver fallback ("the first domain with all six") honest.
      assert {:ok, mapping} = AshBpmn.Resources.for_domain(AshBpmn.Test.Domain)

      assert mapping.subscription == nil
      assert mapping.cursor == nil
      assert mapping.dispatch == nil
      assert mapping.definition == AshBpmn.Test.Definition
    end

    test "DomainResolver resolves a trigger domain by name" do
      resolved = DomainResolver.resolve!("Elixir.AshBpmn.TenantTest.Domain")

      assert resolved.subscription == AshBpmn.TenantTest.Subscription
      assert resolved.cursor == AshBpmn.TenantTest.Cursor
      assert resolved.dispatch == AshBpmn.TenantTest.Dispatch
    end

    test "DomainResolver's fallback still lands on the core-six domain" do
      resolved = DomainResolver.resolve!()

      assert resolved.instance == AshBpmn.Test.Instance
      # Not installed there -- and that is a fact the mapping states, not an
      # error.
      assert resolved.subscription == nil
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────────

  defp engine_scope(tenant), do: AshBpmn.Scope.engine(%Scope{tenant: tenant})

  defp subscribe!(key, tenant, overrides \\ %{}) do
    params =
      Map.merge(
        %{
          key: key,
          match_resource: "TriggerTest.Payout",
          match_action: :approve,
          match_action_type: :create,
          process_key: "onboarding"
        },
        overrides
      )

    Subscription.create!(params, engine_scope(tenant))
  end

  defp publish!(sub) do
    Subscription.publish!(sub, engine_scope(sub.organization_id))
  end

  defp read_cursors!(tenant) do
    Cursor
    |> Ash.Query.for_read(:read)
    |> Ash.read!(engine_scope(tenant))
  end

  defp restore_env(key, nil), do: Application.delete_env(:ash_bpmn, key)
  defp restore_env(key, value), do: Application.put_env(:ash_bpmn, key, value)
end
