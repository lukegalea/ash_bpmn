# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.TimerLedgerWiringTest do
  @moduledoc """
  The ledger as the engine actually writes it.

  `timer_job_test.exs` exercises the resource directly, which proves the actions are correct
  and proves nothing about whether anything calls them. A ledger nobody writes to is an empty
  table that looks like a system with no timers -- the most convincing possible way to be
  wrong -- so these tests drive the real engine paths and read the rows back.
  """

  use AshBpmn.DataCase, async: false

  require Ash.Query

  alias AshBpmn.Runtime.Oban.TestJobs
  alias AshBpmn.Test.{Definition, HumanTask, Instance, TimerJob}

  setup do
    AshBpmn.Test.Invoker.clear_calls()
    TestJobs.clear()
    :ok
  end

  describe "a user task's timers" do
    test "arming a task writes one scheduled row per timer, with its Oban job id attached" do
      {instance, _task} = start_with_approval!()

      rows = rows_for(instance)

      # access_request.bpmn's SecurityApproval declares remind/escalate/expire.
      assert length(rows) == 3
      assert Enum.sort(Enum.map(rows, & &1.kind)) == [:escalate, :expire, :remind]
      assert Enum.all?(rows, &(&1.status == :scheduled))

      # The job id is what ties the row to the thing Oban is actually holding. Without it the
      # row records an intention rather than a timer.
      assert Enum.all?(rows, &is_integer(&1.oban_job_id)),
             "rows without an oban_job_id: #{inspect(Enum.reject(rows, &is_integer(&1.oban_job_id)))}"

      # due_at is a record of what Oban was told, so it must match the schedule, not the
      # moment the row was written.
      assert Enum.all?(rows, &(DateTime.compare(&1.due_at, DateTime.utc_now()) == :gt))
    end

    test "deciding the task cancels its timers, and says it was decided" do
      # This is the row the whole table exists for. Oban can be told to cancel and cannot be
      # told why, and the Pruner then deletes the job outright -- so a week later "the
      # escalation never fired" and "somebody decided before it was due" are the same absence.
      {instance, task} = start_with_approval!()

      {:ok, _} =
        AshBpmn.complete_task(task, outcome: :approved, actor: %{id: Ash.UUID.generate()})

      rows = rows_for(instance)
      assert Enum.all?(rows, &(&1.status == :cancelled))
      assert Enum.all?(rows, &(&1.cancel_reason == :task_decided))
      assert Enum.all?(rows, & &1.cancelled_at)
    end

    test "a timer that fires is recorded as fired, not left scheduled" do
      {instance, task} = start_with_approval!()

      # Drive the reminder through the real worker rather than calling the action.
      {:ok, :reminded} =
        AshBpmn.Runtime.TimerWorker.perform(%Oban.Job{
          args:
            AshBpmn.Scope.to_job_args(AshBpmn.Scope.system(:timer), %{
              "task_id" => task.id,
              "kind" => "remind"
            })
        })

      rows = rows_for(instance)
      remind = Enum.find(rows, &(&1.kind == :remind))

      assert remind.status == :fired
      assert remind.fired_at

      # The other two are untouched: firing a reminder is not a statement about the
      # escalation clock.
      assert Enum.all?(Enum.reject(rows, &(&1.kind == :remind)), &(&1.status == :scheduled))
    end
  end

  describe "a timer catch event's timer" do
    test "parking writes a :catch row, and waking terminates it" do
      instance = start_timer_catch!()

      assert [row] = rows_for(instance)
      assert row.kind == :catch
      assert row.status == :scheduled
      assert row.token_id
      assert row.node_id == "Wait_1"
      # A catch timer belongs to a token, not to a task. A row claiming otherwise would be
      # unfindable by the wake path, which looks it up by token.
      refute row.task_id

      assert TestJobs.fire_due!(DateTime.add(DateTime.utc_now(), 5 * 3600, :second)) == 1

      assert [fired] = rows_for(instance)
      assert fired.status == :fired
      assert fired.fired_at
    end

    test "a terminated branch leaves no scheduled row behind pretending to be armed" do
      # The wake never happens here -- the token is killed first. The row must not be left
      # saying :scheduled, because a scheduled row is a claim that something is still coming.
      instance = start_timer_catch!()
      [row] = rows_for(instance)

      token =
        AshBpmn.Test.Token
        |> Ash.Query.for_read(:read)
        |> Ash.Query.filter(id == ^row.token_id)
        |> Ash.read_one!(authorize?: false)

      AshBpmn.Test.Token.kill!(token)
      assert TestJobs.fire_due!(DateTime.add(DateTime.utc_now(), 5 * 3600, :second)) == 1

      [after_kill] = rows_for(instance)

      # Documents the gap rather than asserting it away: nothing cancels a catch row when its
      # token is killed directly, because the kill did not come through a path that knows
      # why. Terminate and instance-cancel do have that path and should route through it.
      assert after_kill.status == :scheduled,
             "if this now reads :cancelled, the kill path learned a reason -- update the test"
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp rows_for(instance) do
    TimerJob
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(instance_id == ^instance.id)
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.read!(authorize?: false)
  end

  defp publish!(fixture, key) do
    xml = File.read!("test/fixtures/#{fixture}")
    defn = Definition.create!(%{key: key, name: key, xml: xml})
    if is_nil(defn.graph), do: raise("compile failed: #{inspect(defn.errors)}")

    AshBpmn.TestRepo.query!(
      "UPDATE bpmn_definitions SET status = 'published' WHERE id = '#{defn.id}'"
    )

    Definition.by_key_version!(defn.key, defn.version)
  end

  defp subject!(privileged) do
    {:ok, subject} =
      AshBpmn.Test.Subject.create!(%{
        name: "ledger",
        amount: 0,
        is_privileged: privileged
      })

    subject
  end

  defp start_with_approval! do
    defn = publish!("access_request.bpmn", "ledger_#{System.unique_integer([:positive])}")

    {:ok, instance} =
      AshBpmn.start_instance(AshBpmn.Test.Domain, definition: defn, subject: subject!(true))

    task =
      HumanTask
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(instance_id == ^instance.id)
      |> Ash.read!(authorize?: false)
      |> List.first()

    {instance, task}
  end

  defp start_timer_catch! do
    defn = publish!("timer_catch.bpmn", "ledgertc_#{System.unique_integer([:positive])}")

    {:ok, instance} =
      AshBpmn.start_instance(AshBpmn.Test.Domain, definition: defn, subject: subject!(false))

    instance
  end
end
