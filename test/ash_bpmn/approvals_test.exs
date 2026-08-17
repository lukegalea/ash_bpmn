# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.ApprovalsTest do
  use AshBpmn.DataCase, async: false

  require Ash.Query

  alias AshBpmn.ApprovalTestSupport.ApprovalSubject
  alias AshBpmn.Runtime.Oban.TestJobs
  alias AshBpmn.Test.{HumanTask, ProcessEvent, TaskCandidate}

  setup do
    AshBpmn.Test.Invoker.clear_calls()
    TestJobs.clear()

    # Ensure the approval subject table exists
    AshBpmn.ApprovalTestSupport.ensure_table!()

    :ok
  end

  describe "RequireApproval change" do
    test "creates approval task and candidates on create" do
      creator_id = Ash.UUID.generate()
      manager_id = AshBpmn.Test.Resolver.manager_of(creator_id)

      subject =
        ApprovalSubject.create!(%{
          name: "Test Subject",
          created_by_id: creator_id
        })

      # Should have created a HumanTask
      tasks =
        HumanTask
        |> Ash.Query.for_read(:read)
        |> Ash.Query.filter(node_id == "test_approval")
        |> Ash.Query.filter(subject_id == ^subject.id)
        |> Ash.Query.filter(status in [:open, :claimed])
        |> Ash.read!(authorize?: false)

      assert length(tasks) == 1
      task = hd(tasks)
      assert task.name == "Test Approval"
      assert task.on_complete != nil

      # Should have candidates (manager, minus creator)
      candidates =
        TaskCandidate
        |> Ash.Query.for_read(:read)
        |> Ash.Query.filter(task_id == ^task.id)
        |> Ash.read!(authorize?: false)

      candidate_ids = Enum.map(candidates, & &1.principal_id)
      assert manager_id in candidate_ids

      # Should have timers
      timers = TestJobs.all()
      # escalate + expire
      assert length(timers) >= 2
    end

    test "double-submit constraint" do
      creator_id = Ash.UUID.generate()

      subject =
        ApprovalSubject.create_no_approval!(%{
          name: "First",
          created_by_id: creator_id
        })

      subject = ApprovalSubject.request_change!(subject, %{name: "Change one"})

      # Requesting again while the first approval is still open trips the
      # partial unique index on (subject, node, status in open/claimed).
      assert_raise Ash.Error.Invalid, ~r/approval.*pending/i, fn ->
        ApprovalSubject.request_change!(subject, %{name: "Change two"})
      end

      # …and the rejected request rolled back rather than leaving a second task.
      open_tasks =
        HumanTask
        |> Ash.Query.for_read(:read)
        |> Ash.Query.filter(subject_id == ^subject.id)
        |> Ash.Query.filter(status in [:open, :claimed])
        |> Ash.read!(authorize?: false)

      assert length(open_tasks) == 1
    end

    test "hands the resolver the same spec shape a diagram does" do
      creator_id = Ash.UUID.generate()

      ApprovalSubject.create!(%{name: "Spec shape", created_by_id: creator_id})

      # A host writes one resolver, so both callers must normalize to the
      # string-keyed maps the compiler emits — not the keyword forms the change
      # happens to accept.
      assert [%{"kind" => "manager_of", "of" => "subject.created_by_id"}] =
               AshBpmn.Test.Resolver.last_candidate_specs()

      assert [%{"who" => "subject.created_by_id"}] =
               AshBpmn.Test.Resolver.last_exclusion_specs()
    end

    test "claim by non-candidate raises" do
      creator_id = Ash.UUID.generate()
      _manager_id = AshBpmn.Test.Resolver.manager_of(creator_id)
      non_candidate_id = Ash.UUID.generate()

      ApprovalSubject.create!(%{
        name: "Test",
        created_by_id: creator_id
      })

      task =
        HumanTask
        |> Ash.Query.for_read(:read)
        |> Ash.Query.filter(node_id == "test_approval")
        |> Ash.Query.filter(status == :open)
        |> Ash.read_one!(authorize?: false)

      non_candidate_actor = %{id: non_candidate_id}

      assert_raise ArgumentError, ~r/not a candidate/i, fn ->
        AshBpmn.claim_task!(task, actor: non_candidate_actor)
      end
    end

    test "claim by candidate + decide approved fires on_complete" do
      creator_id = Ash.UUID.generate()
      manager_id = AshBpmn.Test.Resolver.manager_of(creator_id)

      ApprovalSubject.create!(%{
        name: "Test Approve",
        created_by_id: creator_id
      })

      task =
        HumanTask
        |> Ash.Query.for_read(:read)
        |> Ash.Query.filter(node_id == "test_approval")
        |> Ash.Query.filter(status == :open)
        |> Ash.read_one!(authorize?: false)

      manager = %{id: manager_id}

      # Claim
      {:ok, claimed} = AshBpmn.claim_task(task, actor: manager)
      assert claimed.status == :claimed
      assert claimed.assignee_id == manager_id

      # Decide approved
      {:ok, completed} = AshBpmn.decide(claimed, outcome: :approved, actor: manager)
      assert completed.status == :completed
      assert completed.outcome == :approved

      # Verify on_complete action was invoked
      calls = AshBpmn.Test.Invoker.recorded_calls()
      assert Enum.any?(calls, fn {_id, action, _ts} -> action == "handle_approved" end)

      # Verify task_completed event
      events =
        ProcessEvent
        |> Ash.Query.for_read(:read)
        |> Ash.Query.filter(task_id == ^task.id)
        |> Ash.Query.filter(kind == :task_completed)
        |> Ash.read!(authorize?: false)

      refute Enum.empty?(events)
    end

    test "decide rejected does not fire on_complete" do
      creator_id = Ash.UUID.generate()
      manager_id = AshBpmn.Test.Resolver.manager_of(creator_id)

      ApprovalSubject.create!(%{
        name: "Test Reject",
        created_by_id: creator_id
      })

      task =
        HumanTask
        |> Ash.Query.for_read(:read)
        |> Ash.Query.filter(node_id == "test_approval")
        |> Ash.Query.filter(status == :open)
        |> Ash.read_one!(authorize?: false)

      manager = %{id: manager_id}

      {:ok, claimed} = AshBpmn.claim_task(task, actor: manager)
      {:ok, completed} = AshBpmn.decide(claimed, outcome: :rejected, actor: manager)

      assert completed.outcome == :rejected

      # handle_approved should NOT be invoked
      calls = AshBpmn.Test.Invoker.recorded_calls()
      assert not Enum.any?(calls, fn {_id, action, _ts} -> action == "handle_approved" end)
    end

    test "expire timer fires and completes task" do
      creator_id = Ash.UUID.generate()
      _manager_id = AshBpmn.Test.Resolver.manager_of(creator_id)

      ApprovalSubject.create!(%{
        name: "Test Expire",
        created_by_id: creator_id
      })

      task =
        HumanTask
        |> Ash.Query.for_read(:read)
        |> Ash.Query.filter(node_id == "test_approval")
        |> Ash.Query.filter(status == :open)
        |> Ash.read_one!(authorize?: false)

      # Find and fire the expire timer
      expire_job =
        TestJobs.all()
        |> Enum.find(fn j ->
          is_map(j.args) && j.args["kind"] == "expire" && j.args["task_id"] == task.id
        end)

      assert expire_job != nil, "Expected an expire timer to be scheduled"

      TestJobs.fire!("expire", task.id)

      # Task should be force-completed with expired outcome
      {:ok, task} =
        HumanTask
        |> Ash.Query.for_read(:read)
        |> Ash.Query.filter(id == ^task.id)
        |> Ash.read_one!(authorize?: false)
        |> then(&{:ok, &1})

      assert task.status == :completed
      assert task.outcome == :expired

      # on_complete should NOT be invoked for expiry
      calls = AshBpmn.Test.Invoker.recorded_calls()
      assert not Enum.any?(calls, fn {_id, action, _ts} -> action == "handle_approved" end)
    end

    test "escalation timer fires" do
      creator_id = Ash.UUID.generate()
      _manager_id = AshBpmn.Test.Resolver.manager_of(creator_id)

      ApprovalSubject.create!(%{
        name: "Test Escalate",
        created_by_id: creator_id
      })

      task =
        HumanTask
        |> Ash.Query.for_read(:read)
        |> Ash.Query.filter(node_id == "test_approval")
        |> Ash.Query.filter(status == :open)
        |> Ash.read_one!(authorize?: false)

      # Find and fire the escalate timer
      escalate_job =
        TestJobs.all()
        |> Enum.find(fn j ->
          is_map(j.args) && j.args["kind"] == "escalate" && j.args["task_id"] == task.id
        end)

      assert escalate_job != nil, "Expected an escalate timer to be scheduled"

      TestJobs.fire!("escalate", task.id)

      # Task should still be open (escalation doesn't complete it)
      {:ok, task} =
        HumanTask
        |> Ash.Query.for_read(:read)
        |> Ash.Query.filter(id == ^task.id)
        |> Ash.read_one!(authorize?: false)
        |> then(&{:ok, &1})

      assert task.status == :open
    end

    test "delegation records delegated_from" do
      creator_id = Ash.UUID.generate()
      manager_id = AshBpmn.Test.Resolver.manager_of(creator_id)
      delegate_to_id = Ash.UUID.generate()

      ApprovalSubject.create!(%{
        name: "Test Delegate",
        created_by_id: creator_id
      })

      task =
        HumanTask
        |> Ash.Query.for_read(:read)
        |> Ash.Query.filter(node_id == "test_approval")
        |> Ash.Query.filter(status == :open)
        |> Ash.read_one!(authorize?: false)

      manager = %{id: manager_id}

      # Claim by manager
      {:ok, claimed} = AshBpmn.claim_task(task, actor: manager)

      # Delegate to another user
      {:ok, delegated} =
        AshBpmn.delegate_task(claimed,
          to_principal: %{type: :user, id: delegate_to_id},
          actor: manager
        )

      assert delegated.assignee_id == delegate_to_id
      assert delegated.delegated_from_id == manager_id

      # Complete by delegate
      delegate = %{id: delegate_to_id}

      {:ok, completed} = AshBpmn.decide(delegated, outcome: :approved, actor: delegate)
      assert completed.decided_by_id == delegate_to_id
      assert completed.delegated_from_id == manager_id
    end
  end
end
