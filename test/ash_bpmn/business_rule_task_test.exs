# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.BusinessRuleTaskTest do
  @moduledoc """
  The third seam: a node that asks the host a question and routes on the answer.

  Two properties matter more than the happy path and are asserted first-class here. A decision
  must be *verified at publish time*, so a diagram cannot be shipped against a decision that
  does not exist. And only **declared, scalar** signals may reach the token, because a token
  carries routing and not business data — a rule that is worth nothing unless something
  enforces it.
  """

  use AshBpmn.DataCase, async: false

  require Ash.Query

  alias AshBpmn.Compiler
  alias AshBpmn.Test.{DecisionResolver, Definition}

  @xml File.read!("test/fixtures/business_rule.bpmn")

  setup do
    DecisionResolver.reset()
    previous = Application.get_env(:ash_bpmn, :decision_resolver)
    Application.put_env(:ash_bpmn, :decision_resolver, DecisionResolver)

    on_exit(fn ->
      DecisionResolver.reset()

      if previous do
        Application.put_env(:ash_bpmn, :decision_resolver, previous)
      else
        Application.delete_env(:ash_bpmn, :decision_resolver)
      end
    end)

    :ok
  end

  describe "compilation" do
    test "compiles a businessRuleTask into its reference, inputs and promotions" do
      DecisionResolver.register("risk.tier", fn _ -> %{outputs: %{"tier" => "low"}} end)

      assert {:ok, graph} = Compiler.compile(@xml)
      node = graph["nodes"]["AssessRisk"]

      assert node["type"] == "businessRuleTask"
      assert node["decision"]["ref"] == "risk.tier"
      assert node["decision"]["binding"] == "latest"
      assert [%{"name" => "amount", "from" => %{"text" => "subject.amount"}}] = node["inputs"]
      assert [%{"name" => "tier", "from" => "tier", "required" => true}] = node["promote"]
    end

    # The check that makes a decision node safe to publish. Without it the first instance to
    # reach the node discovers the typo.
    test "refuses to publish a reference the resolver does not recognise" do
      # nothing registered
      assert {:error, errors} = Compiler.compile(@xml)

      assert Enum.any?(errors, fn e ->
               String.contains?(e.message, "risk.tier") and
                 String.contains?(e.message, "does not exist")
             end)
    end

    test "refuses a decision node when no resolver is configured at all" do
      Application.delete_env(:ash_bpmn, :decision_resolver)

      assert {:error, errors} = Compiler.compile(@xml)
      assert Enum.any?(errors, &String.contains?(&1.message, "decision_resolver"))
    end

    test "refuses an ash:decision without a ref" do
      xml =
        String.replace(
          @xml,
          ~s|<ash:decision ref="risk.tier" binding="latest"/>|,
          ~s|<ash:decision binding="latest"/>|
        )

      assert {:error, errors} = Compiler.compile(xml)
      assert Enum.any?(errors, &String.contains?(&1.message, "non-empty ref"))
    end

    # `binding="pinned"` without a version reads as "this will not move under me" and behaves
    # as "latest". Refusing it is cheaper than explaining it later.
    test "refuses binding=pinned without a version" do
      xml = String.replace(@xml, ~s|binding="latest"|, ~s|binding="pinned"|)
      DecisionResolver.register("risk.tier", fn _ -> %{outputs: %{"tier" => "low"}} end)

      assert {:error, errors} = Compiler.compile(xml)
      assert Enum.any?(errors, &String.contains?(&1.message, "requires a version"))
    end

    # The signal a process routes on and the output a decision produces are named by different
    # people; `from` is what stops one of them having to rename to suit the other.
    test "a signal can take an output under a different name" do
      xml =
        String.replace(
          @xml,
          ~s|<ash:signal name="tier" required="true"/>|,
          ~s|<ash:signal name="tier" from="RiskLevel" required="true"/>|
        )

      DecisionResolver.register("risk.tier", fn _ -> %{outputs: %{"RiskLevel" => "high"}} end)

      assert {:ok, graph} = Compiler.compile(xml)

      assert [%{"name" => "tier", "from" => "RiskLevel"}] =
               graph["nodes"]["AssessRisk"]["promote"]
    end

    test "refuses an input whose from expression is not valid FEEL" do
      xml = String.replace(@xml, ~s|from="subject.amount"|, ~s|from="subject.amount >"|)
      DecisionResolver.register("risk.tier", fn _ -> %{outputs: %{"tier" => "low"}} end)

      assert {:error, errors} = Compiler.compile(xml)
      assert Enum.any?(errors, &String.contains?(&1.message, "not valid FEEL"))
    end
  end

  describe "execution" do
    test "routes on a promoted signal" do
      DecisionResolver.register("risk.tier", fn inputs ->
        tier =
          if Decimal.compare(inputs["amount"], Decimal.new(1000)) == :gt, do: "high", else: "low"

        %{outputs: %{"tier" => tier}, version: 7, rule_ids: ["rule_#{tier}"]}
      end)

      _defn = create_published_definition!("brt_high", @xml)
      subject = create_test_subject!("brt_high_subject", amount: 5000)

      {:ok, instance} =
        AshBpmn.start_instance(AshBpmn.Test.Domain, process: "brt_high", subject: subject)

      assert instance.status == :completed
      assert instance.outcome == :escalated

      calls = AshBpmn.Test.Invoker.recorded_calls()
      assert Enum.any?(calls, fn {_id, action, _ts} -> action == "escalate" end)
    end

    test "the other branch, from the same diagram and the same decision" do
      DecisionResolver.register("risk.tier", fn inputs ->
        tier =
          if Decimal.compare(inputs["amount"], Decimal.new(1000)) == :gt, do: "high", else: "low"

        %{outputs: %{"tier" => tier}}
      end)

      _defn = create_published_definition!("brt_low", @xml)
      subject = create_test_subject!("brt_low_subject", amount: 10)

      {:ok, instance} =
        AshBpmn.start_instance(AshBpmn.Test.Domain, process: "brt_low", subject: subject)

      assert instance.status == :completed
      assert instance.outcome == :approved
    end

    # The decision's own answer, the version that gave it and the rule that fired -- which is
    # what an auditor asking "why did this instance go that way" actually wants.
    test "records a decision_evaluated event carrying the version and the rules that fired" do
      DecisionResolver.register("risk.tier", fn _ ->
        %{outputs: %{"tier" => "high", "score" => 42}, version: 7, rule_ids: ["r1", "r2"]}
      end)

      _defn = create_published_definition!("brt_event", @xml)
      subject = create_test_subject!("brt_event_subject", amount: 5000)

      {:ok, instance} =
        AshBpmn.start_instance(AshBpmn.Test.Domain, process: "brt_event", subject: subject)

      [event] = process_events(instance.id, :decision_evaluated)

      assert event.data["decision_ref"] == "risk.tier"
      assert event.data["decision_version"] == "7"
      assert event.data["rule_ids"] == ["r1", "r2"]
      assert event.data["promoted"] == %{"tier" => "high"}

      # `score` was returned by the decision and not declared as a signal, so it is not on the
      # token and not in the promoted set. The decision layer keeps its own full record; two
      # logs that overlap will eventually disagree.
      refute Map.has_key?(event.data["promoted"], "score")
    end

    # On the three failure paths below, note *how* the failure presents. The engine's
    # convention for a node it cannot complete is to raise, so that Oban retries and the
    # instance fails after `max_attempts` rather than routing itself down a branch nobody
    # chose. Under `oban_testing: :inline` there is no Oban between the caller and the node,
    # so the raise arrives here directly. Asserting a `:failed` instance instead would be
    # asserting something the inline mode does not do.
    test "a required signal the decision did not return fails the node" do
      DecisionResolver.register("risk.tier", fn _ -> %{outputs: %{"something_else" => "x"}} end)

      _defn = create_published_definition!("brt_missing", @xml)
      subject = create_test_subject!("brt_missing_subject", amount: 5000)

      assert_raise RuntimeError, ~r/required signal 'tier'/, fn ->
        AshBpmn.start_instance!(AshBpmn.Test.Domain, process: "brt_missing", subject: subject)
      end
    end

    # The enforcement that makes "tokens carry routing, not business data" a property rather
    # than a request.
    test "a non-scalar signal is refused rather than put on the token" do
      DecisionResolver.register("risk.tier", fn _ ->
        %{outputs: %{"tier" => %{"nested" => "map"}}}
      end)

      _defn = create_published_definition!("brt_nonscalar", @xml)
      subject = create_test_subject!("brt_nonscalar_subject", amount: 5000)

      assert_raise RuntimeError, ~r/not a scalar/, fn ->
        AshBpmn.start_instance!(AshBpmn.Test.Domain, process: "brt_nonscalar", subject: subject)
      end
    end

    test "a resolver crash fails the node rather than routing it somewhere" do
      DecisionResolver.register("risk.tier", fn _ -> raise "boom" end)

      _defn = create_published_definition!("brt_boom", @xml)
      subject = create_test_subject!("brt_boom_subject", amount: 5000)

      assert_raise RuntimeError, ~r/boom/, fn ->
        AshBpmn.start_instance!(AshBpmn.Test.Domain, process: "brt_boom", subject: subject)
      end
    end

    # A resolver returning `{:error, _}` is the ordinary refusal, distinct from a crash.
    test "a resolver returning an error fails the node" do
      DecisionResolver.register("risk.tier", fn _ -> {:error, :unavailable} end)

      _defn = create_published_definition!("brt_error", @xml)
      subject = create_test_subject!("brt_error_subject", amount: 5000)

      assert_raise RuntimeError, ~r/business rule task/, fn ->
        AshBpmn.start_instance!(AshBpmn.Test.Domain, process: "brt_error", subject: subject)
      end
    end
  end

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

  defp create_test_subject!(name, overrides) do
    attrs = %{
      name: name,
      amount: Keyword.get(overrides, :amount, 0),
      is_privileged: Keyword.get(overrides, :is_privileged, false),
      created_by_id: Keyword.get(overrides, :created_by_id)
    }

    # `create!/1` here returns `{:ok, subject}` rather than the record; matching both keeps
    # this helper identical to the one in engine_test.exs.
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
