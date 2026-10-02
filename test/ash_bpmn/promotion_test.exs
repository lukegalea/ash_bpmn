# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.PromotionTest do
  @moduledoc """
  Output promotion through the engine: what a callee returns reaches the token's
  routing only through the promotion gate (AST-98).

  A struct result used to crash promotion outright — the struct was passed through
  as the outputs map, `Map.fetch/2` missed on its string key, and the atom-key
  fallback then enumerated a struct, which is not Enumerable
  (`Protocol.UndefinedError`). Nested outputs were unreachable: there was no
  dotted-path promotion, so a callee's nested result promoted nothing. Both are
  pinned here through the real `ash:call` path; the promotion contract itself is
  property-tested in `AshBpmn.PromotionPropertyTest`.
  """

  use AshBpmn.DataCase, async: false

  require Ash.Query

  alias AshBpmn.Test.Definition

  describe "struct results" do
    # The regression: this crashed with Protocol.UndefinedError before the fix —
    # the struct flowed into the promotion gate as if it were the outputs map.
    test "a callable that returns a struct promotes the named scalar" do
      xml = File.read!("test/fixtures/ash_call_struct.bpmn")
      _defn = create_published_definition!("ash_call_struct", xml)

      subject = create_test_subject!("ash_call_struct_subject")

      {:ok, instance} =
        AshBpmn.start_instance(AshBpmn.Test.Domain, process: "ash_call_struct", subject: subject)

      # The struct's `tier` reached routing and the gateway read it.
      assert instance.status == :completed
      assert instance.outcome == "escalated"

      [event] =
        process_events(instance.id, :action_invoked)
        |> Enum.filter(&(&1.node_id == "AssessStruct"))

      assert event.data["promoted"] == %{"tier" => "high"}
    end
  end

  describe "dotted paths" do
    test "a dotted promote path resolves into nested outputs" do
      xml = File.read!("test/fixtures/ash_call_dotted.bpmn")
      _defn = create_published_definition!("ash_call_dotted", xml)

      subject = create_test_subject!("ash_call_dotted_subject")

      {:ok, instance} =
        AshBpmn.start_instance(AshBpmn.Test.Domain, process: "ash_call_dotted", subject: subject)

      assert instance.status == :completed
      assert instance.outcome == "reviewed"

      [event] =
        process_events(instance.id, :action_invoked)
        |> Enum.filter(&(&1.node_id == "AssessNested"))

      # String and atom keys resolve at each level, the Decimal leaf is promoted
      # as its string, and the absent optional path promotes nothing.
      assert event.data["promoted"] == %{"probability" => "0.93", "verdict" => "escalate"}
    end

    test "a required signal whose dotted path is absent fails the node, named" do
      xml = File.read!("test/fixtures/ash_call_missing.bpmn")
      _defn = create_published_definition!("ash_call_missing", xml)

      subject = create_test_subject!("ash_call_missing_subject")

      assert_raise RuntimeError, ~r/required signal 'tier'/, fn ->
        AshBpmn.start_instance!(AshBpmn.Test.Domain,
          process: "ash_call_missing",
          subject: subject
        )
      end
    end
  end

  describe "non-scalars" do
    test "promoting a non-scalar fails the node with a structured error" do
      xml = File.read!("test/fixtures/ash_call_nonscalar.bpmn")
      _defn = create_published_definition!("ash_call_nonscalar", xml)

      subject = create_test_subject!("ash_call_nonscalar_subject")

      # The node, the path and the value's type — not a protocol crash.
      assert_raise RuntimeError, ~r/AssessDeep.*report\.findings.*list.*not a scalar/s, fn ->
        AshBpmn.start_instance!(AshBpmn.Test.Domain,
          process: "ash_call_nonscalar",
          subject: subject
        )
      end
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

  defp create_test_subject!(name) do
    attrs = %{
      name: name,
      amount: 0,
      is_privileged: false,
      created_by_id: nil
    }

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
