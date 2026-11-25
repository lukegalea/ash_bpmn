# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.TimerRaceTest do
  @moduledoc """
  A timer firing that waits for the instance's lock while something else ends or moves its
  work must find that out once it has the lock (DESIGN.md §11.3, §11.4).

  The interleaving, on real connections: one process takes the instance's lock and, inside
  that transaction, completes the task (or reschedules the timer) without committing. The
  firing starts, reads the task and its ledger row as they were committed (open, scheduled),
  and blocks on the lock. The first process commits; the firing takes the lock and must do
  nothing.

  The sandbox runs a test on one connection, which serialises the race out of existence, so
  this module runs outside it (`Ecto.Adapters.SQL.Sandbox.unboxed_run/2`) and deletes the rows
  it committed. Synchronous, so no sandboxed test runs while those rows exist.
  """
  use ExUnit.Case, async: false

  require Ash.Query

  alias AshBpmn.Runtime.{CatchTimerWorker, Step, TimerWorker}
  alias AshBpmn.Runtime.Oban.TestJobs
  alias AshBpmn.Scope
  alias AshBpmn.Test.{Definition, HumanTask, ProcessEvent, Resolver, TimerJob}
  alias AshBpmn.TestRepo
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    TestJobs.clear()
    on_exit(fn -> TestJobs.clear() end)
    :ok
  end

  test "a reminder that waited while its task was completed reminds nobody" do
    {instance, subject} =
      unboxed(fn -> start!(task_xml(~s|<ash:timer kind="remind" hours="2"/>|)) end)

    on_exit(fn -> unboxed(fn -> delete_instance!(instance, subject) end) end)

    [job] = TestJobs.all()
    [task] = unboxed(fn -> tasks_for(instance) end)
    reviewer = %{id: Resolver.role_member("reviewer")}

    result =
      while_locked(
        instance,
        fn -> {:ok, _} = AshBpmn.complete_task(task, outcome: :approved, actor: reviewer) end,
        fn ->
          TimerWorker.perform(%Oban.Job{id: job.id, args: job.args, attempt: 1, max_attempts: 3})
        end
      )

    assert result == {:ok, :skipped}

    unboxed(fn ->
      assert events_of(instance, :timer_fired) == []
      assert events_of(instance, :notice_delivered) == []
      assert [%{status: :cancelled, cancel_reason: :task_decided}] = ledger_for(instance)
    end)
  end

  test "a catch timer that waited while a reschedule moved it does not wake the token" do
    {instance, subject} =
      unboxed(fn ->
        start!(
          catch_xml(
            ~s|<bpmn2:timeDuration>= duration("PT1H") * subject.amount</bpmn2:timeDuration>|
          ),
          2
        )
      end)

    on_exit(fn -> unboxed(fn -> delete_instance!(instance, subject) end) end)

    [job] = TestJobs.all()

    result =
      while_locked(
        instance,
        fn ->
          moved =
            subject
            |> Ash.Changeset.for_update(:update, %{amount: 5}, authorize?: false)
            |> Ash.update!()

          {:ok, 1} = AshBpmn.reschedule_timers(moved, domain: AshBpmn.Test.Domain)
        end,
        fn -> CatchTimerWorker.perform(%Oban.Job{id: job.id, args: job.args}) end
      )

    assert result == {:ok, :skipped}

    unboxed(fn ->
      assert events_of(instance, :timer_fired) == []
      statuses = ledger_for(instance) |> Enum.map(&{&1.status, &1.cancel_reason}) |> Enum.sort()
      assert statuses == Enum.sort([{:cancelled, :rescheduled}, {:scheduled, nil}])
    end)
  end

  # ── the interleaving ─────────────────────────────────────────────────────

  # Runs `inside` in a transaction holding the instance's lock, starts `firing` in another
  # process once `inside` has run, waits until the firing is blocked on the lock, then commits.
  # Returns what the firing returned.
  defp while_locked(instance, inside, firing) do
    {:ok, resources} = AshBpmn.Resources.for_domain(AshBpmn.Test.Domain)
    scope = Scope.from_record(instance)
    test_pid = self()

    holder =
      Task.async(fn ->
        unboxed(fn ->
          Step.transaction(
            resources,
            fn _locked ->
              inside.()
              send(test_pid, :held)

              receive do
                :commit -> :ok
              end
            end,
            lock: {instance.id, scope}
          )
        end)
      end)

    assert_receive :held, 10_000

    worker = Task.async(fn -> unboxed(firing) end)
    wait_until_blocked()
    send(holder.pid, :commit)

    assert {:ok, :ok} = Task.await(holder, 30_000)
    Task.await(worker, 30_000)
  end

  # Polls Postgres until a backend in this database is waiting on a lock: the firing, blocked
  # on the instance row. A bounded poll, not a fixed sleep: it returns as soon as it is true.
  defp wait_until_blocked(tries \\ 200) do
    %{rows: [[count]]} =
      unboxed(fn ->
        TestRepo.query!(
          "SELECT count(*) FROM pg_stat_activity " <>
            "WHERE datname = current_database() AND wait_event_type = 'Lock'"
        )
      end)

    cond do
      count > 0 -> :ok
      tries == 0 -> flunk("the firing never blocked on the instance lock")
      true -> receive(after: (25 -> wait_until_blocked(tries - 1)))
    end
  end

  # ── fixtures ─────────────────────────────────────────────────────────────

  defp start!(xml, amount \\ 0) do
    defn =
      Definition.create!(%{
        key: "race_#{System.unique_integer([:positive])}",
        name: "Race",
        xml: xml
      })

    if is_nil(defn.graph), do: flunk("compile failed: #{inspect(defn.errors)}")
    defn = Definition.publish!(defn)

    {:ok, subject} =
      AshBpmn.Test.Subject.create!(%{name: "race", amount: amount, is_privileged: false})

    {:ok, instance} =
      AshBpmn.start_instance(AshBpmn.Test.Domain, definition: defn, subject: subject)

    {instance, subject}
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(TestRepo, fun)

  defp delete_instance!(instance, subject) do
    {:ok, id} = Ecto.UUID.dump(instance.id)
    {:ok, subject_id} = Ecto.UUID.dump(subject.id)

    TestRepo.query!(
      "DELETE FROM bpmn_task_candidates WHERE task_id IN " <>
        "(SELECT id FROM bpmn_human_tasks WHERE instance_id = $1)",
      [id]
    )

    for table <- ~w(bpmn_process_events bpmn_timer_jobs bpmn_human_tasks bpmn_signals bpmn_tokens) do
      TestRepo.query!("DELETE FROM #{table} WHERE instance_id = $1", [id])
    end

    {:ok, definition_id} = Ecto.UUID.dump(instance.definition_id)
    TestRepo.query!("DELETE FROM bpmn_instances WHERE id = $1", [id])
    TestRepo.query!("DELETE FROM bpmn_definitions WHERE id = $1", [definition_id])
    TestRepo.query!("DELETE FROM bpmn_test_subjects WHERE id = $1", [subject_id])
  end

  defp tasks_for(instance) do
    HumanTask
    |> Ash.Query.filter(instance_id == ^instance.id)
    |> Ash.read!(authorize?: false)
  end

  defp ledger_for(instance) do
    TimerJob
    |> Ash.Query.filter(instance_id == ^instance.id)
    |> Ash.read!(authorize?: false)
  end

  defp events_of(instance, kind) do
    ProcessEvent
    |> Ash.Query.filter(instance_id == ^instance.id and kind == ^kind)
    |> Ash.read!(authorize?: false)
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

  defp wrap(body) do
    middle = body |> then(&Regex.run(~r/id="(\w+)"/, &1)) |> List.last()

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
end
