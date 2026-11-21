# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.TimerCycleTest do
  @moduledoc """
  DESIGN.md §11.3: bounded cycles, armed one repetition at a time, and
  `AshBpmn.reschedule_timers/2`.

  The refusals come first: a cycle is allowed only where repeating means something, and only
  with a count. Then what a cycle may never do: arm two of the same repetition, fire for work
  that is over, or arm past its count.
  """

  use AshBpmn.DataCase, async: false

  require Ash.Query

  alias AshBpmn.Runtime.Oban.TestJobs
  alias AshBpmn.Runtime.TimerWorker
  alias AshBpmn.Scope
  alias AshBpmn.Test.{Definition, HumanTask, ProcessEvent, Resolver, TimerJob, Token}

  setup do
    AshBpmn.Test.Invoker.clear_calls()
    TestJobs.clear()
    :ok
  end

  # ── compile-time refusals ───────────────────────────────────────────────

  describe "a cycle is refused" do
    for {attrs, expected} <- [
          {~s|kind="escalate" cycle="R3/PT1H"|, "only a remind timer repeats"},
          {~s|kind="expire" cycle="R3/PT1H"|, "only a remind timer repeats"},
          {~s|kind="remind" cycle="R/PT1H"|, "unbounded"},
          {~s|kind="remind" cycle="R0/PT1H"|, "from 1 to 100"},
          {~s|kind="remind" cycle="R101/PT1H"|, "from 1 to 100"},
          {~s|kind="remind" cycle="0 9 * * *"|, "R<n>/<duration>"},
          {~s|kind="remind" cycle="R3/P1M"|, "months and years"},
          {~s|kind="remind" cycle="R3/PT0S"|, "positive amount"},
          {~s|kind="remind" cycle="R3/2026-12-01T09:00:00Z/P1D"|, "may not name its start"},
          {~s|kind="remind" cycle=""|, "empty"}
        ] do
      test "on an ash:timer: #{attrs}" do
        errors = errors_for(task_xml(~s|<ash:timer #{unquote(attrs)}/>|))

        assert errors =~ unquote(expected),
               "expected #{inspect(unquote(expected))} in: #{errors}"

        assert errors =~ "Review"
      end
    end

    test "on an interrupting boundary, which fires once" do
      errors =
        errors_for(boundary_xml(~s|<bpmn2:timeCycle>R3/PT1H</bpmn2:timeCycle>|, true))

      assert errors =~ "timeCycle"
      assert errors =~ "non-interrupting boundary"
    end

    test "on an intermediate catch event, which fires once" do
      errors = errors_for(catch_xml(~s|<bpmn2:timeCycle>R3/PT1H</bpmn2:timeCycle>|))
      assert errors =~ "non-interrupting boundary"
    end

    test "unbounded, on a non-interrupting boundary" do
      errors = errors_for(boundary_xml(~s|<bpmn2:timeCycle>R/PT1H</bpmn2:timeCycle>|, false))
      assert errors =~ "unbounded"
      assert errors =~ "Boundary"
    end
  end

  test "a cycle compiles on a reminder and on a non-interrupting boundary" do
    graph = compile!(task_xml(~s|<ash:timer kind="remind" cycle="R3/PT1H"/>|))

    assert [%{"kind" => "remind", "moment" => moment}] =
             get_in(graph, ["nodes", "Review", "timers"])

    assert moment == %{"form" => "cycle", "literal" => "R3/PT1H", "count" => 3, "seconds" => 3600}

    graph = compile!(boundary_xml(~s|<bpmn2:timeCycle>R2/PT30M</bpmn2:timeCycle>|, false))
    assert %{"cycle" => "R2/PT30M"} = get_in(graph, ["nodes", "Boundary", "catch"])
  end

  # ── a cycle at run time ─────────────────────────────────────────────────

  describe "a repeating reminder" do
    test "R3 fires three times, one repetition armed at a time, and no fourth" do
      defn = publish!(task_xml(~s|<ash:timer kind="remind" cycle="R3/PT1H"/>|))
      instance = start!(defn)
      [task] = tasks_for(instance)
      now = DateTime.utc_now()

      assert [%{args: %{"repetition" => 1}}] = TestJobs.all()

      for {rep, hours} <- [{1, 1}, {2, 2}, {3, 3}] do
        assert [job] = TestJobs.all()
        assert job.args["repetition"] == rep
        assert job.args["key"] == "#{task.id}/Review/0/#{rep}"
        assert_in_delta DateTime.diff(job.scheduled_at, now), hours * 3600, 60
        assert TestJobs.fire_due!(DateTime.add(now, hours * 3600 + 60)) == 1
      end

      assert TestJobs.all() == []

      assert Enum.map(events_of(instance, :timer_fired), & &1.data["key"]) ==
               for(rep <- 1..3, do: "#{task.id}/Review/0/#{rep}")

      rows = ledger_for(instance)
      assert length(rows) == 3
      assert Enum.all?(rows, &(&1.status == :fired))
      assert rows |> Enum.map(& &1.data["repetition"]) |> Enum.sort() == [1, 2, 3]
      assert events_of(instance, :timer_skipped) == []
    end

    test "a task completed after repetition 1 gets no repetition 2" do
      defn = publish!(task_xml(~s|<ash:timer kind="remind" cycle="R3/PT1H"/>|))
      instance = start!(defn)
      [task] = tasks_for(instance)

      assert TestJobs.fire_due!(DateTime.add(DateTime.utc_now(), 3660)) == 1
      assert [rep2] = TestJobs.all()
      assert rep2.args["repetition"] == 2

      {:ok, _} = AshBpmn.complete_task(task, outcome: :approved, actor: reviewer())

      # Cancelled with the task, in Oban and on the ledger.
      assert TestJobs.all() == []

      assert [%{status: :cancelled, cancel_reason: :task_decided}] =
               Enum.filter(ledger_for(instance), &(&1.data["repetition"] == 2))

      # And a copy that escaped the cancel fires nothing and arms nothing.
      assert {:ok, :skipped} = TimerWorker.perform(%Oban.Job{args: rep2.args})
      assert TestJobs.all() == []
      assert length(events_of(instance, :timer_fired)) == 1
    end

    test "a redelivered firing arms only one next repetition" do
      defn = publish!(task_xml(~s|<ash:timer kind="remind" cycle="R3/PT1H"/>|))
      instance = start!(defn)
      [rep1] = TestJobs.all()

      assert {:ok, :reminded} = TimerWorker.perform(%Oban.Job{args: rep1.args})
      assert {:ok, :already_fired} = TimerWorker.perform(%Oban.Job{args: rep1.args})

      assert [%{args: %{"repetition" => 2}}] =
               Enum.reject(TestJobs.all(), &(&1.id == rep1.id))

      assert [%{status: :scheduled}] =
               Enum.filter(ledger_for(instance), &(&1.data["repetition"] == 2))
    end

    # Without the row id the firing is still known by its key: its `:timer_fired` is written
    # once per key (DESIGN.md §11.4), so a redelivery finds it and arms nothing.
    test "without its ledger row, a redelivery arms no second next repetition" do
      defn = publish!(task_xml(~s|<ash:timer kind="remind" cycle="R3/PT1H"/>|))
      instance = start!(defn)
      [rep1] = TestJobs.all()
      args = Map.delete(rep1.args, "timer_job_id")

      assert {:ok, :reminded} = TimerWorker.perform(%Oban.Job{args: args})
      assert {:ok, :already_fired} = TimerWorker.perform(%Oban.Job{args: args})

      assert [%{args: %{"repetition" => 2}}] =
               Enum.reject(TestJobs.all(), &(&1.id == rep1.id))

      rep2_rows = Enum.filter(ledger_for(instance), &(&1.data["repetition"] == 2))

      assert Enum.map(rep2_rows, & &1.status) == [:scheduled]
      assert length(events_of(instance, :timer_fired)) == 1
    end

    test "a firing that ran late skips the repetitions it missed, in one event" do
      defn = publish!(task_xml(~s|<ash:timer kind="remind" cycle="R5/PT1H"/>|))
      instance = start!(defn)
      [rep1] = TestJobs.all()

      # As if repetition 1 ran three and a half hours after it was armed.
      anchor = DateTime.add(DateTime.utc_now(), -210, :minute)
      args = put_in(rep1.args, ["cycle", "anchor"], DateTime.to_iso8601(anchor))

      assert {:ok, :reminded} = TimerWorker.perform(%Oban.Job{args: args})

      assert [skipped] = events_of(instance, :timer_skipped)
      assert skipped.data["count"] == 2
      assert skipped.data["reason"] == "past"

      assert [next] = Enum.reject(TestJobs.all(), &(&1.id == rep1.id))
      assert next.args["repetition"] == 4
      assert DateTime.compare(next.scheduled_at, DateTime.add(anchor, 4 * 3600)) == :eq
    end

    test "a cycle whose start is past skips what it missed and arms the next ahead" do
      start = DateTime.add(DateTime.utc_now(), -150, :minute) |> DateTime.truncate(:second)
      cycle = "R5/#{DateTime.to_iso8601(start)}/PT1H"

      defn =
        publish!(task_xml(~s|<ash:timer kind="remind" cycle="= &quot;#{cycle}&quot;"/>|))

      instance = start!(defn)

      # Due at start, +1h, +2h (all past), +3h, +4h: three missed, the fourth armed.
      assert [skipped] = events_of(instance, :timer_skipped)
      assert skipped.data["count"] == 3

      assert [job] = TestJobs.all()
      assert job.args["repetition"] == 4
      assert DateTime.compare(job.scheduled_at, DateTime.add(start, 3 * 3600)) == :eq
    end

    test "a cycle wholly in the past arms nothing and records the skip" do
      defn =
        publish!(
          task_xml(
            ~s|<ash:timer kind="remind" cycle="= &quot;R3/2020-01-01T00:00:00Z/P1D&quot;"/>|
          )
        )

      instance = start!(defn)

      assert TestJobs.all() == []
      assert [skipped] = events_of(instance, :timer_skipped)
      assert skipped.data["count"] == 3
      assert [%{status: :cancelled, cancel_reason: :past}] = ledger_for(instance)
    end

    test "a cycle expression that returns something else is a timer incident" do
      defn = publish!(task_xml(~s|<ash:timer kind="remind" cycle="= &quot;R/PT1H&quot;"/>|))
      instance = start!(defn)

      assert [event] = events_of(instance, :timer_unresolved)
      assert event.data["reason"] =~ "unbounded"
      assert TestJobs.all() == []
      assert tasks_for(instance) == []
    end
  end

  describe "a repeating non-interrupting boundary" do
    test "starts a branch at each repetition, each with its own ledger row and key" do
      defn = publish!(boundary_xml(~s|<bpmn2:timeCycle>R2/PT30M</bpmn2:timeCycle>|, false))
      instance = start!(defn)
      [token] = Enum.filter(tokens_for(instance), &(&1.node_id == "Review"))
      now = DateTime.utc_now()

      assert TestJobs.fire_due!(DateTime.add(now, 31, :minute)) == 1
      assert [rep2] = TestJobs.all()
      assert rep2.args["key"] == "#{token.id}/Review/Boundary/2"

      assert TestJobs.fire_due!(DateTime.add(now, 61, :minute)) == 1
      assert TestJobs.all() == []

      assert Enum.map(events_of(instance, :timer_fired), & &1.data["key"]) ==
               ["#{token.id}/Review/Boundary/1", "#{token.id}/Review/Boundary/2"]

      assert [%{status: :fired}, %{status: :fired}] =
               Enum.filter(ledger_for(instance), &(&1.kind == :boundary))

      # Two branches ran beside the task, which is still open.
      assert [%{status: :open}] = tasks_for(instance)
    end

    test "is cancelled, in Oban and on the ledger, when its activity ends" do
      defn = publish!(boundary_xml(~s|<bpmn2:timeCycle>R3/PT30M</bpmn2:timeCycle>|, false))
      instance = start!(defn)
      [task] = tasks_for(instance)

      {:ok, _} = AshBpmn.complete_task(task, outcome: :approved, actor: reviewer())

      assert TestJobs.all() == []

      assert [%{status: :cancelled, cancel_reason: :task_decided}] =
               Enum.filter(ledger_for(instance), &(&1.kind == :boundary))
    end
  end

  # ── reschedule_timers/2 ─────────────────────────────────────────────────

  describe "reschedule_timers/2" do
    test "a subject with no instances moves nothing" do
      subject = tenant_subject!(Ash.UUID.generate(), DateTime.utc_now())
      assert {:ok, 0} = reschedule(subject)
    end

    test "moves a data-driven timer, keeps its key, and records the move once" do
      tenant = Ash.UUID.generate()
      first = DateTime.add(DateTime.utc_now(), 6, :hour)
      {subject, instance} = tenant_instance!(tenant, first, ~s|date="= subject.notice_at"|)
      [old_job] = TestJobs.all()

      later = DateTime.add(first, 1, :day)
      subject = update_notice!(subject, later, tenant)

      assert {:ok, 1} = reschedule(subject)

      assert [new_job] = TestJobs.all()
      assert new_job.id != old_job.id
      assert new_job.args["key"] == old_job.args["key"]
      assert DateTime.compare(new_job.scheduled_at, later) == :eq

      rows = tenant_ledger(instance, tenant)
      assert [%{cancel_reason: :rescheduled}] = Enum.filter(rows, &(&1.status == :cancelled))
      assert [%{due_at: due_at}] = Enum.filter(rows, &(&1.status == :scheduled))
      assert DateTime.compare(due_at, later) == :eq

      assert [event] = tenant_events(instance, tenant, :timers_rescheduled)
      assert [%{"key" => key, "from" => from, "to" => to}] = event.data["timers"]
      assert key == old_job.args["key"]
      assert from == DateTime.to_iso8601(first)
      assert to == DateTime.to_iso8601(later)

      # Nothing changed since, so a second call moves nothing and records nothing.
      assert {:ok, 0} = reschedule(subject)
      assert [_] = tenant_events(instance, tenant, :timers_rescheduled)
    end

    test "a new instant already past follows ifPast=skip" do
      tenant = Ash.UUID.generate()
      first = DateTime.add(DateTime.utc_now(), 6, :hour)

      {subject, instance} =
        tenant_instance!(tenant, first, ~s|date="= subject.notice_at" ifPast="skip"|)

      subject = update_notice!(subject, DateTime.add(DateTime.utc_now(), -1, :hour), tenant)

      assert {:ok, 1} = reschedule(subject)
      assert TestJobs.all() == []

      assert [%{data: %{"count" => 1, "reason" => "past"}}] =
               tenant_events(instance, tenant, :timer_skipped)

      assert tenant_ledger(instance, tenant)
             |> Enum.map(& &1.cancel_reason)
             |> Enum.sort() == [:past, :rescheduled]
    end

    test "a new instant already past fires at once, marked late, by default" do
      tenant = Ash.UUID.generate()
      first = DateTime.add(DateTime.utc_now(), 6, :hour)
      {subject, _instance} = tenant_instance!(tenant, first, ~s|date="= subject.notice_at"|)

      subject = update_notice!(subject, DateTime.add(DateTime.utc_now(), -1, :hour), tenant)

      assert {:ok, 1} = reschedule(subject)
      assert [job] = TestJobs.all()
      assert job.args["late"] == true
    end

    test "leaves a fired timer and a literal timer alone" do
      tenant = Ash.UUID.generate()
      first = DateTime.add(DateTime.utc_now(), 1, :hour)

      {subject, instance} =
        tenant_instance!(
          tenant,
          first,
          ~s|date="= subject.notice_at"/><ash:timer kind="escalate" hours="48"|
        )

      assert TestJobs.fire_due!(DateTime.add(first, 60)) == 1
      subject = update_notice!(subject, DateTime.add(first, 2, :hour), tenant)

      assert {:ok, 0} = reschedule(subject)

      assert tenant_ledger(instance, tenant)
             |> Enum.map(& &1.status)
             |> Enum.sort() == [:fired, :scheduled]
    end

    test "never touches another tenant's instance" do
      acme = Ash.UUID.generate()
      globex = Ash.UUID.generate()
      first = DateTime.add(DateTime.utc_now(), 6, :hour)

      {acme_subject, _} = tenant_instance!(acme, first, ~s|date="= subject.notice_at"|)

      {_globex_subject, globex_instance} =
        tenant_instance!(globex, first, ~s|date="= subject.notice_at"|)

      globex_jobs = Enum.filter(TestJobs.all(), &(&1.args["tenant"] == globex))

      acme_subject = update_notice!(acme_subject, DateTime.add(first, 1, :day), acme)
      assert {:ok, 1} = reschedule(acme_subject)

      assert Enum.filter(TestJobs.all(), &(&1.args["tenant"] == globex)) == globex_jobs
      assert [%{status: :scheduled}] = tenant_ledger(globex_instance, globex)
      assert tenant_events(globex_instance, globex, :timers_rescheduled) == []
    end

    test "data that no longer resolves moves nothing and returns the incident" do
      tenant = Ash.UUID.generate()
      first = DateTime.add(DateTime.utc_now(), 6, :hour)
      {subject, instance} = tenant_instance!(tenant, first, ~s|date="= subject.notice_at"|)
      [job] = TestJobs.all()

      subject = update_notice!(subject, nil, tenant)

      assert {:error, {:timer_unresolved, %{"node" => "Review", "reason" => reason}}} =
               reschedule(subject)

      assert reason =~ "null"
      assert TestJobs.all() == [job]
      assert [%{status: :scheduled}] = tenant_ledger(instance, tenant)
    end

    test "without the timer ledger it says so rather than moving nothing silently" do
      {:ok, subject} =
        AshBpmn.Test.Subject.create!(%{name: "x", amount: 0, is_privileged: false})

      # The plain test domain installs the ledger; one that has not is told.
      assert {:ok, 0} = AshBpmn.reschedule_timers(subject, domain: AshBpmn.Test.Domain)

      assert {:error, :timer_ledger_not_installed} =
               AshBpmn.reschedule_timers(subject, domain: AshBpmn.ScopedTest.Domain)
    end
  end

  # ── helpers ─────────────────────────────────────────────────────────────

  defp reviewer, do: %{id: Resolver.role_member("reviewer")}

  defp reschedule(subject),
    do: AshBpmn.reschedule_timers(subject, domain: AshBpmn.TenantTest.Domain)

  defp tenant_subject!(tenant, notice_at) do
    AshBpmn.TenantTest.Subject
    |> Ash.Changeset.for_create(:create, %{name: "s", notice_at: notice_at},
      tenant: tenant,
      authorize?: false
    )
    |> Ash.create!()
  end

  defp update_notice!(subject, notice_at, tenant) do
    subject
    |> Ash.Changeset.for_update(:update, %{notice_at: notice_at},
      tenant: tenant,
      authorize?: false
    )
    |> Ash.update!()
  end

  defp tenant_instance!(tenant, notice_at, timer_attrs) do
    key = "cycle_tenant_#{System.unique_integer([:positive])}"
    scope = Scope.engine(%Scope{tenant: tenant})

    xml = task_xml(~s|<ash:timer kind="remind" #{timer_attrs}/>|)
    defn = AshBpmn.TenantTest.Definition.create!(%{key: key, name: key, xml: xml}, scope)
    if is_nil(defn.graph), do: flunk("compile failed: #{inspect(defn.errors)}")
    AshBpmn.TenantTest.Definition.publish!(defn, scope)

    subject = tenant_subject!(tenant, notice_at)

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

  defp task_xml(timers) do
    wrap("""
    <bpmn2:userTask id="Review" name="Review">
      <bpmn2:extensionElements>
        <ash:taskConfig>
          <ash:candidates><ash:candidate kind="role" of="reviewer"/></ash:candidates>
          <ash:outcomes><ash:outcome name="approved"/></ash:outcomes>
          <ash:timers>#{timers}</ash:timers>
        </ash:taskConfig>
      </bpmn2:extensionElements>
      <bpmn2:incoming>F1</bpmn2:incoming>
      <bpmn2:outgoing>F2</bpmn2:outgoing>
    </bpmn2:userTask>
    """)
  end

  defp catch_xml(moment) do
    wrap("""
    <bpmn2:intermediateCatchEvent id="Wait">
      <bpmn2:incoming>F1</bpmn2:incoming>
      <bpmn2:outgoing>F2</bpmn2:outgoing>
      <bpmn2:timerEventDefinition id="T">#{moment}</bpmn2:timerEventDefinition>
    </bpmn2:intermediateCatchEvent>
    """)
  end

  defp boundary_xml(moment, cancel_activity?) do
    wrap(
      """
      <bpmn2:userTask id="Review" name="Review">
        <bpmn2:extensionElements>
          <ash:taskConfig>
            <ash:candidates><ash:candidate kind="role" of="reviewer"/></ash:candidates>
            <ash:outcomes><ash:outcome name="approved"/></ash:outcomes>
          </ash:taskConfig>
        </bpmn2:extensionElements>
        <bpmn2:incoming>F1</bpmn2:incoming>
        <bpmn2:outgoing>F2</bpmn2:outgoing>
      </bpmn2:userTask>
      <bpmn2:boundaryEvent id="Boundary" attachedToRef="Review" cancelActivity="#{cancel_activity?}">
        <bpmn2:outgoing>F3</bpmn2:outgoing>
        <bpmn2:timerEventDefinition id="T">#{moment}</bpmn2:timerEventDefinition>
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

  defp create(xml),
    do:
      Definition.create!(%{key: "tc_#{System.unique_integer([:positive])}", name: "TC", xml: xml})

  defp compile!(xml) do
    defn = create(xml)
    if is_nil(defn.graph), do: flunk("compile failed: #{inspect(defn.errors)}")
    defn.graph
  end

  defp errors_for(xml) do
    defn = create(xml)
    refute defn.graph, "expected compile errors, the definition compiled"
    Enum.map_join(defn.errors, " ", &"[#{&1["path"]}] #{&1["message"]}")
  end

  defp publish!(xml) do
    defn = create(xml)
    if is_nil(defn.graph), do: flunk("compile failed: #{inspect(defn.errors)}")
    Definition.publish!(defn)
  end

  defp start!(defn) do
    {:ok, subject} =
      AshBpmn.Test.Subject.create!(%{name: "cycle", amount: 0, is_privileged: false})

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

  defp tokens_for(instance) do
    Token
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
