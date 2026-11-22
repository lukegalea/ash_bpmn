# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.TimerMomentTest do
  @moduledoc """
  DESIGN.md §11.3 and §11.4: a timer's moment comes from data, resolves to one instant when
  it is armed, and every firing carries a stable key.

  The refusals and the incidents come first. A timer that compiles when it should not, or
  parks without a deadline, is the declared-but-not-plumbed failure §11.1 describes, and the
  happy path proves nothing about it.
  """

  use AshBpmn.DataCase, async: false

  require Ash.Query

  alias AshBpmn.Runtime.Oban.TestJobs
  alias AshBpmn.Scope
  alias AshBpmn.Test.{Definition, HumanTask, Instance, ProcessEvent, Resolver, TimerJob, Token}

  setup do
    AshBpmn.Test.Invoker.clear_calls()
    TestJobs.clear()
    :ok
  end

  # ── compile-time refusals ───────────────────────────────────────────────

  describe "a malformed ash:timer is refused, naming the node" do
    for {attrs, expected} <- [
          {~s|hours="2"|, "no kind"},
          {~s|kind="nag" hours="2"|, "not one of remind, escalate, expire"},
          {~s|kind="remind"|, "no moment"},
          {~s|kind="remind" hours="2" days="1"|, "more than one moment"},
          {~s|kind="remind" hours="2.5"|, "whole number greater than zero"},
          {~s|kind="remind" minutes="0"|, "whole number greater than zero"},
          {~s|kind="remind" days="-1"|, "whole number greater than zero"},
          {~s|kind="remind" hours="2" ifPast="later"|, "ifPast"},
          {~s|kind="remind" hours="2" until="started"|, "until"},
          {~s|kind="expire" date="= now()" ifPast="skip"|, "skipping"},
          {~s|kind="expire" hours="2" until="claimed"|, "completion deadline"},
          {~s|kind="remind" hours="2" signal="nudge"|, "only an escalate timer throws a signal"},
          {~s|kind="remind" hours="2" howers="3"|, "unknown attribute"},
          {~s|kind="remind" date="2026-12-01T00:00:00Z"|, "write it as an expression"},
          {~s|kind="remind" duration="P1M"|, "months and years"},
          {~s|kind="remind" duration="PT0S"|, "positive amount"},
          {~s|kind="remind" duration="= | <> ~s|&lt;&lt;"|, ~s|duration="= <<"|}
        ] do
      test "#{attrs}" do
        errors = errors_for(task_xml(~s|<ash:timer #{unquote(attrs)}/>|))

        assert errors =~ unquote(expected),
               "expected #{inspect(unquote(expected))} in: #{errors}"

        assert errors =~ "Review"
      end
    end

    test "the original forms compile to exactly the shape they always did" do
      # A republished diagram that changed nothing must compile to the graph it compiled to
      # before: `AshBpmn.Diff` and the migration classifier compare graphs.
      graph =
        compile!(
          task_xml("""
          <ash:timer kind="remind" hours="2"/>
          <ash:timer kind="escalate" minutes="90" signal="stalled"/>
          <ash:timer kind="expire" days="3"/>
          """)
        )

      assert graph["nodes"]["Review"]["timers"] == [
               %{"kind" => "remind", "minutes" => 120},
               %{"kind" => "escalate", "minutes" => 90, "signal" => "stalled"},
               %{"kind" => "expire", "minutes" => 4320}
             ]
    end

    test "an expression is compiled at publish and stored as text" do
      graph =
        compile!(
          task_xml(~s|<ash:timer kind="remind" date="= subject.notice_at" ifPast="skip"/>|)
        )

      assert [timer] = graph["nodes"]["Review"]["timers"]
      assert timer["kind"] == "remind"
      assert timer["if_past"] == "skip"

      assert timer["moment"] == %{
               "form" => "date",
               "expr" => %{"language" => "feel", "text" => "subject.notice_at"}
             }
    end
  end

  describe "a timerEventDefinition" do
    test "a literal timeDate is still refused, and says to write an expression" do
      errors =
        errors_for(catch_xml(~s|<bpmn2:timeDate>2026-12-01T00:00:00Z</bpmn2:timeDate>|))

      assert errors =~ "write it as an expression"
    end

    test "timeCycle on a catch event is refused by name" do
      errors = errors_for(catch_xml(~s|<bpmn2:timeCycle>R3/PT1H</bpmn2:timeCycle>|))
      assert errors =~ "timeCycle"
      assert errors =~ "non-interrupting boundary"
    end

    test "two moments are refused, because BPMN makes them exclusive" do
      errors =
        errors_for(
          catch_xml(
            ~s|<bpmn2:timeDuration>PT1H</bpmn2:timeDuration><bpmn2:timeDate>= now()</bpmn2:timeDate>|
          )
        )

      assert errors =~ "exactly one"
    end

    test "a timeDate expression compiles; a literal timeDuration keeps its old shape" do
      graph = compile!(catch_xml(~s|<bpmn2:timeDate>= now()</bpmn2:timeDate>|))

      assert graph["nodes"]["Wait"]["catch"]["moment"] == %{
               "form" => "date",
               "expr" => %{"language" => "feel", "text" => "now()"}
             }

      graph = compile!(catch_xml(~s|<bpmn2:timeDuration>PT4H</bpmn2:timeDuration>|))

      assert graph["nodes"]["Wait"]["catch"] == %{
               "kind" => "timer",
               "duration" => "PT4H",
               "seconds" => 14_400
             }
    end
  end

  # ── arm-time incidents ──────────────────────────────────────────────────

  describe "a moment that cannot be resolved is a timer incident" do
    for {label, moment} <- [
          {"FEEL null", ~s|date="= null"|},
          {"a date with no time", ~s|date="= date(&quot;2026-01-01&quot;)"|},
          {"a date-time with no offset",
           ~s|date="= date and time(&quot;2026-01-01T00:00:00&quot;)"|},
          {"a negative duration", ~s|duration="= duration(&quot;-PT1H&quot;)"|},
          {"a zero duration", ~s|duration="= duration(&quot;PT0S&quot;)"|},
          {"a years-and-months duration", ~s|duration="= duration(&quot;P1M&quot;)"|},
          {"a string where a date is required", ~s|date="= &quot;tomorrow&quot;"|}
        ] do
      test "#{label}: the instance fails at the node, no task, nothing armed" do
        defn = publish!(task_xml(~s|<ash:timer kind="remind" #{unquote(moment)}/>|))
        instance = start!(defn)

        assert_incident(instance, "Review", 0)

        # Nothing parks without its deadline.
        assert tasks_for(instance) == []
        assert TestJobs.all() == []
      end
    end

    test "a catch event whose timeDate is null parks nothing" do
      defn = publish!(catch_xml(~s|<bpmn2:timeDate>= null</bpmn2:timeDate>|))
      instance = start!(defn)

      assert_incident(instance, "Wait", 0)
      refute Enum.any?(tokens_for(instance), &(&1.status == :waiting))
      assert TestJobs.all() == []
    end

    test "a boundary whose moment is null fails the activity it is attached to" do
      defn =
        publish!(boundary_xml(~s|<bpmn2:timeDate>= null</bpmn2:timeDate>|, cancel_activity: true))

      instance = start!(defn)

      assert_incident(instance, "Boundary", "Boundary")
      assert tasks_for(instance) == []
    end

    test "the incident is not retried, and retry_instance asks again" do
      defn = publish!(task_xml(~s|<ash:timer kind="remind" date="= null"/>|))
      instance = start!(defn)

      # One attempt, one event: the same data gives the same answer, so the engine does not
      # spend its retry budget asking again.
      assert [_] = events_of(instance, :timer_unresolved)
      [token] = Enum.filter(tokens_for(instance), &(&1.node_id == "Review"))
      assert token.status == :dead
      assert token.attempts == 1

      # The token the incident names is the one a retry brings back; with the data unchanged
      # it fails the same way, with a second event.
      {:ok, _} = AshBpmn.retry_instance(reload(instance))
      assert length(events_of(instance, :timer_unresolved)) == 2
    end

    test "an expression cannot read a path its node did not declare in ash:load" do
      # `doubled_amount` is a calculation: not loaded unless declared, so undeclared it is a
      # missing path, null, and an incident -- never a deadline computed from a guess.
      moment = ~s|date="= now() + duration(&quot;PT1H&quot;) * subject.doubled_amount"|

      undeclared = publish!(task_xml(~s|<ash:timer kind="remind" #{moment}/>|))
      instance = start!(undeclared, amount: 1)
      assert_incident(instance, "Review", 0)

      declared =
        publish!(task_xml(~s|<ash:timer kind="remind" #{moment}/>|, load: ["doubled_amount"]))

      instance = start!(declared, amount: 1)
      assert [%{status: :open}] = tasks_for(instance)
      assert [job] = TestJobs.all()
      assert_in_delta DateTime.diff(job.scheduled_at, DateTime.utc_now()), 2 * 3600, 60
    end

    test "the subject is read in the instance's tenant, never another's" do
      acme = Ash.UUID.generate()
      globex = Ash.UUID.generate()
      notice_at = DateTime.add(DateTime.utc_now(), 6, :hour)

      xml = task_xml(~s|<ash:timer kind="remind" date="= subject.notice_at"/>|)
      key = "tenant_timer_#{System.unique_integer([:positive])}"
      publish_tenant!(key, xml, acme)
      publish_tenant!(key, xml, globex)

      subject =
        AshBpmn.TenantTest.Subject
        |> Ash.Changeset.for_create(:create, %{name: "globex's", notice_at: notice_at},
          tenant: globex,
          authorize?: false
        )
        |> Ash.create!()

      # Acme's instance names Globex's row. Read in Acme's tenant it does not exist, so the
      # moment is null and the instance fails rather than arming from another tenant's data.
      {:ok, acme_instance} =
        AshBpmn.start_instance(AshBpmn.TenantTest.Domain,
          process: key,
          subject: subject,
          tenant: acme
        )

      assert acme_instance
             |> tenant_events(acme)
             |> Enum.map(& &1.kind)
             |> Enum.member?(:timer_unresolved)

      assert TestJobs.all() == []

      # In its own tenant the same row arms the timer at its own date.
      {:ok, _} =
        AshBpmn.start_instance(AshBpmn.TenantTest.Domain,
          process: key,
          subject: subject,
          tenant: globex
        )

      assert [job] = TestJobs.all()
      assert DateTime.compare(job.scheduled_at, notice_at) == :eq
    end
  end

  # ── past moments ────────────────────────────────────────────────────────

  describe "a moment already past" do
    @past ~s|date="= date and time(&quot;2020-01-01T00:00:00Z&quot;)"|

    test "fires at once, exactly once, and says it was late" do
      defn = publish!(task_xml(~s|<ash:timer kind="remind" #{@past}/>|))
      instance = start!(defn)
      [task] = tasks_for(instance)

      assert TestJobs.fire_due!() == 1
      assert TestJobs.fire_due!() == 0

      assert [event] = events_of(instance, :timer_fired)
      assert event.data["late"] == true
      assert event.data["due_at"] =~ "2020-01-01T00:00:00"
      assert event.data["key"] == "#{task.id}/Review/0/1"
    end

    test ~s|ifPast="skip" records the skip, arms nothing and delivers nothing| do
      defn = publish!(task_xml(~s|<ash:timer kind="remind" #{@past} ifPast="skip"/>|))
      instance = start!(defn)
      [task] = tasks_for(instance)

      assert TestJobs.all() == []

      assert [skipped] = events_of(instance, :timer_skipped)
      assert skipped.data["reason"] == "past"
      assert skipped.data["key"] == "#{task.id}/Review/0/1"

      assert [row] = ledger_for(instance)
      assert row.status == :cancelled
      assert row.cancel_reason == :past

      assert TestJobs.fire_due!(DateTime.add(DateTime.utc_now(), 365, :day)) == 0
      assert events_of(instance, :timer_fired) == []
    end

    test "calendar months are allowed inside a date expression and resolve to an instant" do
      # Refused in a duration literal (its length is not fixed), allowed in date arithmetic,
      # which FEEL defines: 31 March minus a month is the end of February.
      moment =
        ~s|date="= date and time(&quot;2026-03-31T10:00:00Z&quot;) - duration(&quot;P1M&quot;)"|

      defn = publish!(task_xml(~s|<ash:timer kind="remind" #{moment}/>|))
      start!(defn)

      assert [job] = TestJobs.all()
      assert job.scheduled_at == ~U[2026-02-28 10:00:00.000000Z]
      assert job.args["late"] == true
    end

    test "a reminder can be written relative to the task's due date" do
      defn =
        publish!(
          task_xml("""
          <ash:timer kind="remind" date="= task.due_at - duration(&quot;P2D&quot;)"/>
          </ash:timers><ash:schedule due="P10D"/><ash:timers>
          """)
        )

      start!(defn)

      assert [job] = TestJobs.all()
      assert_in_delta DateTime.diff(job.scheduled_at, DateTime.utc_now()), 8 * 86_400, 60
    end

    test "a future moment with ifPast=skip arms as usual" do
      future = ~s|date="= now() + duration(&quot;PT3H&quot;)"|
      defn = publish!(task_xml(~s|<ash:timer kind="remind" #{future} ifPast="skip"/>|))
      instance = start!(defn)

      assert [job] = TestJobs.all()
      assert_in_delta DateTime.diff(job.scheduled_at, DateTime.utc_now()), 3 * 3600, 60
      refute job.args["late"]
      assert events_of(instance, :timer_skipped) == []
    end
  end

  # ── what a firing guarantees ────────────────────────────────────────────

  describe "a fired timer" do
    test "carries a stable key that is the same on a redelivery" do
      defn = publish!(task_xml(~s|<ash:timer kind="remind" hours="2"/>|))
      instance = start!(defn)
      [task] = tasks_for(instance)
      [job] = TestJobs.all()

      key = "#{task.id}/Review/0/1"
      assert job.args["key"] == key
      assert job.args["timer_job_id"]

      {:ok, :reminded} = AshBpmn.Runtime.TimerWorker.perform(%Oban.Job{args: job.args})

      # A reminder's event and its ledger row commit together, so with the ledger installed a
      # redelivery after a finished delivery does nothing. Without it delivery is at least
      # once, and readers count distinct keys.
      {:ok, :already_fired} = AshBpmn.Runtime.TimerWorker.perform(%Oban.Job{args: job.args})

      assert [key] == Enum.map(events_of(instance, :timer_fired), & &1.data["key"])
      assert [%{status: :fired}] = ledger_for(instance)
    end

    test "two timers of the same kind each record their own ledger row" do
      defn =
        publish!(
          task_xml("""
          <ash:timer kind="remind" hours="1"/>
          <ash:timer kind="remind" hours="2"/>
          """)
        )

      instance = start!(defn)
      assert TestJobs.fire_due!(DateTime.add(DateTime.utc_now(), 90, :minute)) == 1

      assert [:fired, :scheduled] ==
               instance |> ledger_for() |> Enum.sort_by(& &1.due_at) |> Enum.map(& &1.status)
    end

    test "a completed task fires nothing" do
      defn = publish!(task_xml(~s|<ash:timer kind="remind" hours="2"/>|))
      instance = start!(defn)
      [task] = tasks_for(instance)
      [job] = TestJobs.all()

      {:ok, _} = AshBpmn.complete_task(task, outcome: :approved, actor: reviewer())

      assert {:ok, :skipped} = AshBpmn.Runtime.TimerWorker.perform(%Oban.Job{args: job.args})
      assert events_of(instance, :timer_fired) == []
    end

    test "a cancelled task fires nothing" do
      defn = publish!(task_xml(~s|<ash:timer kind="escalate" hours="2"/>|))
      instance = start!(defn)
      [job] = TestJobs.all()

      {:ok, _} = AshBpmn.cancel_instance(reload(instance))

      assert {:ok, :skipped} = AshBpmn.Runtime.TimerWorker.perform(%Oban.Job{args: job.args})
      assert events_of(instance, :timer_fired) == []
    end

    test "a catch timer's key names its token and node" do
      defn = publish!(catch_xml(~s|<bpmn2:timeDuration>PT1H</bpmn2:timeDuration>|))
      instance = start!(defn)
      [token] = Enum.filter(tokens_for(instance), &(&1.node_id == "Wait"))

      assert TestJobs.fire_due!(DateTime.add(DateTime.utc_now(), 2, :hour)) == 1
      assert [event] = events_of(instance, :timer_fired)
      assert event.data["key"] == "#{token.id}/Wait/0/1"
    end

    test "a boundary timer's key names the token, the activity and the boundary" do
      defn =
        publish!(
          boundary_xml(~s|<bpmn2:timeDuration>PT1H</bpmn2:timeDuration>|, cancel_activity: true)
        )

      instance = start!(defn)
      [token] = Enum.filter(tokens_for(instance), &(&1.node_id == "Review"))

      assert TestJobs.fire_due!(DateTime.add(DateTime.utc_now(), 2, :hour)) == 1
      assert [event] = events_of(instance, :timer_fired)
      assert event.data["key"] == "#{token.id}/Review/Boundary/1"
      assert event.data["timer_kind"] == "boundary"
    end

    test "a snapshot that predates moments still arms from its minutes" do
      # Published snapshots are immutable and keep running: a timer stored as minutes, with no
      # moment and no index, arms exactly as it did, and gains a key.
      defn = publish!(task_xml(~s|<ash:timer kind="remind" hours="2"/>|))
      refute Map.has_key?(hd(defn.graph["nodes"]["Review"]["timers"]), "moment")

      instance = start!(defn)
      [job] = TestJobs.all()
      assert_in_delta DateTime.diff(job.scheduled_at, DateTime.utc_now()), 2 * 3600, 60
      assert [%{status: :scheduled}] = ledger_for(instance)
    end
  end

  describe ~s|until="claimed"| do
    test "a start deadline is cancelled on claim; a completion deadline survives it" do
      defn =
        publish!(
          task_xml("""
          <ash:timer kind="escalate" minutes="15" until="claimed"/>
          <ash:timer kind="remind" hours="4"/>
          """)
        )

      instance = start!(defn)
      [task] = tasks_for(instance)
      assert length(TestJobs.all()) == 2

      {:ok, _claimed} = AshBpmn.claim_task(task, actor: reviewer())

      # The completion deadline survives the claim; the start deadline does not.
      assert [remaining] = TestJobs.all()
      assert remaining.args["kind"] == "remind"

      rows = instance |> ledger_for() |> Map.new(&{&1.kind, &1})
      assert rows[:escalate].status == :cancelled
      assert rows[:escalate].cancel_reason == :claimed
      assert rows[:remind].status == :scheduled
    end

    test "a start-deadline job that escaped the cancel fires nothing on a claimed task" do
      defn = publish!(task_xml(~s|<ash:timer kind="escalate" minutes="15" until="claimed"/>|))
      instance = start!(defn)
      [task] = tasks_for(instance)
      [job] = TestJobs.all()

      {:ok, _} = AshBpmn.claim_task(task, actor: reviewer())

      assert {:ok, :skipped} = AshBpmn.Runtime.TimerWorker.perform(%Oban.Job{args: job.args})
      assert events_of(instance, :timer_fired) == []
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp assert_incident(instance, node_id, timer) do
    instance = reload(instance)
    assert instance.status == :failed

    assert [event] = events_of(instance, :timer_unresolved)
    assert event.data["node"] == node_id
    assert event.data["timer"] == timer
    assert is_binary(event.data["reason"]) and event.data["reason"] != ""

    # The give-up beside it says why, as every incident's does (the schedule's included), so a
    # reader counting failed instances by `:action_failed` sees this one too.
    assert [failed] = events_of(instance, :action_failed)
    assert failed.data["reason"] == "timer_unresolved"
    assert failed.data["attempts"] == 1
  end

  defp reviewer, do: %{id: Resolver.role_member("reviewer")}

  defp task_xml(timers, opts \\ []) do
    load = load_xml(opts[:load])

    wrap("""
    <bpmn2:userTask id="Review" name="Review">
      <bpmn2:extensionElements>
        #{load}
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

  defp boundary_xml(moment, opts) do
    cancel = if opts[:cancel_activity], do: "true", else: "false"

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
      <bpmn2:boundaryEvent id="Boundary" attachedToRef="Review" cancelActivity="#{cancel}">
        <bpmn2:outgoing>F3</bpmn2:outgoing>
        <bpmn2:timerEventDefinition id="T">#{moment}</bpmn2:timerEventDefinition>
      </bpmn2:boundaryEvent>
      <bpmn2:endEvent id="Late"><bpmn2:incoming>F3</bpmn2:incoming></bpmn2:endEvent>
      <bpmn2:sequenceFlow id="F3" sourceRef="Boundary" targetRef="Late"/>
      """,
      "Review"
    )
  end

  defp load_xml(nil), do: ""

  defp load_xml(paths) do
    "<ash:load>" <> Enum.map_join(paths, "", &~s|<ash:path name="#{&1}"/>|) <> "</ash:load>"
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
      Definition.create!(%{key: "tm_#{System.unique_integer([:positive])}", name: "TM", xml: xml})

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

  defp publish_tenant!(key, xml, tenant) do
    scope = Scope.engine(%Scope{tenant: tenant})
    defn = AshBpmn.TenantTest.Definition.create!(%{key: key, name: key, xml: xml}, scope)
    if is_nil(defn.graph), do: flunk("compile failed: #{inspect(defn.errors)}")
    AshBpmn.TenantTest.Definition.publish!(defn, scope)
  end

  defp tenant_events(instance, tenant) do
    AshBpmn.TenantTest.ProcessEvent
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(instance_id == ^instance.id)
    |> Ash.read!(Scope.engine(%Scope{tenant: tenant}))
  end

  defp start!(defn, attrs \\ []) do
    {:ok, subject} =
      AshBpmn.Test.Subject.create!(%{
        name: "timer",
        amount: Keyword.get(attrs, :amount, 0),
        is_privileged: false
      })

    {:ok, instance} =
      AshBpmn.start_instance(AshBpmn.Test.Domain, definition: defn, subject: subject)

    instance
  end

  defp reload(instance) do
    Instance
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^instance.id)
    |> Ash.read_one!(authorize?: false)
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
