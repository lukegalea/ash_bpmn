# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.WaitBoundaryTest do
  @moduledoc """
  Timer boundary events on receive tasks and call activities: a deadline on a wait for a
  message or for a child process.

  The token is parked and the deadline is a scheduled job, so nothing runs while the process
  waits. Firing claims the parked token by compare-and-set, the same claim the message or the
  child's completion would make, so exactly one of them wins.
  """

  use AshBpmn.DataCase, async: false

  require Ash.Query

  alias AshBpmn.Runtime.Oban.TestJobs
  alias AshBpmn.Test.{Definition, HumanTask, Instance, ProcessEvent, Token}
  alias AshBpmn.Triggers.Correlator

  @later_than_four_hours 5 * 3600
  @later_than_a_day 25 * 3600

  setup do
    AshBpmn.Test.Invoker.clear_calls()
    TestJobs.clear()
    :ok
  end

  describe "compiling" do
    test "a receive task and a call activity each carry a boundary" do
      receive_task = compile!(File.read!("test/fixtures/receive_task_boundary.bpmn"))
      assert receive_task.graph["boundaries"] == %{"AwaitResult" => ["Boundary_1"]}

      call = compile!(call_xml("child_key"))
      assert call.graph["boundaries"] == %{"Onboard" => ["Boundary_1"]}
      assert call.graph["nodes"]["Boundary_1"]["catch"]["seconds"] == 24 * 3600
    end

    test "a boundary on an intermediate message catch is refused, and names the receive task" do
      # BPMN attaches boundary events to activities only. The receive task is the activity
      # form of the same wait, so the error points there instead of at a missing feature.
      xml =
        "test/fixtures/receive_task_boundary.bpmn"
        |> File.read!()
        |> String.replace(
          ~s(<bpmn2:receiveTask id="AwaitResult" name="Await lab result">),
          ~s(<bpmn2:intermediateCatchEvent id="AwaitResult" name="Await lab result">) <>
            ~s(<bpmn2:messageEventDefinition id="Msg_1"/>)
        )
        |> String.replace("</bpmn2:receiveTask>", "</bpmn2:intermediateCatchEvent>")

      defn = create(xml)
      refute defn.graph
      errors = Enum.map_join(defn.errors, " ", & &1["message"])
      assert errors =~ "attach to activities"
      assert errors =~ "receiveTask"
    end
  end

  describe "a receive task" do
    test "parks with its deadline armed and nothing running" do
      {instance, _subject} = start_receive!()

      assert token_at(instance, "AwaitResult").status == :waiting

      assert [job] = boundary_jobs()
      assert job.args["attached_to"] == "AwaitResult"
      assert job.meta["kind"] == "boundary"
      assert DateTime.diff(job.scheduled_at, DateTime.utc_now(), :second) > 3 * 3600
    end

    test "times out to its boundary" do
      {instance, subject} = start_receive!()

      assert TestJobs.fire_due!(DateTime.add(DateTime.utc_now(), @later_than_four_hours)) >= 1

      assert token_at(instance, "AwaitResult").status == :consumed
      assert invoked?("escalate_it")
      refute invoked?("settle")
      assert reload(instance).status == :completed

      assert [interrupted] = Enum.filter(events(instance), &(&1.kind == :activity_interrupted))
      assert interrupted.node_id == "Boundary_1"
      assert interrupted.data["interrupted"] == "AwaitResult"

      # A result that turns up after the deadline finds nobody waiting for it.
      deliver!(%{invoice_id: subject.id})
      refute invoked?("settle")
      refute Enum.any?(events(instance), &(&1.kind == :message_received))
    end

    test "a message before the deadline wins, and defuses it" do
      {instance, subject} = start_receive!()

      deliver!(%{invoice_id: subject.id})

      assert invoked?("settle")
      assert reload(instance).status == :completed
      assert boundary_jobs() == []

      assert TestJobs.fire_due!(DateTime.add(DateTime.utc_now(), @later_than_four_hours)) == 0
      refute invoked?("escalate_it")
    end

    test "a non-interrupting boundary leaves the wait in place and starts a branch beside it" do
      {instance, subject} = start_receive!(interrupting: false)

      assert TestJobs.fire_due!(DateTime.add(DateTime.utc_now(), @later_than_four_hours)) >= 1

      assert invoked?("escalate_it")
      assert token_at(instance, "AwaitResult").status == :waiting
      assert reload(instance).status == :running

      deliver!(%{invoice_id: subject.id})

      assert invoked?("settle")
      assert reload(instance).status == :completed
    end
  end

  describe "a call activity" do
    test "times out to its boundary and cancels the child in the same step" do
      {parent, child_key} = start_call!(child: :approval)
      [child] = children_of(parent)
      [task] = tasks_of(child)

      assert TestJobs.fire_due!(DateTime.add(DateTime.utc_now(), @later_than_a_day)) >= 1

      assert reload(parent).status == :completed
      assert invoked?("escalate_it")
      refute invoked?("after_child")

      assert reload(child).status == :cancelled
      assert reload_task(task).status == :cancelled
      refute Enum.any?(tokens_of(child), &(&1.status in [:active, :executing, :waiting]))

      assert [cancelled] = Enum.filter(events(child), &(&1.kind == :instance_cancelled))
      assert cancelled.data["reason"] == "boundary_event"
      assert cancelled.data["boundary_id"] == "Boundary_1"

      # Only one child was ever started.
      assert [started] = Enum.filter(events(parent), &(&1.kind == :child_started))
      assert started.data["process_key"] == child_key
    end

    test "cancels the whole call tree below it" do
      grandchild_key = key()
      publish!(File.read!("test/fixtures/access_request.bpmn"), grandchild_key)

      child_key = key()

      publish!(
        String.replace(File.read!("test/fixtures/call_parent.bpmn"), "CHILD_KEY", grandchild_key),
        child_key
      )

      parent = start_parent!(child_key)
      [child] = children_of(parent)
      [grandchild] = children_of(child)
      assert reload(grandchild).status == :running

      assert TestJobs.fire_due!(DateTime.add(DateTime.utc_now(), @later_than_a_day)) >= 1

      assert reload(child).status == :cancelled
      assert reload(grandchild).status == :cancelled
      assert Enum.all?(tasks_of(grandchild), &(&1.status == :cancelled))
      assert reload(parent).status == :completed
    end

    test "a child that finishes first wins, and defuses the deadline" do
      {parent, _child_key} = start_call!(child: :approval)
      [child] = children_of(parent)
      [task] = tasks_of(child)

      {:ok, _} = AshBpmn.complete_task(task, outcome: :approved, actor: candidate_actor(task))

      assert reload(child).status == :completed
      assert reload(parent).status == :completed
      assert invoked?("after_child")
      assert boundary_jobs() == []

      assert TestJobs.fire_due!(DateTime.add(DateTime.utc_now(), @later_than_a_day)) == 0
      refute invoked?("escalate_it")
    end

    test "a child's error caught by an error boundary defuses the deadline too" do
      child_key = key()
      publish!(File.read!("test/fixtures/error_end.bpmn"), child_key)

      timer = """
      <bpmn2:boundaryEvent id="Boundary_1" attachedToRef="Referral">
        <bpmn2:outgoing>Flow_Late</bpmn2:outgoing>
        <bpmn2:timerEventDefinition><bpmn2:timeDuration>P1D</bpmn2:timeDuration></bpmn2:timerEventDefinition>
      </bpmn2:boundaryEvent>
      <bpmn2:endEvent id="End_Late"><bpmn2:incoming>Flow_Late</bpmn2:incoming></bpmn2:endEvent>
      <bpmn2:sequenceFlow id="Flow_Late" sourceRef="Boundary_1" targetRef="End_Late"/>
      </bpmn2:process>
      """

      defn =
        "test/fixtures/call_error_boundary.bpmn"
        |> File.read!()
        |> String.replace("CHILD_KEY", child_key)
        |> String.replace("</bpmn2:process>", timer)
        |> compile!()
        |> Definition.publish!()

      {:ok, parent} =
        AshBpmn.start_instance(AshBpmn.Test.Domain, definition: defn, subject: subject!())

      assert reload(parent).status == :completed
      assert invoked?("notify_gp")
      assert boundary_jobs() == []
      assert TestJobs.fire_due!(DateTime.add(DateTime.utc_now(), @later_than_a_day)) == 0
    end

    test "a non-interrupting boundary leaves the child running" do
      {parent, _child_key} = start_call!(child: :approval, interrupting: false)
      [child] = children_of(parent)

      assert TestJobs.fire_due!(DateTime.add(DateTime.utc_now(), @later_than_a_day)) >= 1

      assert invoked?("escalate_it")
      assert reload(child).status == :running
      assert token_at(parent, "Onboard").status == :waiting
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp key, do: "wb_#{System.unique_integer([:positive])}"

  defp create(xml), do: Definition.create!(%{key: key(), name: "WB", xml: xml})

  defp compile!(xml) do
    defn = create(xml)
    if is_nil(defn.graph), do: raise("compile failed: #{inspect(defn.errors)}")
    defn
  end

  defp publish!(xml, k) do
    defn = Definition.create!(%{key: k, name: k, xml: xml})
    if is_nil(defn.graph), do: raise("compile failed: #{inspect(defn.errors)}")
    Definition.publish!(defn)
  end

  defp non_interrupting(xml, false),
    do: String.replace(xml, ~s(attachedToRef=), ~s(cancelActivity="false" attachedToRef=))

  defp non_interrupting(xml, _), do: xml

  defp subject! do
    {:ok, subject} =
      AshBpmn.Test.Subject.create!(%{
        name: "wb",
        amount: 0,
        is_privileged: true,
        created_by_id: Ash.UUID.generate()
      })

    subject
  end

  defp start_receive!(opts \\ []) do
    defn =
      "test/fixtures/receive_task_boundary.bpmn"
      |> File.read!()
      |> non_interrupting(opts[:interrupting])
      |> compile!()
      |> Definition.publish!()

    subject = subject!()

    {:ok, instance} =
      AshBpmn.start_instance(AshBpmn.Test.Domain, definition: defn, subject: subject)

    {instance, subject}
  end

  defp call_xml(child_key) do
    "test/fixtures/call_activity_boundary.bpmn"
    |> File.read!()
    |> String.replace("CHILD_KEY", child_key)
  end

  defp start_call!(opts) do
    child_fixture = if opts[:child] == :approval, do: "access_request.bpmn", else: "linear.bpmn"
    child_key = key()
    publish!(File.read!("test/fixtures/#{child_fixture}"), child_key)
    {start_parent!(child_key, opts), child_key}
  end

  defp start_parent!(child_key, opts \\ []) do
    defn =
      child_key
      |> call_xml()
      |> non_interrupting(opts[:interrupting])
      |> compile!()
      |> Definition.publish!()

    {:ok, parent} =
      AshBpmn.start_instance(AshBpmn.Test.Domain, definition: defn, subject: subject!())

    parent
  end

  defp deliver!(data) do
    event = %{
      id: "evt-#{System.unique_integer([:positive])}",
      sequence: System.unique_integer([:positive]),
      occurred_at: DateTime.utc_now(),
      resource: "payment",
      action: :create,
      action_type: :create,
      record_id: Ash.UUID.generate(),
      version: 1,
      actor: nil,
      tenant: nil,
      data: data,
      changed: %{},
      metadata: %{}
    }

    {:ok, resources} = AshBpmn.Resources.for_domain(AshBpmn.Test.Domain)

    Correlator.dispatch_event(event, [], %{
      event_source: AshBpmn.Test.EventSource,
      resources: resources,
      scope: AshBpmn.Scope.system(:sweep)
    })
  end

  defp boundary_jobs do
    Enum.filter(TestJobs.all(), &(is_map(&1.args) and &1.args["boundary_id"] == "Boundary_1"))
  end

  defp invoked?(action) do
    Enum.any?(AshBpmn.Test.Invoker.recorded_calls(), fn {_id, a, _ts} -> a == action end)
  end

  defp read(resource, filter) do
    resource
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(^filter)
    |> Ash.read!(authorize?: false)
  end

  defp reload(instance), do: hd(read(Instance, id: instance.id))
  defp reload_task(task), do: hd(read(HumanTask, id: task.id))
  defp children_of(instance), do: read(Instance, parent_instance_id: instance.id)
  defp tasks_of(instance), do: read(HumanTask, instance_id: instance.id)
  defp tokens_of(instance), do: read(Token, instance_id: instance.id)
  defp events(instance), do: read(ProcessEvent, instance_id: instance.id)

  defp token_at(instance, node_id),
    do: instance |> tokens_of() |> Enum.find(&(&1.node_id == node_id))
end
