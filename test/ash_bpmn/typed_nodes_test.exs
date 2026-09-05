# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.TypedNodesTest do
  @moduledoc """
  Typed nodes and their linked editors: FEEL input bindings and output promotion
  shared by service, send and business rule tasks; the sendTask node type; the
  publish-time action verification; and the `decision_name` on a decision call.

  The shape rule under test throughout: the input and promote entries on a
  service task are exactly the entries a decision task carries, because both
  halves are extracted and validated by the same compiler functions.
  """

  use AshBpmn.DataCase, async: false

  require Ash.Query

  alias AshBpmn.Compiler
  alias AshBpmn.Test.{DecisionResolver, Definition, Invoker}

  @xml File.read!("test/fixtures/typed_actions.bpmn")
  @linear File.read!("test/fixtures/linear.bpmn")

  setup do
    DecisionResolver.reset()
    Invoker.clear_calls()

    previous_resolver = Application.get_env(:ash_bpmn, :decision_resolver)
    previous_invoker = Application.get_env(:ash_bpmn, :action_invoker)

    Application.put_env(:ash_bpmn, :decision_resolver, DecisionResolver)
    Application.put_env(:ash_bpmn, :action_invoker, Invoker)

    on_exit(fn ->
      DecisionResolver.reset()
      Invoker.clear_calls()

      if previous_resolver do
        Application.put_env(:ash_bpmn, :decision_resolver, previous_resolver)
      else
        Application.delete_env(:ash_bpmn, :decision_resolver)
      end

      if previous_invoker do
        Application.put_env(:ash_bpmn, :action_invoker, previous_invoker)
      else
        Application.delete_env(:ash_bpmn, :action_invoker)
      end
    end)

    :ok
  end

  # ── Compiler ───────────────────────────────────────────────────────────

  describe "compilation" do
    test "sendTask is a supported node type" do
      DecisionResolver.register("risk.tier", fn _ -> %{outputs: %{"tier" => "low"}} end)

      assert {:ok, graph} = Compiler.compile(@xml)
      node = graph["nodes"]["Notify"]

      assert node["type"] == "sendTask"
      assert node["action"] == "send_notice"
    end

    test "service and send tasks extract inputs and promotions with the shared shapes" do
      DecisionResolver.register("risk.tier", fn _ -> %{outputs: %{"tier" => "low"}} end)

      assert {:ok, graph} = Compiler.compile(@xml)

      assert [%{"name" => "note", "from" => %{"language" => "feel", "text" => "routing.tier"}}] =
               graph["nodes"]["Notify"]["inputs"]

      assert [%{"name" => "ticket", "from" => "reference", "required" => true}] =
               graph["nodes"]["Notify"]["promote"]

      assert [
               %{
                 "name" => "risk_tier",
                 "from" => %{"language" => "feel", "text" => "routing.tier"}
               }
             ] =
               graph["nodes"]["Record"]["inputs"]

      # No promote element, no promote key: the XML never declared one.
      refute Map.has_key?(graph["nodes"]["Record"], "promote")
    end

    test "a decision ref and a service action share input shapes by construction" do
      DecisionResolver.register("risk.tier", fn _ -> %{outputs: %{"tier" => "low"}} end)

      {:ok, graph} = Compiler.compile(@xml)

      decision_input = hd(graph["nodes"]["AssessRisk"]["inputs"])
      service_input = hd(graph["nodes"]["Record"]["inputs"])

      assert Map.keys(decision_input) == Map.keys(service_input)
      assert is_map(decision_input["from"]) == is_map(service_input["from"])

      decision_signal = hd(graph["nodes"]["AssessRisk"]["promote"])
      send_signal = hd(graph["nodes"]["Notify"]["promote"])

      assert MapSet.new(Map.keys(decision_signal)) == MapSet.new(Map.keys(send_signal))
    end

    test "the optional decision name is stored under the decision" do
      DecisionResolver.register("risk.tier", fn _ -> %{outputs: %{"tier" => "low"}} end)

      assert {:ok, graph} = Compiler.compile(@xml)
      assert graph["nodes"]["AssessRisk"]["decision"]["name"] == "RiskTier"
    end

    test "a blank decision name is refused rather than trimmed away" do
      DecisionResolver.register("risk.tier", fn _ -> %{outputs: %{"tier" => "low"}} end)
      xml = String.replace(@xml, ~s|name="RiskTier"|, ~s|name=""|)

      assert {:error, errors} = Compiler.compile(xml)
      assert Enum.any?(errors, &String.contains?(&1.message, "name must be non-empty"))
    end

    test "documents written before inputs existed compile byte-identically" do
      # No resolver: linear.bpmn has no decision, and the default invoker does not
      # export exists?/1, so nothing needs to be verified.
      assert {:ok, graph} = Compiler.compile(@linear)
      node = graph["nodes"]["Service_1"]

      assert node["action"] == "do_something"
      refute Map.has_key?(node, "inputs")
      refute Map.has_key?(node, "promote")
    end

    test "inputs on a service task are validated like decision inputs" do
      DecisionResolver.register("risk.tier", fn _ -> %{outputs: %{"tier" => "low"}} end)

      xml =
        String.replace(
          @xml,
          ~s|<ash:input name="risk_tier" from="routing.tier"/>|,
          ~s|<ash:input name="risk_tier"/>|
        )

      assert {:error, errors} = Compiler.compile(xml)
      assert Enum.any?(errors, &String.contains?(&1.message, "needs a from expression"))

      xml =
        String.replace(
          @xml,
          ~s|<ash:input name="risk_tier" from="routing.tier"/>|,
          ~s|<ash:input name="risk_tier" from="routing.tier >"/>|
        )

      assert {:error, errors} = Compiler.compile(xml)
      assert Enum.any?(errors, &String.contains?(&1.message, "not valid FEEL"))
    end

    test "promotions on a send task are validated like decision promotions" do
      DecisionResolver.register("risk.tier", fn _ -> %{outputs: %{"tier" => "low"}} end)

      # Same signal name twice
      xml =
        String.replace(
          @xml,
          ~s|<ash:signal name="ticket" from="reference" required="true"/>|,
          ~s|<ash:signal name="ticket" from="reference" required="true"/><ash:signal name="ticket"/>|
        )

      assert {:error, errors} = Compiler.compile(xml)

      assert Enum.any?(
               errors,
               &String.contains?(&1.message, "promotes the same signal name twice")
             )

      # Missing name
      xml =
        String.replace(
          @xml,
          ~s|<ash:signal name="ticket" from="reference" required="true"/>|,
          ~s|<ash:signal from="reference"/>|
        )

      assert {:error, errors} = Compiler.compile(xml)
      assert Enum.any?(errors, &String.contains?(&1.message, "ash:signal needs a name"))
    end

    test "unknown ash: attributes on a send task config are still compile errors" do
      DecisionResolver.register("risk.tier", fn _ -> %{outputs: %{"tier" => "low"}} end)

      xml = String.replace(@xml, ~s|action="send_notice"|, ~s|action="send_notice" ash:typo="x"|)

      assert {:error, errors} = Compiler.compile(xml)
      assert Enum.any?(errors, &String.contains?(&1.message, "Unknown ash: attribute 'typo'"))
    end
  end

  # ── Publish-time action verification ───────────────────────────────────

  describe "action verification" do
    setup do
      Application.put_env(:ash_bpmn, :action_invoker, AshBpmn.Test.VerifyingInvoker)
      AshBpmn.Test.VerifyingInvoker.reset()
      DecisionResolver.register("risk.tier", fn _ -> %{outputs: %{"tier" => "low"}} end)

      on_exit(fn -> AshBpmn.Test.VerifyingInvoker.reset() end)
      :ok
    end

    test "an action the invoker knows about compiles" do
      AshBpmn.Test.VerifyingInvoker.register("send_notice")
      AshBpmn.Test.VerifyingInvoker.register("record_risk")

      assert {:ok, _graph} = Compiler.compile(@xml)
    end

    test "an action the invoker does not know about fails at publish" do
      AshBpmn.Test.VerifyingInvoker.register("record_risk")

      assert {:error, errors} = Compiler.compile(@xml)

      assert Enum.any?(
               errors,
               &(String.contains?(&1.message, "send_notice") and
                   String.contains?(&1.message, "does not exist"))
             )
    end

    test "an invoker without exists?/1 is not asked" do
      # Back to the plain double, which has no exists?/1: nothing to ask, nothing fails.
      Application.put_env(:ash_bpmn, :action_invoker, Invoker)

      assert {:ok, _graph} = Compiler.compile(@xml)
    end

    test "a crashing catalogue is a fail-safe error, not a publish" do
      AshBpmn.Test.VerifyingInvoker.register(:raise)

      assert {:error, errors} = Compiler.compile(@xml)
      assert Enum.any?(errors, &String.contains?(&1.message, "could not verify action"))
    end
  end

  # ── Interpreter ────────────────────────────────────────────────────────

  describe "execution" do
    test "a send task dispatches through the service-task path with evaluated inputs" do
      DecisionResolver.register("risk.tier", fn _ -> %{outputs: %{"tier" => "high"}} end)
      Invoker.set_result({:ok, %{"reference" => "T-1"}})

      _defn = create_published_definition!("typed_high", @xml)
      subject = create_test_subject!("typed_high_subject", amount: 5000)

      {:ok, instance} =
        AshBpmn.start_instance(AshBpmn.Test.Domain, process: "typed_high", subject: subject)

      assert instance.status == :completed
      assert instance.outcome == :escalated

      ctxs = Invoker.recorded_ctxs()
      assert Enum.any?(ctxs, fn {_id, action, _ctx} -> action == "send_notice" end)

      {_id, "send_notice", ctx} = Enum.find(ctxs, fn {_id, a, _} -> a == "send_notice" end)
      assert ctx[:inputs] == %{"note" => "high"}
    end

    test "ctx carries the tenant the job travelled with and the system actor" do
      DecisionResolver.register("risk.tier", fn _ -> %{outputs: %{"tier" => "low"}} end)

      _defn = create_published_definition!("typed_tenant", @xml)
      subject = create_test_subject!("typed_tenant_subject", amount: 10)

      {:ok, instance} =
        AshBpmn.start_instance(AshBpmn.Test.Domain,
          process: "typed_tenant",
          subject: subject,
          tenant: "acme"
        )

      assert instance.status == :completed

      {_id, _action, ctx} =
        Enum.find(Invoker.recorded_ctxs(), fn {_id, a, _} -> a == "record_risk" end)

      assert ctx[:tenant] == "acme"
      assert %{name: :advance} = ctx[:actor]
    end

    test "a service task's inputs are evaluated and passed to the invoker" do
      DecisionResolver.register("risk.tier", fn _ -> %{outputs: %{"tier" => "low"}} end)

      _defn = create_published_definition!("typed_low", @xml)
      subject = create_test_subject!("typed_low_subject", amount: 10)

      {:ok, instance} =
        AshBpmn.start_instance(AshBpmn.Test.Domain, process: "typed_low", subject: subject)

      assert instance.status == :completed
      assert instance.outcome == :approved

      {_id, "record_risk", ctx} =
        Enum.find(Invoker.recorded_ctxs(), fn {_id, a, _} -> a == "record_risk" end)

      assert ctx[:inputs] == %{"risk_tier" => "low"}
    end

    test "promotions from an action result merge onto routing and the event" do
      DecisionResolver.register("risk.tier", fn _ -> %{outputs: %{"tier" => "high"}} end)
      Invoker.set_result({:ok, %{"reference" => "T-1", "extra" => "ignored"}})

      _defn = create_published_definition!("typed_promote", @xml)
      subject = create_test_subject!("typed_promote_subject", amount: 5000)

      {:ok, instance} =
        AshBpmn.start_instance(AshBpmn.Test.Domain, process: "typed_promote", subject: subject)

      assert instance.status == :completed

      [event] = process_events(instance.id, :action_invoked)

      assert event.data["action"] == "send_notice"
      assert event.data["inputs"] == %{"note" => "high"}
      # Declared signals only: "extra" stays out, exactly like a decision result.
      assert event.data["promoted"] == %{"ticket" => "T-1"}
    end

    test "an :ok invoker result promotes nothing" do
      DecisionResolver.register("risk.tier", fn _ -> %{outputs: %{"tier" => "high"}} end)
      Invoker.set_result(:ok)

      _defn = create_published_definition!("typed_ok", @xml)
      subject = create_test_subject!("typed_ok_subject", amount: 5000)

      {:ok, instance} =
        AshBpmn.start_instance(AshBpmn.Test.Domain, process: "typed_ok", subject: subject)

      assert instance.status == :completed

      [event] = process_events(instance.id, :action_invoked)
      assert event.data["promoted"] == %{}
    end

    test "a required signal the action did not return fails the node" do
      DecisionResolver.register("risk.tier", fn _ -> %{outputs: %{"tier" => "high"}} end)
      Invoker.set_result({:ok, %{"something_else" => "x"}})

      _defn = create_published_definition!("typed_missing", @xml)
      subject = create_test_subject!("typed_missing_subject", amount: 5000)

      assert_raise RuntimeError, ~r/required signal 'ticket'/, fn ->
        AshBpmn.start_instance!(AshBpmn.Test.Domain, process: "typed_missing", subject: subject)
      end
    end

    test "a non-scalar signal from an action result is refused" do
      DecisionResolver.register("risk.tier", fn _ -> %{outputs: %{"tier" => "high"}} end)
      Invoker.set_result({:ok, %{"reference" => %{"deep" => "map"}}})

      _defn = create_published_definition!("typed_nonscalar", @xml)
      subject = create_test_subject!("typed_nonscalar_subject", amount: 5000)

      assert_raise RuntimeError, ~r/not a scalar/, fn ->
        AshBpmn.start_instance!(AshBpmn.Test.Domain, process: "typed_nonscalar", subject: subject)
      end
    end

    test "the decision context carries the decision's name" do
      Application.put_env(:ash_bpmn, :decision_resolver, AshBpmn.Test.RecordingDecisionResolver)
      Invoker.set_result(:ok)

      _defn = create_published_definition!("typed_name", @xml)
      subject = create_test_subject!("typed_name_subject", amount: 10)

      {:ok, instance} =
        AshBpmn.start_instance(AshBpmn.Test.Domain, process: "typed_name", subject: subject)

      assert instance.status == :completed

      assert_received {:decision_context, context}
      assert context.decision_name == "RiskTier"
      assert context.node_id == "AssessRisk"
      # The ctx keys the resolver sees alongside it.
      assert context.tenant == nil
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
