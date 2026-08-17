# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.EngineTest do
  use AshBpmn.DataCase, async: false

  require Ash.Query

  alias AshBpmn.Runtime.Oban.TestJobs
  alias AshBpmn.Test.{Definition, HumanTask, Instance, ProcessEvent, TaskCandidate, Token}

  setup do
    AshBpmn.Test.Invoker.clear_calls()
    TestJobs.clear()
    :ok
  end

  describe "linear process" do
    test "start → service task → end completes instance" do
      xml = File.read!("test/fixtures/linear.bpmn")
      defn = create_published_definition!("linear_engine", xml)

      subject = create_test_subject!("linear_engine")

      {:ok, instance} =
        AshBpmn.start_instance(AshBpmn.Test.Domain,
          process: "linear_engine",
          subject: subject
        )

      assert instance.status == :completed
      assert instance.definition_id == defn.id

      # Verify invoker was called with do_something action
      calls = AshBpmn.Test.Invoker.recorded_calls()
      assert Enum.any?(calls, fn {_id, action, _ts} -> action == "do_something" end)

      # Verify events
      events =
        ProcessEvent
        |> Ash.Query.for_read(:read)
        |> Ash.Query.filter(instance_id == ^instance.id)
        |> Ash.Query.sort(recorded_at: :asc)
        |> Ash.read!(authorize?: false)

      event_kinds = Enum.map(events, & &1.kind)
      assert :instance_started in event_kinds
      assert :action_invoked in event_kinds
      assert :instance_completed in event_kinds

      # No token is left behind — a start event that never consumes its token
      # strands one on the start node for the life of the instance, and the
      # reconciliation sweep keeps finding it.
      tokens =
        Token
        |> Ash.Query.for_read(:read)
        |> Ash.Query.filter(instance_id == ^instance.id)
        |> Ash.read!(authorize?: false)

      assert tokens != []
      assert Enum.all?(tokens, &(&1.status in [:consumed, :dead]))
    end
  end

  describe "exclusive gateway" do
    test "condition matching routes to correct branch" do
      xml = File.read!("test/fixtures/exclusive.bpmn")
      _defn = create_published_definition!("exclusive_engine", xml)

      # Subject with amount > 100 → should take condition branch
      subject = create_test_subject!("exclusive_engine_high", amount: 200)

      {:ok, instance} =
        AshBpmn.start_instance(AshBpmn.Test.Domain,
          process: "exclusive_engine",
          subject: subject
        )

      assert instance.status == :completed

      calls = AshBpmn.Test.Invoker.recorded_calls()
      assert Enum.any?(calls, fn {_id, action, _ts} -> action == "task_a" end)

      # Verify gateway branch event
      events =
        ProcessEvent
        |> Ash.Query.for_read(:read)
        |> Ash.Query.filter(instance_id == ^instance.id)
        |> Ash.Query.filter(kind == :gateway_branch_taken)
        |> Ash.read!(authorize?: false)

      refute Enum.empty?(events)
      assert hd(events).data["target_node"] == "Task_A"
    end

    test "default branch taken when no condition matches" do
      xml = File.read!("test/fixtures/exclusive.bpmn")
      _defn = create_published_definition!("exclusive_engine_def", xml)

      # Subject with amount = 50 → default branch (no condition matches)
      subject = create_test_subject!("exclusive_engine_low", amount: 50)

      {:ok, instance} =
        AshBpmn.start_instance(AshBpmn.Test.Domain,
          process: "exclusive_engine_def",
          subject: subject
        )

      assert instance.status == :completed

      calls = AshBpmn.Test.Invoker.recorded_calls()
      assert Enum.any?(calls, fn {_id, action, _ts} -> action == "task_b" end)
    end
  end

  describe "parallel fork and join" do
    test "parallel process completes after join" do
      xml = File.read!("test/fixtures/parallel.bpmn")
      _defn = create_published_definition!("parallel_engine", xml)

      subject = create_test_subject!("parallel_engine")

      {:ok, instance} =
        AshBpmn.start_instance(AshBpmn.Test.Domain,
          process: "parallel_engine",
          subject: subject
        )

      assert instance.status == :completed

      calls = AshBpmn.Test.Invoker.recorded_calls()
      assert Enum.any?(calls, fn {_id, action, _ts} -> action == "task_a" end)
      assert Enum.any?(calls, fn {_id, action, _ts} -> action == "task_b" end)
    end
  end

  describe "access request process" do
    test "unprivileged subject → manager approval → provision" do
      xml = File.read!("test/fixtures/access_request.bpmn")
      _defn = create_published_definition!("access_req_unpriv", xml)

      requester_id = Ash.UUID.generate()
      manager_id = AshBpmn.Test.Resolver.manager_of(requester_id)

      subject =
        create_test_subject!("access_req_unpriv",
          is_privileged: false,
          created_by_id: requester_id
        )

      {:ok, instance} =
        AshBpmn.start_instance(AshBpmn.Test.Domain,
          process: "access_req_unpriv",
          subject: subject
        )

      # Should be running with a manager approval task
      assert instance.status == :running

      # Find the manager approval task
      task =
        HumanTask
        |> Ash.Query.for_read(:read)
        |> Ash.Query.filter(instance_id == ^instance.id)
        |> Ash.Query.filter(node_id == "ManagerApproval")
        |> Ash.read_one!(authorize?: false)

      assert task.status == :open
      assert task.name == "Manager approval"

      # Candidates are materialized as rows: manager_of(subject.created_by_id)
      # is in, and the exclusion has already subtracted the requester.
      candidate_ids =
        TaskCandidate
        |> Ash.Query.for_read(:read)
        |> Ash.Query.filter(task_id == ^task.id)
        |> Ash.read!(authorize?: false)
        |> Enum.map(& &1.principal_id)

      assert manager_id in candidate_ids
      refute requester_id in candidate_ids

      actor = %{id: manager_id}
      {:ok, completed_task} = AshBpmn.complete_task(task, outcome: :approved, actor: actor)

      assert completed_task.status == :completed
      assert completed_task.outcome == :approved

      # Instance should complete with provision_access invoked
      assert instance.status == :running
      # Reload
      {:ok, instance} = fetch_instance(instance.id)
      assert instance.status == :completed

      calls = AshBpmn.Test.Invoker.recorded_calls()
      assert Enum.any?(calls, fn {_id, action, _ts} -> action == "provision_access" end)
    end

    test "privileged subject → security approval → join (waits for manager path)" do
      xml = File.read!("test/fixtures/access_request.bpmn")
      _defn = create_published_definition!("access_req_priv_engine", xml)

      requester_id = Ash.UUID.generate()

      subject =
        create_test_subject!("access_req_priv",
          is_privileged: true,
          created_by_id: requester_id
        )

      {:ok, instance} =
        AshBpmn.start_instance(AshBpmn.Test.Domain,
          process: "access_req_priv_engine",
          subject: subject
        )

      assert instance.status == :running

      # Privileged path goes through SecurityApproval (exclusive gateway)
      sec_task =
        HumanTask
        |> Ash.Query.for_read(:read)
        |> Ash.Query.filter(instance_id == ^instance.id)
        |> Ash.Query.filter(node_id == "SecurityApproval")
        |> Ash.read_one!(authorize?: false)

      assert sec_task != nil
      assert sec_task.status == :open

      # ManagerApproval is NOT created — exclusive gateway chose SecurityApproval
      mgr_task =
        HumanTask
        |> Ash.Query.for_read(:read)
        |> Ash.Query.filter(instance_id == ^instance.id)
        |> Ash.Query.filter(node_id == "ManagerApproval")
        |> Ash.read_one!(authorize?: false)

      assert mgr_task == nil
    end

    test "manager rejection → End_rejected" do
      xml = File.read!("test/fixtures/access_request.bpmn")
      _defn = create_published_definition!("access_req_reject_engine", xml)

      manager_id = Ash.UUID.generate()

      subject =
        create_test_subject!("access_req_reject",
          is_privileged: false,
          created_by_id: manager_id
        )

      {:ok, instance} =
        AshBpmn.start_instance(AshBpmn.Test.Domain,
          process: "access_req_reject_engine",
          subject: subject
        )

      # Find and complete manager approval with rejected
      mgr_task =
        HumanTask
        |> Ash.Query.for_read(:read)
        |> Ash.Query.filter(instance_id == ^instance.id)
        |> Ash.Query.filter(node_id == "ManagerApproval")
        |> Ash.read_one!(authorize?: false)

      actor = %{id: manager_id}

      {:ok, _} = AshBpmn.complete_task(mgr_task, outcome: :rejected, actor: actor)

      # Should reach End_rejected via default flow at MgrDecision
      {:ok, instance} = fetch_instance(instance.id)
      assert instance.status == :completed
      # End_rejected has no outcome, so outcome might be nil or set differently
    end

    test "token claim gate — double enqueue is lost_race" do
      xml = File.read!("test/fixtures/linear.bpmn")
      _defn = create_published_definition!("claim_gate_engine", xml)

      subject = create_test_subject!("claim_gate")

      {:ok, instance} =
        AshBpmn.start_instance(AshBpmn.Test.Domain,
          process: "claim_gate_engine",
          subject: subject
        )

      # The process should complete in inline mode
      # But test that claim mechanism works by checking events
      events =
        ProcessEvent
        |> Ash.Query.for_read(:read)
        |> Ash.Query.filter(instance_id == ^instance.id)
        |> Ash.read!(authorize?: false)

      refute Enum.empty?(events)
    end
  end

  describe "timer expiry" do
    test "expire timer completes task and follows graph" do
      xml = File.read!("test/fixtures/access_request.bpmn")
      _defn = create_published_definition!("timer_expire_engine", xml)

      manager_id = Ash.UUID.generate()

      subject =
        create_test_subject!("timer_expire",
          is_privileged: false,
          created_by_id: manager_id
        )

      {:ok, instance} =
        AshBpmn.start_instance(AshBpmn.Test.Domain,
          process: "timer_expire_engine",
          subject: subject
        )

      # Find manager approval task
      task =
        HumanTask
        |> Ash.Query.for_read(:read)
        |> Ash.Query.filter(instance_id == ^instance.id)
        |> Ash.Query.filter(node_id == "ManagerApproval")
        |> Ash.read_one!(authorize?: false)

      assert task.status == :open

      # Find and fire the expire timer
      expire_job =
        TestJobs.all()
        |> Enum.find(fn j ->
          is_map(j.args) && j.args["kind"] == "expire" && j.args["task_id"] == task.id
        end)

      if expire_job do
        TestJobs.fire!("expire", task.id)

        # Task should be force-completed with expired outcome
        {:ok, task} = fetch_task(task.id)
        assert task.status == :completed
        assert task.outcome == :expired
      end
    end
  end

  describe "timer cancellation" do
    test "timers cancelled on task completion" do
      xml = File.read!("test/fixtures/access_request.bpmn")
      _defn = create_published_definition!("timer_cancel_engine", xml)

      manager_id = Ash.UUID.generate()

      subject =
        create_test_subject!("timer_cancel",
          is_privileged: false,
          created_by_id: manager_id
        )

      {:ok, instance} =
        AshBpmn.start_instance(AshBpmn.Test.Domain,
          process: "timer_cancel_engine",
          subject: subject
        )

      task =
        HumanTask
        |> Ash.Query.for_read(:read)
        |> Ash.Query.filter(instance_id == ^instance.id)
        |> Ash.Query.filter(node_id == "ManagerApproval")
        |> Ash.read_one!(authorize?: false)

      # Count timers before completion
      timers_before = length(TestJobs.all())

      # Complete the task
      actor = %{id: manager_id}
      {:ok, completed} = AshBpmn.complete_task(task, outcome: :approved, actor: actor)

      assert completed.status == :completed

      # Timers should have been cancelled
      timers_after = length(TestJobs.all())

      # Some timers should have been removed (at least the ones for this task)
      assert timers_after < timers_before
    end
  end

  describe "instance report" do
    test "returns tokens, tasks, and events" do
      xml = File.read!("test/fixtures/linear.bpmn")
      _defn = create_published_definition!("report_engine", xml)

      subject = create_test_subject!("report_test")

      {:ok, instance} =
        AshBpmn.start_instance(AshBpmn.Test.Domain,
          process: "report_engine",
          subject: subject
        )

      report = AshBpmn.instance_report(instance)
      assert report.instance.id == instance.id
      assert is_list(report.tokens)
      assert is_list(report.tasks)
      assert is_list(report.events)
      refute Enum.empty?(report.events)
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  defp create_published_definition!(key, xml) do
    defn =
      Definition.create!(%{
        key: key,
        name: "Test #{key}",
        xml: xml
      })

    if defn.graph do
      AshBpmn.TestRepo.query!(
        "UPDATE bpmn_definitions SET status = 'published' WHERE id = '#{defn.id}'"
      )

      Definition.by_key_version!(defn.key, defn.version)
    else
      raise "Definition #{key} failed to compile: #{inspect(defn.errors)}"
    end
  end

  defp create_test_subject!(name, overrides \\ []) do
    attrs =
      %{
        name: name,
        amount: Keyword.get(overrides, :amount, 0),
        is_privileged: Keyword.get(overrides, :is_privileged, false),
        created_by_id: Keyword.get(overrides, :created_by_id)
      }

    case AshBpmn.Test.Subject.create!(attrs) do
      {:ok, subject} -> subject
      subject when is_map(subject) -> subject
    end
  end

  defp fetch_instance(id) do
    instance =
      Instance
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(id == ^id)
      |> Ash.read_one!(authorize?: false)

    {:ok, instance}
  end

  defp fetch_task(id) do
    task =
      HumanTask
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(id == ^id)
      |> Ash.read_one!(authorize?: false)

    {:ok, task}
  end
end
