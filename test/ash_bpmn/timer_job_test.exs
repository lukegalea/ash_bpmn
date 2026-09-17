# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.TimerJobTest do
  @moduledoc """
  The timer ledger.

  These tests are about the two claims the resource makes that nothing else in the system can:
  that a cancelled timer carries a *reason*, and that the record outlives the Oban job it
  names. A test suite that only proved rows could be written would pass against a table nobody
  ever reads, so most of what is asserted here is what happens *after* the job is gone.
  """

  use AshBpmn.DataCase, async: false

  require Ash.Query

  alias AshBpmn.Runtime.Oban.TestJobs
  alias AshBpmn.Test.{Definition, HumanTask, Instance, TimerJob, Token}

  setup do
    TestJobs.clear()
    :ok
  end

  describe "arming" do
    test "a new row records what the timer was for and starts with no verdict" do
      due = DateTime.add(DateTime.utc_now(), 30, :minute)
      task = task!()

      row =
        TimerJob.create!(%{
          instance_id: task.instance_id,
          token_id: task.token_id,
          task_id: task.id,
          node_id: task.node_id,
          kind: :escalate,
          due_at: due,
          oban_job_id: 4242
        })

      assert row.status == :scheduled
      assert row.kind == :escalate
      assert row.task_id == task.id
      assert row.token_id == task.token_id
      assert row.node_id == task.node_id
      assert DateTime.compare(row.due_at, due) == :eq
      assert row.oban_job_id == 4242

      # No verdict yet, and specifically no cancel reason: the field is required at the moment
      # of cancelling, not before.
      refute row.fired_at
      refute row.cancelled_at
      refute row.cancel_reason
    end

    test "a timer intended but never armed is a row with no job id" do
      # The insert-fails case, and it is the reason the row is written before the job rather
      # than after. A nil `oban_job_id` says "this timer was meant to exist and no job carried
      # it", which is a different failure from a timer that was armed and called off -- and the
      # other ordering leaves no trace of it at all.
      row = timer!(%{kind: :expire, oban_job_id: nil})

      assert row.status == :scheduled
      refute row.oban_job_id

      attached = TimerJob.attach_job!(row, 99)
      assert attached.oban_job_id == 99
      assert attached.status == :scheduled
    end

    test "a catch timer has a token and no task" do
      # The shape assertion that stops `task_id` quietly becoming required. A timer catch event
      # is armed against a parked token; there is no human task anywhere near it.
      row = timer!(%{kind: :catch, task_id: nil})

      assert row.kind == :catch
      refute row.task_id
      assert row.token_id
    end
  end

  describe "firing" do
    test "a fired timer records when it actually ran" do
      row = timer!(%{kind: :remind})

      fired = TimerJob.record_fired!(row)

      assert fired.status == :fired
      assert fired.fired_at
      # `due_at` is untouched by firing: the gap between the two is queue lag, and overwriting
      # the due date would erase the only evidence of it.
      assert DateTime.compare(fired.due_at, row.due_at) == :eq
      refute fired.cancel_reason
    end

    test "a redelivered worker cannot fire the same timer twice" do
      # Oban re-runs a worker whose node died mid-job. The second run must find the ledger row
      # already terminal and lose, rather than moving `fired_at` forward to the retry -- which
      # is how a timer that fired four hours late starts looking punctual.
      row = timer!(%{kind: :escalate})

      fired = TimerJob.record_fired!(row)

      assert {:error, error} = TimerJob.record_fired(fired)
      assert Exception.message(error) =~ "already fired"

      reloaded = reload!(row)
      assert DateTime.compare(reloaded.fired_at, fired.fired_at) == :eq
    end

    test "a cancelled timer cannot then be recorded as fired" do
      # The narrow race `AshBpmn.Runtime.Oban.cancel_all/1` cannot close: it cancels only
      # pending jobs, so a timer already executing runs to completion and then finds its row
      # cancelled. The row keeps the verdict the engine decided, and the firing is in the
      # process event log. Letting the fire win would make an audit row's terminal state depend
      # on which of two writers finished last.
      row = timer!(%{kind: :escalate}) |> TimerJob.record_cancelled!(:task_decided)

      assert {:error, error} = TimerJob.record_fired(row)
      assert Exception.message(error) =~ "already cancelled"

      assert reload!(row).cancel_reason == :task_decided
    end
  end

  describe "cancelling" do
    test "a cancellation must say why" do
      # The entire reason this resource exists. Oban's `cancelled` state carries no reason, so
      # a ledger that also allowed a reasonless cancel would reproduce the gap it was built to
      # close.
      row = timer!(%{kind: :escalate})

      assert {:error, error} = TimerJob.record_cancelled(row, nil)
      assert Exception.message(error) =~ "cancel_reason"

      assert reload!(row).status == :scheduled
    end

    test "the reason distinguishes a decided task from a pruned branch" do
      decided = timer!(%{kind: :escalate}) |> TimerJob.record_cancelled!(:task_decided)
      pruned = timer!(%{kind: :expire}) |> TimerJob.record_cancelled!(:token_consumed)

      assert decided.status == :cancelled
      assert decided.cancel_reason == :task_decided
      assert decided.cancelled_at
      refute decided.fired_at

      assert pruned.cancel_reason == :token_consumed
    end

    test "a host cancellation carries its own words in data" do
      row =
        timer!(%{kind: :remind})
        |> TimerJob.record_cancelled!(:host_request, %{
          data: %{"actor_id" => "ops-7", "note" => "escalation muted for the migration"}
        })

      assert row.cancel_reason == :host_request
      assert row.data["note"] == "escalation muted for the migration"
    end

    test "a timer cannot be cancelled twice" do
      row = timer!(%{kind: :expire}) |> TimerJob.record_cancelled!(:task_decided)

      # The second caller loses rather than rewriting the reason. Two different reasons for one
      # cancellation is worse than no reason at all: it is a reason that is wrong.
      assert {:error, _} = TimerJob.record_cancelled(row, :instance_cancelled)
      assert reload!(row).cancel_reason == :task_decided
    end

    test "a fired timer cannot be cancelled afterwards" do
      row = timer!(%{kind: :remind}) |> TimerJob.record_fired!()

      assert {:error, error} = TimerJob.record_cancelled(row, :task_decided)
      assert Exception.message(error) =~ "already fired"
    end
  end

  describe "surviving the Oban job" do
    test "the record answers why a timer never fired after the job is gone" do
      # The whole point, end to end. Oban's pruner deletes cancelled jobs after `max_age`, and
      # a cancelled Oban job never held a reason to begin with -- so this is the state of the
      # world a week after an escalation was called off, and the question is whether anything
      # can still answer "why".
      task = task!()

      {:ok, job} =
        AshBpmn.Runtime.Oban.insert(
          AshBpmn.Runtime.TimerWorker,
          %{"task_id" => task.id, "kind" => "escalate"},
          scheduled_at: DateTime.add(DateTime.utc_now(), 4, :hour)
        )

      row =
        TimerJob.create!(%{
          instance_id: task.instance_id,
          token_id: task.token_id,
          task_id: task.id,
          node_id: task.node_id,
          kind: :escalate,
          due_at: job.scheduled_at,
          oban_job_id: job.id
        })

      assert Enum.any?(TestJobs.all(), &(&1.id == job.id))

      TimerJob.record_cancelled!(row, :task_decided)

      # The job goes away -- cancelled, then pruned. Nothing about the ledger row depends on it.
      :ok = AshBpmn.Runtime.Oban.cancel_job(job.id)
      refute Enum.any?(TestJobs.all(), &(&1.id == job.id))

      survivor = reload!(row)

      assert survivor.status == :cancelled
      assert survivor.cancel_reason == :task_decided
      assert survivor.task_id == task.id
      assert survivor.kind == :escalate
      # Still names the job it was carried by, even though that job no longer exists. That is
      # the ledger's job: `oban_job_id` is a record, not a live reference, and nothing here
      # dereferences it.
      assert survivor.oban_job_id == job.id
      assert DateTime.compare(survivor.due_at, job.scheduled_at) == :eq
    end

    test "the ledger has no destroy action" do
      # An audit record that can be deleted answers no question. Asserted against the resource's
      # own action list rather than by trying a call, so adding a destroy action fails here and
      # not six months later when somebody notices rows are missing.
      types =
        TimerJob
        |> Ash.Resource.Info.actions()
        |> Enum.map(& &1.type)

      refute :destroy in types
    end
  end

  describe "the query the index exists for" do
    test "cancelled timers are found without touching the fired or scheduled ones" do
      # Guards the predicate the partial index is built for. If this query ever stops filtering
      # on `status`, the index silently stops being used and the forensic query degrades to a
      # scan over every timer the system has ever armed -- with no test failing.
      cancelled = timer!(%{kind: :escalate}) |> TimerJob.record_cancelled!(:token_consumed)
      fired = timer!(%{kind: :remind}) |> TimerJob.record_fired!()
      still_waiting = timer!(%{kind: :expire})

      found =
        TimerJob
        |> Ash.Query.for_read(:read)
        |> Ash.Query.filter(status == :cancelled)
        |> Ash.Query.sort(due_at: :asc)
        |> Ash.read!(authorize?: false)
        |> Enum.map(& &1.id)

      assert cancelled.id in found
      refute fired.id in found
      refute still_waiting.id in found
    end

    test "a task's whole timer history is reachable from the task id" do
      task = task!()

      for_task = fn kind ->
        TimerJob.create!(%{
          instance_id: task.instance_id,
          token_id: task.token_id,
          task_id: task.id,
          node_id: task.node_id,
          kind: kind,
          due_at: DateTime.add(DateTime.utc_now(), 30, :minute),
          oban_job_id: System.unique_integer([:positive])
        })
      end

      escalate = for_task.(:escalate) |> TimerJob.record_cancelled!(:task_decided)
      remind = for_task.(:remind) |> TimerJob.record_fired!()

      history =
        TimerJob
        |> Ash.Query.for_read(:read)
        |> Ash.Query.filter(task_id == ^task.id)
        |> Ash.read!(authorize?: false)

      # Both verdicts, side by side: the reminder that fired and the escalation that was called
      # off because somebody decided. Neither fact is in `oban_jobs` a week later.
      assert Enum.sort(Enum.map(history, & &1.id)) == Enum.sort([escalate.id, remind.id])
      assert Enum.find(history, &(&1.id == escalate.id)).cancel_reason == :task_decided
      assert Enum.find(history, &(&1.id == remind.id)).status == :fired
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp reload!(row) do
    TimerJob
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^row.id)
    |> Ash.read_one!(authorize?: false)
  end

  defp timer!(overrides), do: TimerJob.create!(timer_attrs(overrides))

  defp timer_attrs(overrides) do
    token = token!()

    %{
      instance_id: token.instance_id,
      token_id: token.id,
      task_id: nil,
      node_id: token.node_id,
      kind: :remind,
      due_at: DateTime.add(DateTime.utc_now(), 30, :minute),
      oban_job_id: System.unique_integer([:positive])
    }
    |> Map.merge(overrides)
  end

  defp task! do
    token = token!()

    HumanTask.create!(%{
      instance_id: token.instance_id,
      token_id: token.id,
      node_id: token.node_id,
      name: "Approve"
    })
  end

  defp token! do
    instance = instance!()

    Token.create!(%{
      node_id: "Node_#{System.unique_integer([:positive])}",
      status: :executing,
      instance_id: instance.id
    })
  end

  defp instance! do
    xml = File.read!("test/fixtures/linear.bpmn")

    defn =
      Definition.create!(%{
        key: "timer_job_#{System.unique_integer([:positive])}",
        name: "T",
        xml: xml
      })

    if is_nil(defn.graph), do: raise("definition failed to compile: #{inspect(defn.errors)}")

    {:ok, subject} =
      AshBpmn.Test.Subject.create!(%{name: "timer", amount: 0, is_privileged: false})

    Instance.create!(%{
      subject_type: "AshBpmn.Test.Subject",
      subject_id: subject.id,
      definition_id: defn.id
    })
  end
end
