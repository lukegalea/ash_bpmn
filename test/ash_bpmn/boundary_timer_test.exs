# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.BoundaryTimerTest do
  @moduledoc """
  Interrupting timer boundary events on user tasks.
  """

  use AshBpmn.DataCase, async: false

  require Ash.Query

  alias AshBpmn.Runtime.Oban.TestJobs
  alias AshBpmn.Test.{Definition, HumanTask, Instance, ProcessEvent, Token}

  setup do
    AshBpmn.Test.Invoker.clear_calls()
    TestJobs.clear()
    :ok
  end

  describe "compiling" do
    test "a boundary is a node carrying its attachment, and is indexed by what it attaches to" do
      defn = compile!("boundary_timer.bpmn")
      boundary = defn.graph["nodes"]["Boundary_1"]

      assert boundary["type"] == "boundaryEvent"
      assert boundary["attached_to"] == "Approve_1"
      assert boundary["catch"]["seconds"] == 4 * 3600

      # A list, because one activity may carry several boundaries.
      assert defn.graph["boundaries"] == %{"Approve_1" => ["Boundary_1"]}
    end

    test "the activity keeps exactly one outgoing flow" do
      # The activity-to-boundary edge must not be written into `flows`. Ordinary completion
      # routes with `fallback: :single_unconditioned`, which matches only when there is one
      # unconditioned flow -- a second one makes it select nothing and raise, so adding the
      # edge would break every completion on a task that has a boundary.
      defn = compile!("boundary_timer.bpmn")

      from_task =
        defn.graph["flows"]
        |> Map.values()
        |> Enum.filter(&(&1["from"] == "Approve_1"))

      assert length(from_task) == 1
    end
  end

  describe "refusing" do
    test "a non-boolean cancelActivity is refused" do
      xml =
        String.replace(
          File.read!("test/fixtures/boundary_non_interrupting.bpmn"),
          ~s(cancelActivity="false"),
          ~s(cancelActivity="perhaps")
        )

      defn =
        Definition.create!(%{
          key: "bt_#{System.unique_integer([:positive])}",
          name: "BT",
          xml: xml
        })

      refute defn.graph
      assert Enum.map_join(defn.errors, " ", & &1["message"]) =~ "non-boolean cancelActivity"
    end

    test "a boundary on a service task is refused, and says what it is supported on" do
      errors = errors_for!("refusal_boundary_on_service_task.bpmn")
      assert errors =~ "serviceTask"
      assert errors =~ "userTask"
    end

    test "a boundary attached to nothing is refused" do
      assert errors_for!("refusal_boundary_dangling.bpmn") =~ "not a node in this process"
    end

    test "a boundary with an incoming flow is refused" do
      assert errors_for!("refusal_boundary_incoming.bpmn") =~ "incoming sequenceFlow"
    end

    test "a task carrying both an expire timer and a boundary is refused" do
      # Both answer "what happens when time runs out" and they route differently -- expire
      # down the task's own flow with outcome :expired, the boundary down its own flow with
      # no outcome. Whichever fired first would win, and neither can be silently preferred.
      errors = errors_for!("refusal_boundary_and_expire.bpmn")
      assert errors =~ "expire"
      assert errors =~ "Keep one"
    end
  end

  describe "non-interrupting" do
    test "the activity keeps running and a second branch starts beside it" do
      # The whole difference. An interrupting boundary cancels the approval; this one leaves
      # somebody's open task exactly where it was and runs the escalation alongside.
      {instance, task} = start!("boundary_non_interrupting.bpmn")

      assert TestJobs.fire_due!(DateTime.add(DateTime.utc_now(), 5 * 3600, :second)) >= 1

      assert reload_task(task).status == :open, "the approval must survive a nudge"
      assert token_for(task).status == :waiting

      # And the escalation ran on its own branch.
      assert invoked?("escalate_it")

      # The instance is still running, because the approval branch has not finished.
      assert reload(instance).status == :running
    end

    test "the new branch records where it came from" do
      {instance, task} = start!("boundary_non_interrupting.bpmn")
      assert TestJobs.fire_due!(DateTime.add(DateTime.utc_now(), 5 * 3600, :second)) >= 1

      spawned =
        Token
        |> Ash.Query.for_read(:read)
        |> Ash.Query.filter(instance_id == ^instance.id and node_id == "Boundary_1")
        |> Ash.read!(authorize?: false)
        |> List.first()

      # There is no join that reunites them and BPMN does not expect one, so the parent link
      # is the only record of the relationship.
      assert spawned.parent_token_id == token_for(task).id
    end

    test "completing the approval afterwards finishes the instance" do
      {instance, task} = start!("boundary_non_interrupting.bpmn")
      assert TestJobs.fire_due!(DateTime.add(DateTime.utc_now(), 5 * 3600, :second)) >= 1

      {:ok, _} =
        AshBpmn.complete_task(reload_task(task),
          outcome: :approved,
          actor: %{id: Ash.UUID.generate()}
        )

      assert reload(instance).status == :completed
    end
  end

  describe "firing" do
    test "the timer is armed when the task is created, not before" do
      {instance, _task} = start!()

      job = boundary_job()
      assert job, "expected a boundary timer to be scheduled"
      assert job.args["boundary_id"] == "Boundary_1"
      assert job.args["attached_to"] == "Approve_1"

      # Tagged so cancel-by-owner can find it when the task is decided.
      assert job.meta["kind"] == "boundary"

      # Not routed anywhere yet, and the approval is still open.
      assert reload(instance).status == :running
      refute invoked?("escalate_it")
    end

    test "firing cancels the task, interrupts the branch, and routes out of the boundary" do
      {instance, task} = start!()

      assert TestJobs.fire_due!(DateTime.add(DateTime.utc_now(), 5 * 3600, :second)) >= 1

      # The task is cancelled, not completed with an invented outcome. `outcome` is what
      # reporting and post-task conditions read, so giving one to a task nobody decided makes
      # an undecided task indistinguishable from a decided one.
      assert reload_task(task).status == :cancelled
      refute reload_task(task).outcome

      assert invoked?("escalate_it")
      assert reload(instance).status == :completed

      kinds = Enum.map(events(instance), & &1.kind)
      assert :activity_interrupted in kinds
      assert :task_cancelled in kinds
    end

    test "a decision beats the deadline" do
      # The ordering that makes this work: the worker cancels the task before it claims the
      # token. `complete_task/2` writes the task first and claims the token after, so there is
      # a window where the task says :completed and the token is still :waiting. A boundary
      # that claimed first would win that window and escalate a request a person had already
      # approved.
      {instance, task} = start!()

      {:ok, _} =
        AshBpmn.complete_task(task, outcome: :approved, actor: %{id: Ash.UUID.generate()})

      assert TestJobs.fire_due!(DateTime.add(DateTime.utc_now(), 5 * 3600, :second)) >= 0

      assert reload_task(task).status == :completed
      assert reload_task(task).outcome == :approved
      refute invoked?("escalate_it")

      refute Enum.any?(events(instance), &(&1.kind == :activity_interrupted))
    end

    test "a decision half-written still beats the deadline" do
      # The previous test passes whichever order the worker uses, because inline mode runs
      # `complete_task/2` synchronously and leaves no window. The window is real in
      # production: `complete_task/2` writes the task first and claims the token after, so
      # between those two statements the task says `:completed` with a `decided_by_id` while
      # its token is still `:waiting`.
      #
      # So the state is built directly here rather than raced for. A worker that claimed the
      # token first would win this and escalate a request a person had already approved; the
      # cancel-first order makes it lose, because `:cancel` will not apply to a completed
      # task.
      {instance, task} = start!()

      HumanTask.claim!(task, %{assignee_type: :user, assignee_id: Ash.UUID.generate()})

      HumanTask.complete!(reload_task(task), %{
        outcome: :approved,
        decided_by_id: Ash.UUID.generate()
      })

      # The token is deliberately left `:waiting` -- that is the window.
      assert token_for(task).status == :waiting

      job = boundary_job()

      assert {:ok, :lost_to_completion} =
               AshBpmn.Runtime.BoundaryTimerWorker.perform(%Oban.Job{args: job.args})

      assert reload_task(task).outcome == :approved
      assert reload_task(task).status == :completed
      refute invoked?("escalate_it")
      refute Enum.any?(events(instance), &(&1.kind == :activity_interrupted))

      # And the token is untouched, so the ordinary completion path can still advance it.
      assert token_for(task).status == :waiting
    end

    test "deciding the task cancels the boundary timer" do
      {instance, task} = start!()
      assert boundary_job()

      {:ok, _} =
        AshBpmn.complete_task(task, outcome: :approved, actor: %{id: Ash.UUID.generate()})

      refute boundary_job(),
             "the boundary timer should be cancelled with the task it was watching"

      _ = instance
    end

    test "a redelivered boundary job interrupts nothing a second time" do
      {instance, _task} = start!()
      job = boundary_job()

      assert TestJobs.fire_due!(DateTime.add(DateTime.utc_now(), 5 * 3600, :second)) >= 1
      before = Enum.count(events(instance), &(&1.kind == :activity_interrupted))

      assert {:ok, reason} =
               AshBpmn.Runtime.BoundaryTimerWorker.perform(%Oban.Job{args: job.args})

      # `:not_live` is the earliest of the three: the token was consumed by the first run, so
      # the redelivery stops before it even looks for the task.
      assert reason in [:lost_to_completion, :not_waiting, :not_live]

      assert Enum.count(events(instance), &(&1.kind == :activity_interrupted)) == before
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp boundary_job do
    Enum.find(TestJobs.all(), &(is_map(&1.args) and &1.args["boundary_id"] == "Boundary_1"))
  end

  defp invoked?(action) do
    Enum.any?(AshBpmn.Test.Invoker.recorded_calls(), fn {_id, a, _ts} -> a == action end)
  end

  defp compile!(fixture) do
    defn = create(fixture)
    if is_nil(defn.graph), do: raise("compile failed: #{inspect(defn.errors)}")
    defn
  end

  defp errors_for!(fixture) do
    defn = create(fixture)
    refute defn.graph, "expected #{fixture} to be refused"
    Enum.map_join(defn.errors, " ", & &1["message"])
  end

  defp create(fixture) do
    xml = File.read!("test/fixtures/#{fixture}")
    Definition.create!(%{key: "bt_#{System.unique_integer([:positive])}", name: "BT", xml: xml})
  end

  defp start!(fixture \\ "boundary_timer.bpmn") do
    defn = compile!(fixture)

    # Through the resource's own `publish` action, not an UPDATE. Raw SQL here would skip
    # `ErrorsEmpty`, which is the validation that stops a definition with compile errors
    # being published -- so a test using SQL could publish something the application never
    # would, and then assert on its behaviour.
    defn = Definition.publish!(defn)

    {:ok, subject} =
      AshBpmn.Test.Subject.create!(%{name: "boundary", amount: 0, is_privileged: false})

    {:ok, instance} =
      AshBpmn.start_instance(AshBpmn.Test.Domain, definition: defn, subject: subject)

    task =
      HumanTask
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(instance_id == ^instance.id)
      |> Ash.read!(authorize?: false)
      |> List.first()

    {instance, task}
  end

  defp token_for(task) do
    AshBpmn.Test.Token
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^task.token_id)
    |> Ash.read_one!(authorize?: false)
  end

  defp reload(instance) do
    Instance
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^instance.id)
    |> Ash.read_one!(authorize?: false)
  end

  defp reload_task(task) do
    HumanTask
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^task.id)
    |> Ash.read_one!(authorize?: false)
  end

  defp events(instance) do
    ProcessEvent
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(instance_id == ^instance.id)
    |> Ash.read!(authorize?: false)
  end
end
