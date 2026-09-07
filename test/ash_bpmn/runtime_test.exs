# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.RuntimeTest do
  use AshBpmn.DataCase, async: false

  require Ash.Query

  alias AshBpmn.Runtime.{Oban, Oban.TestJobs, SweepWorker}
  alias AshBpmn.Test.{Definition, HumanTask, Instance, ProcessEvent, TaskCandidate, Token}

  setup do
    AshBpmn.Test.Invoker.clear_calls()
    TestJobs.clear()
    :ok
  end

  describe "Oban shim — inline mode" do
    test "immediate job executes synchronously" do
      {:ok, job} = Oban.insert(AshBpmn.RuntimeTest.DummyWorker, %{"val" => "hello"}, [])

      assert job.args == %{"val" => "hello"}
      assert is_integer(job.id)
    end

    test "scheduled job stores but does not execute" do
      scheduled_at = DateTime.add(DateTime.utc_now(), 60, :minute)

      {:ok, job} =
        Oban.insert(
          AshBpmn.RuntimeTest.DummyWorker,
          %{"task_id" => "timer_test", "kind" => "expire"},
          scheduled_at: scheduled_at
        )

      assert is_integer(job.id)
      assert job.scheduled_at == scheduled_at

      # Should be in TestJobs storage
      stored = TestJobs.all()
      refute Enum.empty?(stored)
      assert Enum.any?(stored, fn j -> j.args["task_id"] == "timer_test" end)
    end

    test "cancel_job removes from TestJobs" do
      scheduled_at = DateTime.add(DateTime.utc_now(), 60, :minute)

      {:ok, job} =
        Oban.insert(
          AshBpmn.RuntimeTest.DummyWorker,
          %{"task_id" => "to_cancel", "kind" => "expire"},
          scheduled_at: scheduled_at
        )

      refute Enum.empty?(TestJobs.all())

      :ok = Oban.cancel_job(job.id)

      # Should be removed
      assert not Enum.any?(TestJobs.all(), fn j -> j.id == job.id end)
    end

    test "fire! executes a stored timer job" do
      scheduled_at = DateTime.add(DateTime.utc_now(), 60, :minute)

      {:ok, job} =
        Oban.insert(
          AshBpmn.RuntimeTest.DummyWorker,
          %{"task_id" => "fire_me", "kind" => "escalate"},
          scheduled_at: scheduled_at
        )

      TestJobs.fire!("escalate", "fire_me")

      assert not Enum.any?(TestJobs.all(), fn j -> j.id == job.id end)
    end

    test "fire! raises when no matching job found" do
      assert_raise RuntimeError, ~r/no timer job found for/i, fn ->
        TestJobs.fire!("nonexistent_kind", "nonexistent_id")
      end
    end
  end

  describe "sweep worker" do
    test "re-enqueues advance for stuck active tokens" do
      defn = create_published_definition!("sweep_test", File.read!("test/fixtures/linear.bpmn"))

      inst =
        Instance.create!(
          %{
            definition_id: defn.id,
            subject_type: "TestSubject",
            subject_id: Ash.UUID.generate()
          },
          authorize?: false
        )

      # Create a stuck token manually (no advance job enqueued)
      _token =
        Token.create!(
          %{
            instance_id: inst.id,
            node_id: "Service_1",
            status: :active
          },
          authorize?: false
        )

      # Run sweep
      SweepWorker.perform(%{args: %{}, attempt: 1})

      # The sweep should have re-enqueued an advance
      # Since it's inline mode, the advance runs and the token gets claimed+advanced
      # Check events for sweep_recovered
      events =
        ProcessEvent
        |> Ash.Query.for_read(:read)
        |> Ash.Query.filter(instance_id == ^inst.id)
        |> Ash.Query.filter(kind == :sweep_recovered)
        |> Ash.read!(authorize?: false)

      refute Enum.empty?(events)
    end
  end

  describe "my_tasks" do
    test "returns only tasks where principal is a candidate" do
      defn =
        create_published_definition!("my_tasks_test", File.read!("test/fixtures/linear.bpmn"))

      inst =
        Instance.create!(
          %{
            definition_id: defn.id,
            subject_type: "TestSubject",
            subject_id: Ash.UUID.generate()
          },
          authorize?: false
        )

      token =
        Token.create!(
          %{
            instance_id: inst.id,
            node_id: "Start_1",
            status: :active
          },
          authorize?: false
        )

      user1_id = Ash.UUID.generate()
      user2_id = Ash.UUID.generate()

      task1 =
        HumanTask.create!(
          %{
            instance_id: inst.id,
            token_id: token.id,
            node_id: "task_1",
            name: "Task for User1"
          },
          authorize?: false
        )

      task2 =
        HumanTask.create!(
          %{
            instance_id: inst.id,
            token_id: token.id,
            node_id: "task_2",
            name: "Task for User2"
          },
          authorize?: false
        )

      # User1 is candidate for task1, User2 is candidate for task2
      TaskCandidate.create!(%{task_id: task1.id, principal_type: :user, principal_id: user1_id},
        authorize?: false
      )

      TaskCandidate.create!(%{task_id: task2.id, principal_type: :user, principal_id: user2_id},
        authorize?: false
      )

      # my_tasks for user1 should only return task1
      tasks = AshBpmn.my_tasks(AshBpmn.Test.Domain, principal_ids: [user1_id])
      task_ids = Enum.map(tasks, & &1.id)

      assert task1.id in task_ids
      assert task2.id not in task_ids
    end

    test "matches any of the given principal ids" do
      defn =
        create_published_definition!(
          "my_tasks_multi_principal",
          File.read!("test/fixtures/linear.bpmn")
        )

      inst =
        Instance.create!(
          %{
            definition_id: defn.id,
            subject_type: "TestSubject",
            subject_id: Ash.UUID.generate()
          },
          authorize?: false
        )

      token =
        Token.create!(
          %{
            instance_id: inst.id,
            node_id: "Start_1",
            status: :active
          },
          authorize?: false
        )

      user_id = Ash.UUID.generate()
      other_id = Ash.UUID.generate()

      task =
        HumanTask.create!(
          %{
            instance_id: inst.id,
            token_id: token.id,
            node_id: "task_1",
            name: "Task for later principal"
          },
          authorize?: false
        )

      TaskCandidate.create!(%{task_id: task.id, principal_type: :user, principal_id: user_id},
        authorize?: false
      )

      tasks =
        AshBpmn.my_tasks(AshBpmn.Test.Domain, principal_ids: [other_id, user_id, other_id])

      assert Enum.map(tasks, & &1.id) == [task.id]
    end

    test "team-type candidates do not match user principal ids" do
      defn =
        create_published_definition!(
          "my_tasks_team_type",
          File.read!("test/fixtures/linear.bpmn")
        )

      inst =
        Instance.create!(
          %{
            definition_id: defn.id,
            subject_type: "TestSubject",
            subject_id: Ash.UUID.generate()
          },
          authorize?: false
        )

      token =
        Token.create!(
          %{
            instance_id: inst.id,
            node_id: "Start_1",
            status: :active
          },
          authorize?: false
        )

      principal_id = Ash.UUID.generate()

      task =
        HumanTask.create!(
          %{
            instance_id: inst.id,
            token_id: token.id,
            node_id: "task_1",
            name: "Task for a team"
          },
          authorize?: false
        )

      # Same id, but the candidate row is a *team*, not a user: my_tasks is
      # the user's work list, and this must not come back.
      TaskCandidate.create!(
        %{task_id: task.id, principal_type: :team, principal_id: principal_id},
        authorize?: false
      )

      assert AshBpmn.my_tasks(AshBpmn.Test.Domain, principal_ids: [principal_id]) == []
    end

    test "includes claimed tasks but excludes decided ones" do
      defn =
        create_published_definition!("my_tasks_statuses", File.read!("test/fixtures/linear.bpmn"))

      inst =
        Instance.create!(
          %{
            definition_id: defn.id,
            subject_type: "TestSubject",
            subject_id: Ash.UUID.generate()
          },
          authorize?: false
        )

      token =
        Token.create!(
          %{
            instance_id: inst.id,
            node_id: "Start_1",
            status: :active
          },
          authorize?: false
        )

      user_id = Ash.UUID.generate()

      open_task =
        HumanTask.create!(
          %{
            instance_id: inst.id,
            token_id: token.id,
            node_id: "task_open",
            name: "Open"
          },
          authorize?: false
        )

      claimed_task =
        HumanTask.create!(
          %{
            instance_id: inst.id,
            token_id: token.id,
            node_id: "task_claimed",
            name: "Claimed",
            status: :claimed,
            assignee_type: :user,
            assignee_id: user_id
          },
          authorize?: false
        )

      done_task =
        HumanTask.create!(
          %{
            instance_id: inst.id,
            token_id: token.id,
            node_id: "task_done",
            name: "Done",
            status: :completed
          },
          authorize?: false
        )

      for task <- [open_task, claimed_task, done_task] do
        TaskCandidate.create!(%{task_id: task.id, principal_type: :user, principal_id: user_id},
          authorize?: false
        )
      end

      task_ids =
        AshBpmn.my_tasks(AshBpmn.Test.Domain, principal_ids: [user_id])
        |> Enum.map(& &1.id)
        |> Enum.sort()

      assert task_ids == Enum.sort([open_task.id, claimed_task.id])
    end
  end

  # Dummy worker for testing the Oban shim
  defmodule DummyWorker do
    @moduledoc false

    def perform(_job), do: :ok
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  defp create_published_definition!(key, xml) do
    defn =
      Definition.create!(%{
        key: key,
        name: "Test #{key}",
        xml: xml
      })

    # Check if it compiled successfully (graph is non-nil)
    if defn.graph do
      # Force-publish it
      AshBpmn.TestRepo.query!(
        "UPDATE bpmn_definitions SET status = 'published' WHERE id = '#{defn.id}'"
      )

      Definition.by_key_version!(defn.key, defn.version)
    else
      raise "Definition #{key} failed to compile: #{inspect(defn.errors)}"
    end
  end
end
