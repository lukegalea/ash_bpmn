# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.AshCallTest do
  @moduledoc """
  The `ash:call` service-task binding, driven through the engine.

  What matters beyond the happy path: the FEEL inputs arrive at the callee
  *evaluated* (the engine, not the host, evaluates them), a promoted signal reaches
  the token's routing and is visible to a following gateway, every call travels on
  the engine scope — a callable whose policy admits only the engine interaction
  bypass is reachable, and nothing else is — and an erroring callable fails the
  node the way every other node failure does: raise, retry, instance fails.
  """

  use AshBpmn.DataCase, async: false

  require Ash.Query

  alias AshBpmn.Test.{CallablesEnrollee, CallablesRecorder, Definition}

  setup do
    CallablesRecorder.clear()
    :ok
  end

  describe "execution" do
    test "inputs arrive evaluated and the promoted signal routes a following gateway" do
      xml = File.read!("test/fixtures/ash_call.bpmn")
      _defn = create_published_definition!("ash_call_high", xml)

      subject = create_test_subject!("ash_call_high_subject", amount: 5000)

      {:ok, instance} =
        AshBpmn.start_instance(AshBpmn.Test.Domain, process: "ash_call_high", subject: subject)

      # The high branch: the promoted tier reached routing, the gateway read it, and
      # the process ended on the escalated outcome.
      assert instance.status == :completed
      assert instance.outcome == :escalated

      assert [record] =
               CallablesRecorder.recorded()
               |> Enum.filter(&(&1.action == "record_inputs"))

      # FEEL numbers are decimal; the promoted signal arrives as the string the
      # token carries.
      assert Decimal.compare(record.arguments["amount"], Decimal.new(5000)) == :eq
      assert record.arguments["tier"] == "high"

      # Each call is recorded as an action_invoked event carrying the ref; the
      # assessing node's event is the one that promoted.
      [event] =
        process_events(instance.id, :action_invoked)
        |> Enum.filter(&(&1.node_id == "AssessCall"))

      assert event.data["action"] == "AshBpmn.Test.RuntimeCallablesDomain.assess_tier"
      assert event.data["promoted"] == %{"tier" => "high"}
    end

    test "the default branch routes when the promoted signal does not match" do
      xml = File.read!("test/fixtures/ash_call.bpmn")
      _defn = create_published_definition!("ash_call_low", xml)

      subject = create_test_subject!("ash_call_low_subject", amount: 10)

      {:ok, instance} =
        AshBpmn.start_instance(AshBpmn.Test.Domain, process: "ash_call_low", subject: subject)

      assert instance.status == :completed
      assert instance.outcome == :approved
    end

    test "a create callable goes through Ash.create" do
      xml = File.read!("test/fixtures/ash_call_create.bpmn")
      _defn = create_published_definition!("ash_call_create", xml)

      subject = create_test_subject!("ash_call_create_subject")

      {:ok, instance} =
        AshBpmn.start_instance(AshBpmn.Test.Domain,
          process: "ash_call_create",
          subject: subject
        )

      assert instance.status == :completed

      rows =
        CallablesEnrollee
        |> Ash.Query.for_read(:read)
        |> Ash.Query.filter(name == ^subject.name)
        |> Ash.read!(authorize?: false)

      assert rows != [], "expected an enrolled row named #{subject.name}"
    end

    test "a callable whose policy admits only the engine proves the call carried the engine scope" do
      xml = File.read!("test/fixtures/ash_call_guarded.bpmn")
      _defn = create_published_definition!("ash_call_guarded", xml)

      subject = create_test_subject!("ash_call_guarded_subject")

      # The policy forbids every actor; only the engine interaction bypass admits
      # the call. If this completes, the scope travelled.
      {:ok, instance} =
        AshBpmn.start_instance(AshBpmn.Test.Domain,
          process: "ash_call_guarded",
          subject: subject
        )

      assert instance.status == :completed

      assert [record] =
               CallablesRecorder.recorded()
               |> Enum.filter(&(&1.action == "engine_only"))

      # Not `authorize? bypassed` — the private context flag the engine scope sets
      # is what the bypass matched on, and the callee saw it.
      assert record.engine_context? == true
    end

    # How the failure presents under `oban_testing: :inline`: there is no Oban
    # between the caller and the node, so the raise arrives here directly, the same
    # way a business rule task's failure does. Asserting a `:failed` instance would
    # be asserting something inline mode does not do.
    test "an erroring callable fails the node" do
      xml = File.read!("test/fixtures/ash_call_failing.bpmn")
      _defn = create_published_definition!("ash_call_failing", xml)

      subject = create_test_subject!("ash_call_failing_subject")

      assert_raise RuntimeError, ~r/ash:call/, fn ->
        AshBpmn.start_instance!(AshBpmn.Test.Domain,
          process: "ash_call_failing",
          subject: subject
        )
      end
    end
  end

  describe "legacy binding" do
    test "a taskConfig service task still dispatches through the invoker" do
      xml = File.read!("test/fixtures/linear.bpmn")
      AshBpmn.Test.Invoker.clear_calls()
      _defn = create_published_definition!("ash_call_legacy", xml)

      subject = create_test_subject!("ash_call_legacy_subject")

      {:ok, instance} =
        AshBpmn.start_instance(AshBpmn.Test.Domain,
          process: "ash_call_legacy",
          subject: subject
        )

      assert instance.status == :completed

      calls = AshBpmn.Test.Invoker.recorded_calls()
      assert Enum.any?(calls, fn {_id, action, _ts} -> action == "do_something" end)
      assert CallablesRecorder.recorded() == []
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  defp create_published_definition!(key, xml) do
    defn = Definition.create!(%{key: key, name: "Test #{key}", xml: xml})

    if defn.graph do
      AshBpmn.TestRepo.query!(
        "UPDATE bpmn_definitions SET status = 'published' WHERE id = '#{defn.id}'"
      )

      Definition.by_key_version!(defn.key, defn.version)
    else
      raise "Definition #{key} failed to compile: #{inspect(defn.errors)}"
    end
  end

  defp create_test_subject!(name, overrides \\ []) do
    attrs = %{
      name: name,
      amount: Keyword.get(overrides, :amount, 0),
      is_privileged: Keyword.get(overrides, :is_privileged, false),
      created_by_id: Keyword.get(overrides, :created_by_id)
    }

    # `create!/1` here returns `{:ok, subject}` rather than the record; matching both
    # keeps this helper identical to the one in engine_test.exs.
    case AshBpmn.Test.Subject.create!(attrs) do
      {:ok, subject} -> subject
      subject when is_map(subject) -> subject
    end
  end

  defp process_events(instance_id, kind) do
    AshBpmn.Test.ProcessEvent
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(instance_id == ^instance_id)
    |> Ash.Query.filter(kind == ^kind)
    |> Ash.read!(authorize?: false)
  end
end
