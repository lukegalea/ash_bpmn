# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.ScheduleTest do
  @moduledoc """
  A task's due date and follow-up date as data (DESIGN.md §11.5), and the reads over them.

  The negative cases come first: a due date that cannot be resolved is an incident, never a
  task parked without its deadline, and a task with no due date is in neither the overdue nor
  the follow-up read, because nil means "no deadline", not "on time".
  """

  use AshBpmn.DataCase, async: false

  require Ash.Query

  alias AshBpmn.Runtime.Oban.TestJobs
  alias AshBpmn.Scope
  alias AshBpmn.Test.{Definition, HumanTask, Instance, ProcessEvent, Resolver, Token}

  setup do
    TestJobs.clear()
    AshBpmn.ApprovalTestSupport.ensure_table!()
    Resolver.clear_escalations()
    on_exit(&Resolver.clear_escalations/0)
    :ok
  end

  describe "a due date that cannot be resolved is an incident" do
    test "a due expression that answers null fails the instance at the task, unretried" do
      {instance, nil} = start!(~s(<ash:schedule due="= subject.no_such_date"/>))

      instance = reload_instance(instance)
      assert instance.status == :failed

      assert [event] = events(instance, :timer_unresolved)
      assert event.node_id == "Review_1"
      assert event.data["timer"] == "schedule.due"
      assert event.data["expression"] == "= subject.no_such_date"
      assert event.data["reason"] =~ "null"

      # Failed on the first attempt: an incident is not retried, because the same data gives
      # the same answer. The ordinary failure path would have handed the token back.
      assert [failed] = events(instance, :action_failed)
      assert failed.data["reason"] == "timer_unresolved"
      assert failed.data["attempts"] == 1
      assert [%{status: :dead}] = Enum.filter(tokens(instance), &(&1.node_id == "Review_1"))

      # Nothing parks without its deadline.
      assert tasks(instance) == []
    end

    for {label, expression, reason} <- [
          {"a date with no time", ~s|= date(&quot;2030-01-01&quot;)|, "date with no time"},
          {"a date-time with no offset", ~s|= date and time(&quot;2030-01-01T10:00:00&quot;)|,
           "no offset"},
          {"a duration", ~s|= duration(&quot;P2D&quot;)|, "duration"},
          {"a string", ~s|= &quot;soon&quot;|, "not a date-time"}
        ] do
      test "a due expression that answers #{label} is an incident" do
        {instance, nil} = start!(~s(<ash:schedule due="#{unquote(expression)}"/>))

        assert reload_instance(instance).status == :failed
        assert [event] = events(instance, :timer_unresolved)
        assert event.data["reason"] =~ unquote(reason)
        assert tasks(instance) == []
      end
    end

    test "a followUp that cannot be resolved is an incident too" do
      {instance, nil} = start!(~s(<ash:schedule due="P3D" followUp="= null"/>))

      assert reload_instance(instance).status == :failed
      assert [event] = events(instance, :timer_unresolved)
      assert event.data["timer"] == "schedule.followUp"
      assert tasks(instance) == []
    end
  end

  describe "a task with no due date" do
    test "with no schedule and no expire timer, due_at is nil and it is in neither read" do
      {_instance, task} = start!("")

      assert task.due_at == nil
      assert task.follow_up_at == nil
      refute load_overdue?(task)
      assert read(:overdue) == []
      assert read(:follow_up_due) == []
    end

    test "with no due but an expire timer, the expire instant is the due date" do
      {_instance, task} = start!("", ~s(<ash:timer kind="expire" hours="6"/>))

      assert [job] = Enum.filter(TestJobs.all(), &(&1.args["kind"] == "expire"))
      assert task.due_at == job.scheduled_at
    end
  end

  describe "a due date that resolves" do
    test "a duration literal counts from the task's creation" do
      {_instance, task} = start!(~s(<ash:schedule due="P3D" followUp="PT36H"/>))

      assert_about(task.due_at, DateTime.add(task.inserted_at, 3, :day))
      assert_about(task.follow_up_at, DateTime.add(task.inserted_at, 36, :hour))
      refute load_overdue?(task)
    end

    test "an expression reads the subject, and followUp can read the task's due date" do
      {_instance, task} =
        start!(
          ~s|<ash:schedule due="= subject.inserted_at + duration(&quot;P30D&quot;)" | <>
            ~s|followUp="= task.due_at - duration(&quot;P2D&quot;)"/>|
        )

      subject = AshBpmn.Subject.load(reload_instance_of(task), Scope.system(:timer))
      assert_about(task.due_at, DateTime.add(subject.inserted_at, 30, :day))
      assert_about(task.follow_up_at, DateTime.add(task.due_at, -2, :day))
    end

    test "an explicit due beats the expire timer" do
      {_instance, task} =
        start!(~s(<ash:schedule due="P1D"/>), ~s(<ash:timer kind="expire" hours="6"/>))

      assert_about(task.due_at, DateTime.add(task.inserted_at, 1, :day))
    end

    test "a due date already past is recorded as it is, and the task starts overdue" do
      {instance, task} =
        start!(~s|<ash:schedule due="= now() - duration(&quot;P1D&quot;)"/>|)

      assert DateTime.before?(task.due_at, DateTime.utc_now())
      assert load_overdue?(task)
      assert [%{id: id}] = read(:overdue)
      assert id == task.id

      assert [created] = events(instance, :task_created)
      assert created.data["overdue_on_creation"] == true
      assert created.data["due_at"] == DateTime.to_iso8601(task.due_at)
    end
  end

  describe "the :overdue read" do
    test "leaves out completed and cancelled tasks, and tasks not yet due" do
      past = DateTime.add(DateTime.utc_now(), -3600, :second)

      overdue = task!(due_at: past)
      _completed = task!(due_at: past, status: :completed)
      _cancelled = task!(due_at: past, status: :cancelled)
      _not_due = task!(due_at: DateTime.add(DateTime.utc_now(), 3600, :second))
      claimed = task!(due_at: DateTime.add(past, -60, :second), status: :claimed)

      # Oldest due first.
      assert Enum.map(read(:overdue), & &1.id) == [claimed.id, overdue.id]
    end

    test "another tenant's overdue tasks never appear" do
      acme = Ash.UUID.generate()
      globex = Ash.UUID.generate()
      past = DateTime.add(DateTime.utc_now(), -3600, :second)

      mine = tenant_task!(acme, past)
      _theirs = tenant_task!(globex, past)

      assert [%{id: id}] =
               AshBpmn.TenantTest.HumanTask
               |> Ash.Query.for_read(:overdue)
               |> Ash.read!(tenant: acme, authorize?: false)

      assert id == mine.id
    end
  end

  describe "the :follow_up_due read" do
    test "returns live tasks whose follow-up date has come, earliest first" do
      now = DateTime.utc_now()

      later = task!(follow_up_at: DateTime.add(now, -60, :second))
      earlier = task!(follow_up_at: DateTime.add(now, -3600, :second))
      _future = task!(follow_up_at: DateTime.add(now, 3600, :second))
      _done = task!(follow_up_at: DateTime.add(now, -60, :second), status: :completed)
      _none = task!([])

      assert Enum.map(read(:follow_up_due), & &1.id) == [earlier.id, later.id]
    end
  end

  describe "a standalone approval" do
    test "takes its expiry as its due date when it has no due_in, and keeps follow_up_in" do
      AshBpmn.ApprovalTestSupport.ApprovalSubject.request_followed_up!(%{
        name: "followed_#{System.unique_integer([:positive])}",
        created_by_id: Ash.UUID.generate()
      })

      task = latest_task!("test_followed_up_approval")
      assert [expire] = Enum.filter(TestJobs.all(), &(&1.args["task_id"] == task.id))
      assert expire.args["kind"] == "expire"
      assert task.due_at == expire.scheduled_at
      assert_about(task.follow_up_at, DateTime.add(task.inserted_at, 2, :day))
    end
  end

  describe "the compiler" do
    test "refuses a malformed schedule, naming the node" do
      for {schedule, message} <- [
            {~s(<ash:schedule due="2030-01-01T00:00:00Z"/>), "literal date"},
            {~s(<ash:schedule due="P1M"/>), "months or years"},
            {~s(<ash:schedule due="PT0S"/>), "longer than zero"},
            {~s(<ash:schedule due=""/>), "is empty"},
            {~s|<ash:schedule due="= subject.("/>|, "not a valid FEEL expression"},
            {~s(<ash:schedule/>), "neither due nor followUp"},
            {~s(<ash:schedule due="P1D" remind="P1D"/>), "Unknown attribute 'remind'"},
            {~s(<ash:schedule due="P1D"/><ash:schedule due="P2D"/>), "more than one"}
          ] do
        defn = Definition.create!(%{key: key(), name: "Sched", xml: xml(schedule, "")})

        assert defn.graph == nil, "expected #{schedule} to be refused"
        assert Enum.any?(defn.errors, &(err(&1, :path) == "Review_1")), inspect(defn.errors)

        assert Enum.any?(defn.errors, &(err(&1, :message) =~ message)),
               "expected #{inspect(message)} in #{inspect(defn.errors)}"
      end
    end

    test "stores a duration as seconds and an expression as its source" do
      defn =
        Definition.create!(%{
          key: key(),
          name: "Sched",
          xml: xml(~s|<ash:schedule due="P2D" followUp="= now()"/>|, "")
        })

      assert %{"due" => due, "follow_up" => follow_up} =
               defn.graph["nodes"]["Review_1"]["schedule"]

      assert due == %{"form" => "duration", "source" => "P2D", "seconds" => 172_800}
      assert follow_up["form"] == "expression"
      assert follow_up["feel"]["text"] == "now()"
    end
  end

  describe "the resolver's :decisions" do
    test "an exclusion can name whoever decided an earlier task in the instance" do
      {instance, review} = start!("")
      first_reviewer = Resolver.role_member("reviewer")

      assert {:ok, _} =
               AshBpmn.complete_task(review, outcome: :unsure, actor: %{id: first_reviewer})

      assert [second] = Enum.filter(tasks(instance), &(&1.node_id == "Review_2"))

      decisions = Resolver.last_exclusion_ctx().decisions
      assert decisions["Review_1"].decided_by_id == first_reviewer
      assert decisions["Review_1"].outcome == "unsure"

      # The first reviewer is excluded from the senior review; the senior steward remains.
      assert first_reviewer in second.excluded_principal_ids
      assert candidate_ids(second) == [Resolver.role_member("senior")]
      assert {:error, _} = AshBpmn.claim_task(second, actor: %{id: first_reviewer})
    end
  end

  describe "the escalate context" do
    test "carries the tenant, the instance, its subject, the candidates, exclusions and timer" do
      tenant = Ash.UUID.generate()
      creator = Ash.UUID.generate()
      defn = tenant_definition!(tenant, xml("", ~s(<ash:timer kind="escalate" hours="4"/>)))

      {:ok, subject} =
        AshBpmn.Test.Subject.create!(%{name: "esc", amount: 1, created_by_id: creator})

      {:ok, instance} =
        AshBpmn.start_instance(AshBpmn.TenantTest.Domain,
          definition: defn,
          subject: subject,
          tenant: tenant
        )

      [task] =
        AshBpmn.TenantTest.HumanTask
        |> Ash.Query.filter(instance_id == ^instance.id)
        |> Ash.read!(Scope.engine(%Scope{tenant: tenant}))

      TestJobs.fire!("escalate", task.id)

      assert [ctx] = Resolver.escalation_ctxs()
      assert ctx.tenant == tenant
      assert ctx.instance.id == instance.id
      assert ctx.subject.id == subject.id
      assert ctx.task.id == task.id
      assert ctx.candidates == [%{type: :user, id: Resolver.role_member("reviewer")}]
      assert ctx.exclusions == [creator]
      assert ctx.timer.key == "#{task.id}/Review_1/0/1"
      assert ctx.timer.repetition == 1
    end

    test "a standalone approval's escalation carries its subject and tenant" do
      AshBpmn.ApprovalTestSupport.ApprovalSubject.create!(%{
        name: "esc_#{System.unique_integer([:positive])}",
        created_by_id: Ash.UUID.generate()
      })

      task = latest_task!("test_approval")
      TestJobs.fire!("escalate", task.id)

      assert [ctx] = Resolver.escalation_ctxs()
      assert ctx.instance == nil
      assert ctx.subject.id == task.subject_id
      assert ctx.timer.key == "#{task.id}/test_approval/0/1"
      assert [_] = ctx.candidates
      assert Map.has_key?(ctx, :tenant)
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp start!(schedule, timers \\ "") do
    defn = Definition.create!(%{key: key(), name: "Sched", xml: xml(schedule, timers)})
    if is_nil(defn.graph), do: raise("compile failed: #{inspect(defn.errors)}")
    defn = Definition.publish!(defn)

    {:ok, subject} =
      AshBpmn.Test.Subject.create!(%{
        name: "sched",
        amount: 0,
        created_by_id: Ash.UUID.generate()
      })

    {:ok, instance} =
      AshBpmn.start_instance(AshBpmn.Test.Domain, definition: defn, subject: subject)

    {instance, instance |> tasks() |> List.first()}
  end

  defp xml(schedule, timers) do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <bpmn2:definitions xmlns:bpmn2="http://www.omg.org/spec/BPMN/20100524/MODEL"
                       xmlns:ash="https://github.com/lukegalea/ash_bpmn/ns"
                       id="Definitions_schedule"
                       targetNamespace="https://github.com/lukegalea/ash_bpmn/ns">
      <bpmn2:process id="Process_schedule" isExecutable="true">
        <bpmn2:startEvent id="Start_1"><bpmn2:outgoing>Flow_1</bpmn2:outgoing></bpmn2:startEvent>
        <bpmn2:userTask id="Review_1" name="Review">
          <bpmn2:extensionElements>
            <ash:taskConfig>
              <ash:candidates><ash:candidate kind="role" of="reviewer"/></ash:candidates>
              <ash:exclusions><ash:exclusion who="subject.created_by_id"/></ash:exclusions>
              <ash:outcomes>
                <ash:outcome name="approved"/>
                <ash:outcome name="unsure"/>
              </ash:outcomes>
              #{schedule}
              #{if timers == "", do: "", else: "<ash:timers>#{timers}</ash:timers>"}
            </ash:taskConfig>
          </bpmn2:extensionElements>
          <bpmn2:incoming>Flow_1</bpmn2:incoming>
          <bpmn2:outgoing>Flow_2</bpmn2:outgoing>
        </bpmn2:userTask>
        <bpmn2:userTask id="Review_2" name="Senior review">
          <bpmn2:extensionElements>
            <ash:taskConfig>
              <ash:candidates>
                <ash:candidate kind="role" of="reviewer"/>
                <ash:candidate kind="role" of="senior"/>
              </ash:candidates>
              <ash:exclusions><ash:exclusion who="decided_by:Review_1"/></ash:exclusions>
              <ash:outcomes><ash:outcome name="approved"/></ash:outcomes>
            </ash:taskConfig>
          </bpmn2:extensionElements>
          <bpmn2:incoming>Flow_2</bpmn2:incoming>
          <bpmn2:outgoing>Flow_3</bpmn2:outgoing>
        </bpmn2:userTask>
        <bpmn2:endEvent id="End_1"><bpmn2:incoming>Flow_3</bpmn2:incoming></bpmn2:endEvent>
        <bpmn2:sequenceFlow id="Flow_1" sourceRef="Start_1" targetRef="Review_1"/>
        <bpmn2:sequenceFlow id="Flow_2" sourceRef="Review_1" targetRef="Review_2"/>
        <bpmn2:sequenceFlow id="Flow_3" sourceRef="Review_2" targetRef="End_1"/>
      </bpmn2:process>
    </bpmn2:definitions>
    """
  end

  defp tenant_definition!(tenant, xml) do
    defn =
      AshBpmn.TenantTest.Definition.create!(
        %{key: key(), name: "Sched", xml: xml},
        Scope.engine(%Scope{tenant: tenant})
      )

    if is_nil(defn.graph), do: raise("compile failed: #{inspect(defn.errors)}")

    AshBpmn.TestRepo.query!(
      "UPDATE tenant_bpmn_definitions SET status = 'published' WHERE id = $1",
      [Ecto.UUID.dump!(defn.id)]
    )

    AshBpmn.TenantTest.Definition
    |> Ash.Query.filter(id == ^defn.id)
    |> Ash.read_one!(Scope.engine(%Scope{tenant: tenant}))
  end

  defp err(error, field), do: Map.get(error, field) || Map.get(error, to_string(field))

  defp key, do: "sched_#{System.unique_integer([:positive])}"

  defp task!(attrs) do
    {status, attrs} = Keyword.pop(attrs, :status, :open)

    task =
      HumanTask.create!(
        Map.merge(
          %{node_id: "n_#{System.unique_integer([:positive])}", name: "t"},
          Map.new(attrs)
        ),
        authorize?: false
      )

    if status == :open do
      task
    else
      AshBpmn.TestRepo.query!("UPDATE bpmn_human_tasks SET status = $1 WHERE id = $2", [
        to_string(status),
        Ecto.UUID.dump!(task.id)
      ])

      task
    end
  end

  defp tenant_task!(tenant, due_at) do
    AshBpmn.TenantTest.HumanTask.create!(
      %{node_id: "n_#{System.unique_integer([:positive])}", name: "t", due_at: due_at},
      Scope.engine(%Scope{tenant: tenant})
    )
  end

  defp read(action) do
    HumanTask
    |> Ash.Query.for_read(action)
    |> Ash.read!(authorize?: false)
  end

  defp load_overdue?(task) do
    HumanTask
    |> Ash.Query.filter(id == ^task.id)
    |> Ash.Query.load(:overdue?)
    |> Ash.read_one!(authorize?: false)
    |> Map.fetch!(:overdue?)
  end

  defp latest_task!(node_id) do
    HumanTask
    |> Ash.Query.filter(status == :open and node_id == ^node_id)
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.read!(authorize?: false)
    |> List.first()
  end

  defp tasks(instance) do
    HumanTask
    |> Ash.Query.filter(instance_id == ^instance.id)
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.read!(authorize?: false)
  end

  defp tokens(instance) do
    Token
    |> Ash.Query.filter(instance_id == ^instance.id)
    |> Ash.read!(authorize?: false)
  end

  defp candidate_ids(task) do
    AshBpmn.Test.TaskCandidate
    |> Ash.Query.filter(task_id == ^task.id)
    |> Ash.read!(authorize?: false)
    |> Enum.map(& &1.principal_id)
  end

  defp events(instance, kind) do
    ProcessEvent
    |> Ash.Query.filter(instance_id == ^instance.id and kind == ^kind)
    |> Ash.read!(authorize?: false)
  end

  defp reload_instance(instance) do
    Instance
    |> Ash.Query.filter(id == ^instance.id)
    |> Ash.read_one!(authorize?: false)
  end

  defp reload_instance_of(task) do
    Instance
    |> Ash.Query.filter(id == ^task.instance_id)
    |> Ash.read_one!(authorize?: false)
  end

  # Within a second: the engine and the test read the clock at slightly different instants.
  defp assert_about(%DateTime{} = actual, %DateTime{} = expected) do
    assert abs(DateTime.diff(actual, expected, :millisecond)) < 1_000,
           "expected #{actual} to be within a second of #{expected}"
  end
end
