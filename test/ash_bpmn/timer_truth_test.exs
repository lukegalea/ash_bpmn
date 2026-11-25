# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.TimerTruthTest do
  @moduledoc """
  What a timer must never do, whatever happens around it (DESIGN.md §11.3, §11.4):

    * move when the data it reads has not changed;
    * read null for a date the task has;
    * fire twice under one key;
    * fire for work that ended, or at an instant a reschedule moved, because the end or the
      move committed while the firing waited for the instance's lock (`TimerRaceTest` has the
      interleavings on real connections);
    * stay armed in the ledger after its task expired or was interrupted.
  """

  use AshBpmn.DataCase, async: false

  require Ash.Query

  alias AshBpmn.Runtime.Oban.TestJobs
  alias AshBpmn.Runtime.TimerWorker
  alias AshBpmn.Scope
  alias AshBpmn.Test.{Definition, HumanTask, ProcessEvent, TimerJob}

  setup do
    AshBpmn.Test.Invoker.clear_calls()
    TestJobs.clear()
    :ok
  end

  describe "reschedule_timers/2 with data that has not changed" do
    test "moves no duration-expression timer, however often it is called" do
      tenant = Ash.UUID.generate()
      {subject, instance} = tenant_instance!(tenant, ~s|duration="= duration(&quot;PT6H&quot;)"|)
      [job] = TestJobs.all()

      assert reschedule(subject) == {:ok, 0}
      assert reschedule(subject) == {:ok, 0}

      assert [%{scheduled_at: at}] = TestJobs.all()
      assert at == job.scheduled_at
      assert tenant_events(instance, tenant, :timers_rescheduled) == []
    end

    test "moves no start-less cycle expression" do
      tenant = Ash.UUID.generate()
      {subject, instance} = tenant_instance!(tenant, ~s|cycle="= &quot;R3/PT1H&quot;"|)
      [job] = TestJobs.all()

      assert reschedule(subject) == {:ok, 0}
      assert [%{scheduled_at: at}] = TestJobs.all()
      assert at == job.scheduled_at
      assert tenant_events(instance, tenant, :timers_rescheduled) == []
    end

    test "counts a moved duration from when the timer was first armed, not the last write" do
      # A duration read from data: one hour for every unit of the subject's amount.
      defn =
        publish!(
          task_xml(
            ~s|<ash:timer kind="remind" duration="= duration(&quot;PT1H&quot;) * subject.amount"/>|
          )
        )

      {:ok, subject} =
        AshBpmn.Test.Subject.create!(%{name: "truth", amount: 6, is_privileged: false})

      {:ok, instance} =
        AshBpmn.start_instance(AshBpmn.Test.Domain, definition: defn, subject: subject)

      [first] = ledger_for(instance)
      armed_at = first.inserted_at

      subject = update_amount!(subject, 8)
      assert {:ok, 1} = AshBpmn.reschedule_timers(subject, domain: AshBpmn.Test.Domain)

      subject = update_amount!(subject, 9)
      assert {:ok, 1} = AshBpmn.reschedule_timers(subject, domain: AshBpmn.Test.Domain)

      [%{scheduled_at: at}] = TestJobs.all()
      expected = DateTime.add(armed_at, 9, :hour)
      assert abs(DateTime.diff(at, expected, :millisecond)) < 1_000

      # And once more with nothing changed: still where it was.
      assert {:ok, 0} = AshBpmn.reschedule_timers(subject, domain: AshBpmn.Test.Domain)
    end
  end

  describe "a timer expression reading the task's own dates" do
    test "task.follow_up_at is the schedule's follow-up date" do
      defn =
        publish!(
          task_xml(
            ~s|<ash:timer kind="remind" date="= task.follow_up_at"/>|,
            ~s|<ash:schedule due="P10D" followUp="P1D"/>|
          )
        )

      instance = start!(defn)

      assert events_of(instance, :timer_unresolved) == []
      assert [task] = tasks_for(instance)
      assert [job] = TestJobs.all()
      assert job.scheduled_at == task.follow_up_at
    end

    test "task.due_at is the due date even when it falls back to the expire timer" do
      defn =
        publish!(
          task_xml(~s|<ash:timer kind="remind" date="= task.due_at - duration(&quot;PT1H&quot;)"/>
            <ash:timer kind="expire" days="7"/>|)
        )

      instance = start!(defn)

      assert events_of(instance, :timer_unresolved) == []
      assert [task] = tasks_for(instance)
      assert task.due_at

      remind = Enum.find(TestJobs.all(), &(&1.args["kind"] == "remind"))
      assert remind.scheduled_at == DateTime.add(task.due_at, -1, :hour)
    end

    test "a follow-up that reads a due date falling back to expiry gets that date" do
      defn =
        publish!(
          task_xml(
            ~s|<ash:timer kind="remind" date="= task.follow_up_at"/>
               <ash:timer kind="expire" days="7"/>|,
            ~s|<ash:schedule followUp="= task.due_at - duration(&quot;P2D&quot;)"/>|
          )
        )

      instance = start!(defn)

      assert events_of(instance, :timer_unresolved) == []
      assert [task] = tasks_for(instance)
      assert task.follow_up_at == DateTime.add(task.due_at, -2, :day)
      remind = Enum.find(TestJobs.all(), &(&1.args["kind"] == "remind"))
      assert remind.scheduled_at == task.follow_up_at
    end

    test "an expire timer reading its own due date is still an incident, not a guess" do
      defn =
        publish!(task_xml(~s|<ash:timer kind="expire" date="= task.due_at"/>|))

      instance = start!(defn)

      assert [event] = events_of(instance, :timer_unresolved)
      assert event.data["reason"] =~ "null"
      assert tasks_for(instance) == []
    end
  end

  describe "a signal escalation delivered twice" do
    test "throws its signal once and records one firing under its key" do
      defn = publish!(task_xml(~s|<ash:timer kind="escalate" hours="2" signal="stalled"/>|))
      instance = start!(defn)
      [job] = TestJobs.all()

      assert {:ok, :escalated} = perform(job)
      assert {:ok, :already_fired} = perform(job)

      assert [_] = Ash.read!(AshBpmn.Test.Signal, authorize?: false)
      assert [fired] = events_of(instance, :timer_fired)
      assert fired.data["key"] =~ ~r|/Review/0/1$|
      assert [%{status: :fired}] = ledger_for(instance)
    end
  end

  describe "an expiry" do
    test "cancels the task's other timers, in Oban and in the ledger" do
      defn =
        publish!(task_xml(~s|<ash:timer kind="remind" hours="2"/>
             <ash:timer kind="escalate" hours="4"/>
             <ash:timer kind="expire" hours="1"/>|))

      instance = start!(defn)
      assert TestJobs.fire_due!(DateTime.add(DateTime.utc_now(), 3_700)) == 1

      ledger = ledger_for(instance) |> Enum.map(&{&1.kind, &1.status, &1.cancel_reason})
      assert {:expire, :fired, nil} in ledger
      assert {:remind, :cancelled, :task_expired} in ledger
      assert {:escalate, :cancelled, :task_expired} in ledger

      refute Enum.any?(TestJobs.all(), &(&1.args["kind"] in ["remind", "escalate"]))
    end

    test "leaves reschedule_timers/2 nothing to re-arm for the expired task" do
      tenant = Ash.UUID.generate()

      {subject, instance} =
        tenant_instance!(
          tenant,
          ~s|date="= subject.notice_at"/><ash:timer kind="expire" hours="1"|
        )

      assert TestJobs.fire_due!(DateTime.add(DateTime.utc_now(), 3_700)) == 1

      assert Enum.all?(tenant_ledger(instance, tenant), &(&1.status != :scheduled))

      later = DateTime.add(DateTime.utc_now(), 2, :day)
      subject = update_subject!(subject, %{notice_at: later}, tenant)
      assert reschedule(subject) == {:ok, 0}

      # Only the dead task read notice_at: clearing it is not an incident for anyone.
      subject = update_subject!(subject, %{notice_at: nil}, tenant)
      assert reschedule(subject) == {:ok, 0}
    end
  end

  describe "an interrupting boundary" do
    test "cancels the interrupted task's own timers in the ledger, not just its boundaries" do
      defn = publish!(boundary_with_task_timers_xml())
      instance = start!(defn)

      assert TestJobs.fire_due!(DateTime.add(DateTime.utc_now(), 3_700)) == 1

      ledger = ledger_for(instance) |> Enum.map(&{&1.kind, &1.status, &1.cancel_reason})
      assert {:boundary, :fired, nil} in ledger
      assert {:remind, :cancelled, :task_cancelled} in ledger
      refute Enum.any?(TestJobs.all(), &(&1.args["kind"] == "remind"))
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp perform(job),
    do: TimerWorker.perform(%Oban.Job{id: job.id, args: job.args, attempt: 1, max_attempts: 3})

  defp reschedule(subject),
    do: AshBpmn.reschedule_timers(subject, domain: AshBpmn.TenantTest.Domain)

  defp tenant_subject!(tenant, attrs) do
    AshBpmn.TenantTest.Subject
    |> Ash.Changeset.for_create(:create, Map.merge(%{name: "s"}, attrs),
      tenant: tenant,
      authorize?: false
    )
    |> Ash.create!()
  end

  defp update_subject!(subject, attrs, tenant) do
    subject
    |> Ash.Changeset.for_update(:update, attrs, tenant: tenant, authorize?: false)
    |> Ash.update!()
  end

  defp update_amount!(subject, amount) do
    subject
    |> Ash.Changeset.for_update(:update, %{amount: amount}, authorize?: false)
    |> Ash.update!()
  end

  defp tenant_instance!(tenant, timer_attrs, notice_at \\ nil) do
    key = "truth_#{System.unique_integer([:positive])}"
    scope = Scope.engine(%Scope{tenant: tenant})

    xml = task_xml(~s|<ash:timer kind="remind" #{timer_attrs}/>|)
    defn = AshBpmn.TenantTest.Definition.create!(%{key: key, name: key, xml: xml}, scope)
    if is_nil(defn.graph), do: flunk("compile failed: #{inspect(defn.errors)}")
    AshBpmn.TenantTest.Definition.publish!(defn, scope)

    subject =
      tenant_subject!(tenant, %{
        notice_at: notice_at || DateTime.add(DateTime.utc_now(), 6, :hour)
      })

    {:ok, instance} =
      AshBpmn.start_instance(AshBpmn.TenantTest.Domain,
        process: key,
        subject: subject,
        tenant: tenant
      )

    {subject, instance}
  end

  defp tenant_ledger(instance, tenant) do
    AshBpmn.TenantTest.TimerJob
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(instance_id == ^instance.id)
    |> Ash.read!(Scope.engine(%Scope{tenant: tenant}))
  end

  defp tenant_events(instance, tenant, kind) do
    AshBpmn.TenantTest.ProcessEvent
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(instance_id == ^instance.id and kind == ^kind)
    |> Ash.read!(Scope.engine(%Scope{tenant: tenant}))
  end

  defp task_xml(timers, schedule \\ "") do
    wrap("""
    <bpmn2:userTask id="Review" name="Review">
      <bpmn2:extensionElements>
        <ash:taskConfig>
          <ash:candidates><ash:candidate kind="role" of="reviewer"/></ash:candidates>
          <ash:outcomes><ash:outcome name="approved"/></ash:outcomes>
          #{schedule}
          <ash:timers>#{timers}</ash:timers>
        </ash:taskConfig>
      </bpmn2:extensionElements>
      <bpmn2:incoming>F1</bpmn2:incoming>
      <bpmn2:outgoing>F2</bpmn2:outgoing>
    </bpmn2:userTask>
    """)
  end

  defp boundary_with_task_timers_xml do
    wrap(
      """
      <bpmn2:userTask id="Review" name="Review">
        <bpmn2:extensionElements>
          <ash:taskConfig>
            <ash:candidates><ash:candidate kind="role" of="reviewer"/></ash:candidates>
            <ash:outcomes><ash:outcome name="approved"/></ash:outcomes>
            <ash:timers><ash:timer kind="remind" hours="2"/></ash:timers>
          </ash:taskConfig>
        </bpmn2:extensionElements>
        <bpmn2:incoming>F1</bpmn2:incoming>
        <bpmn2:outgoing>F2</bpmn2:outgoing>
      </bpmn2:userTask>
      <bpmn2:boundaryEvent id="Boundary" attachedToRef="Review" cancelActivity="true">
        <bpmn2:outgoing>F3</bpmn2:outgoing>
        <bpmn2:timerEventDefinition id="T"><bpmn2:timeDuration>PT1H</bpmn2:timeDuration></bpmn2:timerEventDefinition>
      </bpmn2:boundaryEvent>
      <bpmn2:endEvent id="Late"><bpmn2:incoming>F3</bpmn2:incoming></bpmn2:endEvent>
      <bpmn2:sequenceFlow id="F3" sourceRef="Boundary" targetRef="Late"/>
      """,
      "Review"
    )
  end

  defp wrap(body, middle \\ nil) do
    middle = middle || body |> then(&Regex.run(~r/id="(\w+)"/, &1)) |> List.last()

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <bpmn2:definitions xmlns:bpmn2="http://www.omg.org/spec/BPMN/20100524/MODEL"
                       xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
                       xmlns:ash="https://github.com/lukegalea/ash_bpmn/ns"
                       id="Defs" targetNamespace="https://github.com/lukegalea/ash_bpmn/ns">
      <bpmn2:process id="P" isExecutable="true">
        <bpmn2:startEvent id="Start"><bpmn2:outgoing>F1</bpmn2:outgoing></bpmn2:startEvent>
        #{body}
        <bpmn2:endEvent id="End"><bpmn2:incoming>F2</bpmn2:incoming></bpmn2:endEvent>
        <bpmn2:sequenceFlow id="F1" sourceRef="Start" targetRef="#{middle}"/>
        <bpmn2:sequenceFlow id="F2" sourceRef="#{middle}" targetRef="End"/>
      </bpmn2:process>
    </bpmn2:definitions>
    """
  end

  defp publish!(xml) do
    defn =
      Definition.create!(%{key: "tt_#{System.unique_integer([:positive])}", name: "TT", xml: xml})

    if is_nil(defn.graph), do: flunk("compile failed: #{inspect(defn.errors)}")
    Definition.publish!(defn)
  end

  defp start!(defn) do
    {:ok, subject} =
      AshBpmn.Test.Subject.create!(%{name: "truth", amount: 0, is_privileged: false})

    {:ok, instance} =
      AshBpmn.start_instance(AshBpmn.Test.Domain, definition: defn, subject: subject)

    instance
  end

  defp tasks_for(instance) do
    HumanTask
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(instance_id == ^instance.id)
    |> Ash.read!(authorize?: false)
  end

  defp ledger_for(instance) do
    TimerJob
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(instance_id == ^instance.id)
    |> Ash.read!(authorize?: false)
  end

  defp events_of(instance, kind) do
    ProcessEvent
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(instance_id == ^instance.id and kind == ^kind)
    |> Ash.Query.sort(recorded_at: :asc)
    |> Ash.read!(authorize?: false)
  end
end
