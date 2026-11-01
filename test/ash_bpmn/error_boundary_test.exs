# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.ErrorBoundaryTest do
  @moduledoc """
  Error boundary events: a task whose answer is a modelled failure leaves by the route the
  diagram drew for it.

  They were refused for as long as nothing could tell a business error from a fault: a callee
  returned `{:error, term()}` either way, and catching would have routed a database outage
  down the "coverage denied" branch. A callee now names the answer -- `{:bpmn_error, code,
  details}` from the invoker, an `AshBpmn.BpmnError` from an `ash:call` callable, an error end
  event from a called child -- and only that is caught. Everything else is still a fault.
  """

  use AshBpmn.DataCase, async: false

  require Ash.Query

  alias AshBpmn.Compiler
  alias AshBpmn.Runtime.AdvanceWorker
  alias AshBpmn.Runtime.Oban.TestJobs
  alias AshBpmn.Test.{Definition, Instance, Invoker, ProcessEvent, Token}

  @denied {:error, {:bpmn_error, "COVERAGE_DENIED", %{"plan" => "basic"}}}

  setup do
    Invoker.clear_calls()
    TestJobs.clear()
    on_exit(fn -> Invoker.clear_calls() end)
    :ok
  end

  describe "compiling" do
    test "an error boundary on a service task carries its error into the snapshot" do
      {:ok, graph} = Compiler.compile(File.read!("test/fixtures/error_boundary.bpmn"))
      boundary = graph["nodes"]["CoverageDenied"]

      assert boundary["attached_to"] == "CoverageCheck"
      assert boundary["interrupting"] == true

      assert boundary["error"] == %{
               "ref" => "Error_Coverage",
               "code" => "COVERAGE_DENIED",
               "name" => "Coverage denied"
             }

      refute Map.has_key?(boundary, "catch")
      assert graph["boundaries"]["CoverageCheck"] == ["CoverageDenied"]
    end

    test "send tasks and call activities take one too" do
      assert {:ok, _} = Compiler.compile(service_xml(task: "sendTask"))
      assert {:ok, _} = Compiler.compile(File.read!("test/fixtures/call_error_boundary.bpmn"))
    end

    test "a user task is refused: nothing it does can throw" do
      xml =
        service_xml()
        |> String.replace(
          ~s(<bpmn2:serviceTask id="Check"><bpmn2:extensionElements><ash:taskConfig action="check"/></bpmn2:extensionElements>),
          ~s(<bpmn2:userTask id="Check"><bpmn2:extensionElements><ash:taskConfig><ash:candidates><ash:candidate kind="role" of="nurse"/></ash:candidates><ash:outcomes><ash:outcome name="done"/></ash:outcomes></ash:taskConfig></bpmn2:extensionElements>)
        )
        |> String.replace("</bpmn2:serviceTask>", "</bpmn2:userTask>")

      message = refusal(xml)
      assert message =~ "catches an error on a userTask"
      assert message =~ "serviceTask, sendTask, callActivity"
    end

    test "a non-interrupting error boundary is refused: an error always interrupts" do
      xml = service_xml(boundary_attrs: ~s( cancelActivity="false"))
      assert refusal(xml) =~ "always interrupts"
    end

    test "a catch with no errorRef is refused rather than read as catch-all" do
      xml = service_xml(definition: ~s(<bpmn2:errorEventDefinition id="ED"/>))
      assert refusal(xml) =~ "no errorRef"
    end

    test "an errorRef with no declaration is refused" do
      xml = service_xml(definition: ~s(<bpmn2:errorEventDefinition id="ED" errorRef="Nope"/>))
      message = refusal(xml)
      assert message =~ "'Nope'"
      assert message =~ "not declared"
    end

    test "an error with no errorCode is refused, because nothing could ever match it" do
      xml = service_xml(declaration: ~s(<bpmn2:error id="Error_1" name="Unnamed"/>))
      assert refusal(xml) =~ "no errorCode"
    end

    test "two boundaries on one task catching the same code are refused" do
      second = """
      <bpmn2:boundaryEvent id="Caught2" attachedToRef="Check">
        <bpmn2:outgoing>F_caught2</bpmn2:outgoing>
        <bpmn2:errorEventDefinition id="ED2" errorRef="Error_1"/>
      </bpmn2:boundaryEvent>
      <bpmn2:endEvent id="End_caught2"><bpmn2:incoming>F_caught2</bpmn2:incoming></bpmn2:endEvent>
      <bpmn2:sequenceFlow id="F_caught2" sourceRef="Caught2" targetRef="End_caught2"/>
      """

      xml = String.replace(service_xml(), "</bpmn2:process>", second <> "</bpmn2:process>")
      assert refusal(xml) =~ "both catch error code 'DENIED'"
    end

    test "a multi-instance task is refused: one instance's error would not stop the rest" do
      xml =
        String.replace(
          service_xml(),
          ~s(<bpmn2:incoming>F_start</bpmn2:incoming>),
          ~s(<bpmn2:multiInstanceLoopCharacteristics isSequential="false"><ash:collection from="subject.ids" as="id"/></bpmn2:multiInstanceLoopCharacteristics><bpmn2:incoming>F_start</bpmn2:incoming>)
        )

      assert refusal(xml) =~ "multi-instance"
    end

    test "a timer boundary on a service task is still refused" do
      # The error boundary did not open the door for timers: a timer interrupts work that is
      # still running, and a service task's work cannot be interrupted.
      xml =
        service_xml(
          definition:
            ~s(<bpmn2:timerEventDefinition id="TD"><bpmn2:timeDuration>PT1H</bpmn2:timeDuration></bpmn2:timerEventDefinition>)
        )

      assert refusal(xml) =~ "timer boundary events are supported on: userTask"
    end
  end

  describe "a service task's callee throwing a business error" do
    test "takes the boundary while the sibling branch completes" do
      Invoker.set_result("check_coverage", @denied)

      instance = start!("error_boundary.bpmn")

      assert reload(instance).status == :completed
      assert invoked("check_allergies") == 1
      assert invoked("offer_self_pay") == 1
      assert [%{status: :consumed}] = tokens_at(instance, "End_SelfPay")
      assert tokens_at(instance, "End_Covered") == []

      # Asked once: an answer is not retried.
      assert invoked("check_coverage") == 1

      assert [event] = events(instance, :activity_interrupted)
      assert event.node_id == "CoverageDenied"
      assert event.data["interrupted"] == "CoverageCheck"
      assert event.data["error_code"] == "COVERAGE_DENIED"
      assert event.data["error_ref"] == "Error_Coverage"
      assert event.data["details"] =~ "basic"

      # The check never completed: it was interrupted, so its own flow was not taken.
      refute Enum.any?(events(instance, :node_completed), &(&1.node_id == "CoverageCheck"))
      assert [%{status: :consumed}] = tokens_at(instance, "CoverageCheck")
    end

    test "a covered patient goes the ordinary way and the boundary never fires" do
      instance = start!("error_boundary.bpmn")

      assert reload(instance).status == :completed
      assert invoked("offer_self_pay") == 0
      assert events(instance, :activity_interrupted) == []
    end

    test "an atom code is read by its name" do
      Invoker.set_result("check_coverage", {:error, {:bpmn_error, :COVERAGE_DENIED, %{}}})

      instance = start!("error_boundary.bpmn")

      assert reload(instance).status == :completed
      assert invoked("offer_self_pay") == 1
    end

    test "an uncaught code fails the instance at the task at once, without retrying" do
      Invoker.set_result("check_coverage", {:error, {:bpmn_error, "PLAN_EXPIRED", %{}}})

      instance = start!("error_boundary.bpmn")

      assert reload(instance).status == :failed
      assert invoked("check_coverage") == 1
      assert invoked("offer_self_pay") == 0

      assert [event] = events(instance, :action_failed)
      assert event.node_id == "CoverageCheck"
      assert event.data["reason"] == "unhandled_error"
      assert event.data["error_code"] == "PLAN_EXPIRED"
      assert event.data["error"] =~ "no error boundary on this activity catches it"
      assert [%{status: :dead}] = tokens_at(instance, "CoverageCheck")
    end

    test "retrying an unhandled error asks again under the same invocation key" do
      Invoker.set_result("check_coverage", {:error, {:bpmn_error, "PLAN_EXPIRED", %{}}})
      instance = start!("error_boundary.bpmn")
      assert reload(instance).status == :failed

      # Somebody renewed the plan; the next answer is a yes.
      Invoker.set_result("check_coverage", :ok)
      retried = AshBpmn.retry_instance!(reload(instance))

      assert retried.status == :completed

      assert [first, second] = keys_for("check_coverage")
      assert first == second
    end

    test "a fault is not caught: the task with a boundary still retries and gives up" do
      # The distinction the whole feature rests on. A timeout is not "coverage denied", and
      # routing it down the self-pay branch would decide something nobody decided.
      Invoker.set_result("check_coverage", {:error, "the insurer timed out"})

      assert_raise RuntimeError, ~r/check_coverage' failed/, fn ->
        start!("error_boundary.bpmn", raise?: true)
      end

      instance = latest_instance!()
      [token] = tokens_at(instance, "CoverageCheck")
      assert token.status == :active
      assert events(instance, :activity_interrupted) == []

      max = AshBpmn.Config.max_attempts()

      for attempt <- 2..(max - 1) do
        assert_raise RuntimeError, fn ->
          AdvanceWorker.perform(retry_job(instance, token, attempt))
        end
      end

      assert {:ok, :failed_permanently} = AdvanceWorker.perform(retry_job(instance, token, max))
      assert [event] = events(instance, :action_failed)
      assert event.data["reason"] == "max_attempts_exceeded"
      assert invoked("offer_self_pay") == 0
    end

    test "a send task's callee is caught the same way" do
      Invoker.set_result("check", {:error, {:bpmn_error, "DENIED", %{}}})

      instance = start_xml!(service_xml(task: "sendTask"))

      assert reload(instance).status == :completed
      assert [event] = events(instance, :activity_interrupted)
      assert event.node_id == "Caught"
    end
  end

  describe "an ash:call callable throwing an AshBpmn.BpmnError" do
    test "takes the boundary" do
      xml =
        String.replace(
          File.read!("test/fixtures/error_boundary.bpmn"),
          ~s(<ash:taskConfig action="check_coverage"/>),
          ~s(<ash:call ref="AshBpmn.Test.RuntimeCallablesDomain.deny_coverage"/>)
        )

      instance = start_xml!(xml)

      assert reload(instance).status == :completed
      assert invoked("offer_self_pay") == 1

      assert [event] = events(instance, :activity_interrupted)
      assert event.data["error_code"] == "COVERAGE_DENIED"
      assert event.data["details"] =~ "basic"
    end
  end

  describe "a called child ending in an error end event" do
    test "takes the call activity's boundary in the parent" do
      parent = start_parent!("call_error_boundary.bpmn")

      assert reload(parent).status == :completed
      assert invoked("notify_gp") == 1
      assert invoked("schedule_specialist") == 0

      [child] = children_of(parent)
      assert reload(child).status == :errored

      assert [completed] = events(parent, :child_completed)
      assert completed.data["child_instance_id"] == child.id
      assert completed.data["error_code"] == "DECLINED"

      assert [interrupted] = events(parent, :activity_interrupted)
      assert interrupted.node_id == "ReferralDeclined"
      assert interrupted.data["interrupted"] == "Referral"
      assert interrupted.data["child_instance_id"] == child.id
    end

    test "with no boundary to catch it, fails the parent at the call activity" do
      # It used to do nothing: an errored child never woke its parent, which waited forever.
      parent = start_parent!("call_parent.bpmn")

      assert reload(parent).status == :failed
      assert invoked("after_child") == 0

      [child] = children_of(parent)
      assert [event] = events(parent, :action_failed)
      assert event.node_id == "Onboard"
      assert event.data["reason"] == "unhandled_error"
      assert event.data["error_code"] == "DECLINED"
      assert event.data["child_instance_id"] == child.id
      assert [%{status: :dead}] = tokens_at(parent, "Onboard")
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  # One service task with one error boundary, its parts replaceable for the refusals.
  defp service_xml(opts \\ []) do
    task = Keyword.get(opts, :task, "serviceTask")

    declaration =
      Keyword.get(
        opts,
        :declaration,
        ~s(<bpmn2:error id="Error_1" name="Denied" errorCode="DENIED"/>)
      )

    definition =
      Keyword.get(opts, :definition, ~s(<bpmn2:errorEventDefinition id="ED" errorRef="Error_1"/>))

    """
    <bpmn2:definitions xmlns:bpmn2="http://www.omg.org/spec/BPMN/20100524/MODEL"
                       xmlns:ash="https://github.com/lukegalea/ash_bpmn/ns"
                       id="D" targetNamespace="https://github.com/lukegalea/ash_bpmn/ns">
      #{declaration}
      <bpmn2:process id="P" isExecutable="true">
        <bpmn2:startEvent id="Start"><bpmn2:outgoing>F_start</bpmn2:outgoing></bpmn2:startEvent>
        <bpmn2:#{task} id="Check"><bpmn2:extensionElements><ash:taskConfig action="check"/></bpmn2:extensionElements>
          <bpmn2:incoming>F_start</bpmn2:incoming>
          <bpmn2:outgoing>F_done</bpmn2:outgoing>
        </bpmn2:#{task}>
        <bpmn2:boundaryEvent id="Caught" attachedToRef="Check"#{opts[:boundary_attrs]}>
          <bpmn2:outgoing>F_caught</bpmn2:outgoing>
          #{definition}
        </bpmn2:boundaryEvent>
        <bpmn2:endEvent id="End"><bpmn2:incoming>F_done</bpmn2:incoming></bpmn2:endEvent>
        <bpmn2:endEvent id="End_caught"><bpmn2:incoming>F_caught</bpmn2:incoming></bpmn2:endEvent>
        <bpmn2:sequenceFlow id="F_start" sourceRef="Start" targetRef="Check"/>
        <bpmn2:sequenceFlow id="F_done" sourceRef="Check" targetRef="End"/>
        <bpmn2:sequenceFlow id="F_caught" sourceRef="Caught" targetRef="End_caught"/>
      </bpmn2:process>
    </bpmn2:definitions>
    """
  end

  defp refusal(xml) do
    assert {:error, errors} = Compiler.compile(xml)
    Enum.map_join(errors, " ", & &1.message)
  end

  defp start!(fixture, opts \\ []), do: start_xml!(File.read!("test/fixtures/#{fixture}"), opts)

  defp start_xml!(xml, opts \\ []) do
    defn = publish!(xml)

    {:ok, subject} =
      AshBpmn.Test.Subject.create!(%{name: "intake", amount: 0, is_privileged: false})

    if opts[:raise?] do
      AshBpmn.start_instance!(AshBpmn.Test.Domain, definition: defn, subject: subject)
    else
      {:ok, instance} =
        AshBpmn.start_instance(AshBpmn.Test.Domain, definition: defn, subject: subject)

      instance
    end
  end

  defp start_parent!(fixture) do
    child_key = key()
    publish!(File.read!("test/fixtures/error_end.bpmn"), child_key)

    "test/fixtures/#{fixture}"
    |> File.read!()
    |> String.replace("CHILD_KEY", child_key)
    |> start_xml!()
  end

  defp publish!(xml, k \\ nil) do
    k = k || key()
    Process.put(:eb_key, k)
    defn = Definition.create!(%{key: k, name: k, xml: xml})
    if is_nil(defn.graph), do: raise("compile failed: #{inspect(defn.errors)}")
    Definition.publish!(defn)
  end

  defp key, do: "eb_#{System.unique_integer([:positive])}"

  defp latest_instance! do
    key = Process.get(:eb_key)

    Instance
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(definition.key == ^key)
    |> Ash.read_one!(authorize?: false)
  end

  defp retry_job(instance, token, attempt) do
    %Oban.Job{
      id: System.unique_integer([:positive]),
      attempt: attempt,
      max_attempts: 20,
      args: %{
        "instance_id" => instance.id,
        "token_id" => token.id,
        "node_id" => token.node_id,
        "domain" => to_string(AshBpmn.Test.Domain)
      }
    }
  end

  defp invoked(action),
    do: Enum.count(Invoker.recorded_calls(), fn {_id, a, _ts} -> a == action end)

  defp keys_for(action) do
    for {_id, ^action, ctx} <- Invoker.recorded_ctxs(), do: ctx[:invocation_key]
  end

  defp reload(instance) do
    Instance
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^instance.id)
    |> Ash.read_one!(authorize?: false)
  end

  defp children_of(parent) do
    Instance
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(parent_instance_id == ^parent.id)
    |> Ash.read!(authorize?: false)
  end

  defp tokens_at(instance, node_id) do
    Token
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(instance_id == ^instance.id and node_id == ^node_id)
    |> Ash.read!(authorize?: false)
  end

  defp events(instance, kind) do
    ProcessEvent
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(instance_id == ^instance.id and kind == ^kind)
    |> Ash.read!(authorize?: false)
  end
end
