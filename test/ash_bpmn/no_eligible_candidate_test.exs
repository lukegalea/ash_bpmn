# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.NoEligibleCandidateTest do
  @moduledoc """
  A task whose candidates, minus its exclusions, leave nobody.

  Before `no_eligible_candidate/2` such a task was written with no candidate rows and sat open
  for ever, with nothing anywhere saying so. Now a host that implements the callback is asked
  who gets it, the engine subtracts the exclusions from that answer again, and a
  `:no_eligible_candidate` event names the task. A host that does not implement it sees no
  change, which the first test holds.
  """

  use AshBpmn.DataCase, async: false

  require Ash.Query

  alias AshBpmn.ApprovalTestSupport.ApprovalSubject
  alias AshBpmn.Runtime.Oban.TestJobs

  alias AshBpmn.Test.{
    Definition,
    FallbackResolver,
    HumanTask,
    Instance,
    ProcessEvent,
    TaskCandidate
  }

  setup do
    TestJobs.clear()
    AshBpmn.ApprovalTestSupport.ensure_table!()
    FallbackResolver.clear()
    on_exit(&FallbackResolver.clear/0)
    :ok
  end

  describe "a host without the callback" do
    test "sees no change: the task has nobody, and no event is written" do
      {_instance, task, _creator} = start!()

      assert candidate_ids(task) == []
      assert events(task) == []
      assert task.status == :open
    end
  end

  describe "the fallback never reaches an excluded person" do
    test "an excluded person the fallback names is subtracted again" do
      use_fallback_resolver()
      operator = Ash.UUID.generate()
      creator = Ash.UUID.generate()
      FallbackResolver.stage({:ok, [%{type: :user, id: creator}, %{type: :user, id: operator}]})

      {_instance, task, ^creator} = start!(creator)

      assert candidate_ids(task) == [operator]
      assert creator in task.excluded_principal_ids

      assert [event] = events(task)
      assert event.data["escalated"] == true
      assert event.data["fallback"] == 1
      assert event.data["candidates"] == 1
      assert event.data["excluded"] == [creator]
    end

    test "the excluded person cannot claim the escalated task" do
      use_fallback_resolver()
      operator = Ash.UUID.generate()
      FallbackResolver.stage({:ok, [%{type: :user, id: operator}]})

      {_instance, task, creator} = start!()

      assert {:error, _} = AshBpmn.claim_task(task, actor: %{id: creator})
      assert reload(task).status == :open
    end
  end

  describe "a fallback with nobody, or one that fails" do
    test "nobody is recorded as not escalated, and the task still exists" do
      use_fallback_resolver()
      FallbackResolver.stage({:ok, []})

      {_instance, task, _creator} = start!()

      assert candidate_ids(task) == []
      assert [event] = events(task)
      assert event.data["escalated"] == false
      assert event.data["fallback"] == 0
      refute Map.has_key?(event.data, "error")
    end

    test "an error is recorded on the event, and the task is written with nobody" do
      use_fallback_resolver()
      FallbackResolver.stage({:error, :directory_unavailable})

      {_instance, task, _creator} = start!()

      assert task.status == :open
      assert candidate_ids(task) == []
      assert [event] = events(task)
      assert event.data["escalated"] == false
      assert event.data["error"] =~ "directory_unavailable"
    end

    test "a fallback that raises is caught and recorded the same way" do
      use_fallback_resolver()
      FallbackResolver.stage({:__raise__, "operator directory exploded"})

      {_instance, task, _creator} = start!()

      assert candidate_ids(task) == []
      assert [event] = events(task)
      assert event.data["error"] =~ "operator directory exploded"
    end

    test "an undeclared answer is recorded as one" do
      use_fallback_resolver()
      FallbackResolver.stage(:operators)

      {_instance, task, _creator} = start!()

      assert [event] = events(task)
      assert event.data["error"] =~ "undeclared shape"
      assert candidate_ids(task) == []
    end
  end

  describe "a task someone can act on" do
    test "never asks the fallback" do
      use_fallback_resolver()
      FallbackResolver.stage({:ok, [%{type: :user, id: Ash.UUID.generate()}]})

      defn = publish!("boundary_timer.bpmn")
      {:ok, subject} = subject!(Ash.UUID.generate())

      {:ok, instance} =
        AshBpmn.start_instance(AshBpmn.Test.Domain, definition: defn, subject: subject)

      assert FallbackResolver.calls() == []
      assert [task] = tasks(instance)
      assert events(task) == []
    end
  end

  describe "escalated" do
    test "the fallback principal completes the task and the process finishes" do
      use_fallback_resolver()
      operator = Ash.UUID.generate()
      FallbackResolver.stage({:ok, [%{type: :user, id: operator}]})

      {instance, task, _creator} = start!()

      assert [info] = FallbackResolver.calls()
      assert info.node_id == "Review_1"
      assert info.exclusion_specs == [%{"who" => "subject.created_by_id"}]

      assert {:ok, _} = AshBpmn.complete_task(task, outcome: :approved, actor: %{id: operator})
      assert reload_instance(instance).status == :completed
    end

    test "a standalone approval with nobody left is escalated the same way" do
      use_fallback_resolver()
      FallbackResolver.stage_empty_candidates()
      operator = Ash.UUID.generate()
      FallbackResolver.stage({:ok, [%{type: :user, id: operator}]})

      ApprovalSubject.create!(%{
        name: "nobody_#{System.unique_integer([:positive])}",
        created_by_id: Ash.UUID.generate()
      })

      task =
        HumanTask
        |> Ash.Query.filter(status == :open and node_id == "test_approval")
        |> Ash.Query.sort(inserted_at: :desc)
        |> Ash.read!(authorize?: false)
        |> List.first()

      assert candidate_ids(task) == [operator]
      assert [event] = events(task)
      assert event.data["escalated"] == true
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp use_fallback_resolver do
    previous = Application.get_env(:ash_bpmn, :assignment_resolver)
    Application.put_env(:ash_bpmn, :assignment_resolver, FallbackResolver)
    on_exit(fn -> Application.put_env(:ash_bpmn, :assignment_resolver, previous) end)
  end

  defp start!(creator \\ Ash.UUID.generate()) do
    defn = publish!("no_eligible_candidate.bpmn")
    {:ok, subject} = subject!(creator)

    {:ok, instance} =
      AshBpmn.start_instance(AshBpmn.Test.Domain, definition: defn, subject: subject)

    assert [task] = tasks(instance)
    {instance, task, creator}
  end

  defp publish!(fixture) do
    xml = File.read!("test/fixtures/#{fixture}")

    defn =
      Definition.create!(%{
        key: "nec_#{System.unique_integer([:positive])}",
        name: "NEC",
        xml: xml
      })

    if is_nil(defn.graph), do: raise("compile failed: #{inspect(defn.errors)}")
    Definition.publish!(defn)
  end

  defp subject!(creator) do
    AshBpmn.Test.Subject.create!(%{
      name: "no_eligible",
      amount: 0,
      is_privileged: false,
      created_by_id: creator
    })
  end

  defp tasks(instance) do
    HumanTask
    |> Ash.Query.filter(instance_id == ^instance.id)
    |> Ash.read!(authorize?: false)
  end

  defp candidate_ids(task) do
    TaskCandidate
    |> Ash.Query.filter(task_id == ^task.id)
    |> Ash.read!(authorize?: false)
    |> Enum.map(& &1.principal_id)
  end

  defp events(task) do
    ProcessEvent
    |> Ash.Query.filter(task_id == ^task.id and kind == :no_eligible_candidate)
    |> Ash.read!(authorize?: false)
  end

  defp reload(task) do
    HumanTask
    |> Ash.Query.filter(id == ^task.id)
    |> Ash.read_one!(authorize?: false)
  end

  defp reload_instance(instance) do
    Instance
    |> Ash.Query.filter(id == ^instance.id)
    |> Ash.read_one!(authorize?: false)
  end
end
