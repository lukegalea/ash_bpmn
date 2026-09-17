# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.EscalationTest do
  @moduledoc """
  What happens when an escalation timer fires, told apart from what happens when it doesn't.

  The suite already had a test called "escalation timer fires". It passed for months while no
  escalation had ever fired: `escalate/2` is an optional callback, the test resolver did not
  implement it, and the clause-level `rescue _ -> {:ok, :escalated}` turned the resulting
  `UndefinedFunctionError` into success. The test asserted the task was still open, which is
  true precisely when nothing happens.

  So these tests assert on the event log, which is the only place the three outcomes are
  distinguishable.
  """

  use AshBpmn.DataCase, async: false

  require Ash.Query

  alias AshBpmn.ApprovalTestSupport.ApprovalSubject
  alias AshBpmn.Runtime.Oban.TestJobs
  alias AshBpmn.Test.{HumanTask, ProcessEvent, Resolver}

  setup do
    TestJobs.clear()
    AshBpmn.ApprovalTestSupport.ensure_table!()
    Resolver.clear_escalations()
    on_exit(&Resolver.clear_escalations/0)
    :ok
  end

  describe "a handler that succeeds" do
    test "the resolver is called, and the log says a handler ran" do
      task = open_task!()

      assert {:ok, :escalated} = escalate(task)
      assert Resolver.escalations() == [task.id]

      assert [event] = events(task, :timer_fired)
      assert event.data["timer_kind"] == "escalate"
      assert event.data["handler"] == "resolver"

      assert events(task, :escalation_failed) == []
    end
  end

  describe "a host with no escalation handler" do
    test "is a configuration fact, recorded as such, and not an error" do
      # `escalate/2` is an optional callback. A host that declines to implement it has not
      # failed at anything, and the distinction from a handler that blew up is the whole
      # reason this is detected with `function_exported?/3` rather than by rescuing.
      task = open_task!()

      assert {:ok, :no_escalation_handler} =
               escalate(task, resolver: AshBpmn.Test.NoEscalateResolver)

      assert [event] = events(task, :timer_fired)
      assert event.data["handler"] == "none"
      assert events(task, :escalation_failed) == []
    end
  end

  describe "a handler that fails" do
    test "an {:error, _} is recorded as a failure and returned so Oban retries" do
      # Escalation is a notification and never touches task state, so a failure here is
      # survivable -- but survivable is not the same as silent. Returning the error is what
      # gets the notification retried.
      task = open_task!()
      Resolver.set_escalate_result({:error, :smtp_unavailable})

      assert {:error, message} = escalate(task)
      assert message =~ "smtp_unavailable"

      assert [event] = events(task, :escalation_failed)
      assert event.data["error"] =~ "smtp_unavailable"

      # Not :timer_fired. Something that failed to notify anybody did not fire.
      assert events(task, :timer_fired) == []
    end

    test "a handler that raises is caught, named, and not reported as success" do
      task = open_task!()
      Resolver.set_escalate_result({:__raise__, "mailer pool exhausted"})

      assert {:error, message} = escalate(task)
      assert message =~ "mailer pool exhausted"

      assert [event] = events(task, :escalation_failed)
      assert event.data["error"] =~ "mailer pool exhausted"
    end

    test "an undeclared return shape is a failure, not a shrug" do
      # The callback declares `:ok | {:ok, map} | {:error, term}`. Anything else means the
      # host and the engine disagree about the contract, and guessing which way is how a
      # failed escalation becomes a successful one.
      task = open_task!()
      Resolver.set_escalate_result(:sent)

      assert {:error, message} = escalate(task)
      assert message =~ "undeclared shape"
    end
  end

  describe "escalating to a process" do
    test "an escalate timer naming a signal throws it instead of calling the resolver" do
      # The difference between notifying somebody and starting something. A resolver reaches a
      # person through whatever the host wired up; a signal reaches every process listening for
      # that name, and a modeller can draw the second without asking for Elixir.
      task = open_task!()

      assert {:ok, :escalated} = escalate(task, signal: "approval.stalled")

      assert [signal] = Ash.read!(AshBpmn.Test.Signal, authorize?: false)
      assert signal.name == "approval.stalled"
      assert signal.payload["task_id"] == task.id

      # The resolver is not called at all. Doing both would notify a person *and* start a
      # process for the same escalation, which is a choice the modeller has already made.
      assert Resolver.escalations() == []

      assert [event] = events(task, :timer_fired)
      assert event.data["handler"] == "signal"
      assert event.data["signal_name"] == "approval.stalled"
    end

    test "an escalate timer with no signal still calls the resolver" do
      task = open_task!()

      assert {:ok, :escalated} = escalate(task)
      assert Resolver.escalations() == [task.id]
      assert Ash.read!(AshBpmn.Test.Signal, authorize?: false) == []
    end
  end

  describe "the task itself" do
    test "is untouched by every outcome, including failure" do
      task = open_task!()
      Resolver.set_escalate_result({:error, :nope})

      assert {:error, _} = escalate(task)

      assert reload(task).status == :open
      refute reload(task).outcome
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp escalate(task, opts \\ []) do
    previous = Application.get_env(:ash_bpmn, :assignment_resolver)

    if resolver = opts[:resolver] do
      Application.put_env(:ash_bpmn, :assignment_resolver, resolver)
      on_exit(fn -> Application.put_env(:ash_bpmn, :assignment_resolver, previous) end)
    end

    args =
      %{"task_id" => task.id, "kind" => "escalate"}
      |> then(&if(opts[:signal], do: Map.put(&1, "signal", opts[:signal]), else: &1))

    AshBpmn.Runtime.TimerWorker.perform(%Oban.Job{
      args: AshBpmn.Scope.to_job_args(AshBpmn.Scope.system(:timer), args)
    })
  end

  defp open_task! do
    creator_id = Ash.UUID.generate()

    ApprovalSubject.create!(%{
      name: "escalation_#{System.unique_integer([:positive])}",
      created_by_id: creator_id
    })

    HumanTask
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(status == :open)
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.read!(authorize?: false)
    |> List.first()
  end

  defp reload(task) do
    HumanTask
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^task.id)
    |> Ash.read_one!(authorize?: false)
  end

  defp events(task, kind) do
    ProcessEvent
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(task_id == ^task.id and kind == ^kind)
    |> Ash.read!(authorize?: false)
  end
end
