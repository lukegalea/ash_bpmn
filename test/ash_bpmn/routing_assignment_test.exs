# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.RoutingAssignmentTest do
  @moduledoc """
  A user task's candidates and exclusions can read what the token carries.

  The composition is the one the decision seam already uses for gateways: a business rule task
  promotes its answer, and the next node reads `routing.<name>`. Here the next node is a user
  task, so a decision can name the role that approves and the person who asked, and the
  person who asked is subtracted from the candidates even when they hold that role.
  """

  use AshBpmn.DataCase, async: false

  require Ash.Query

  alias AshBpmn.Runtime.Oban.TestJobs
  alias AshBpmn.Test.{DecisionResolver, Definition, HumanTask, Resolver, TaskCandidate}

  setup do
    TestJobs.clear()
    DecisionResolver.reset()
    previous = Application.get_env(:ash_bpmn, :decision_resolver)
    Application.put_env(:ash_bpmn, :decision_resolver, DecisionResolver)

    on_exit(fn ->
      DecisionResolver.reset()

      if previous,
        do: Application.put_env(:ash_bpmn, :decision_resolver, previous),
        else: Application.delete_env(:ash_bpmn, :decision_resolver)
    end)

    :ok
  end

  test "the role a decision names is who the task goes to" do
    requester = Ash.UUID.generate()
    decide("Senior approver", requester)

    task = start!(created_by_id: requester)

    assert Resolver.role_member("Senior approver") in candidate_ids(task)
  end

  test "a different answer gives the task to a different role, from the same diagram" do
    requester = Ash.UUID.generate()
    decide("Approver", requester)

    task = start!(created_by_id: requester)

    ids = candidate_ids(task)
    assert Resolver.role_member("Approver") in ids
    refute Resolver.role_member("Senior approver") in ids
  end

  test "the person a decision names as the requester is never a candidate" do
    requester = Ash.UUID.generate()
    decide("Approver", requester)

    # The subject names the requester as a candidate too; the exclusion read from the token
    # still subtracts them, and records that it did.
    task = start!(created_by_id: requester)

    refute requester in candidate_ids(task)
    assert requester in task.excluded_principal_ids
  end

  test "the resolver is handed the token's routing" do
    requester = Ash.UUID.generate()
    decide("Approver", requester)

    _task = start!(created_by_id: requester)

    assert [%{"kind" => "role", "of" => "routing.approver_role"} | _] =
             Resolver.last_candidate_specs()
  end

  test "every branch of a parallel fork carries the routing promoted before it" do
    requester = Ash.UUID.generate()
    decide("Approver", requester)

    tasks = start_all!("forked_assignment.bpmn", created_by_id: requester)

    assert Enum.map(tasks, & &1.node_id) |> Enum.sort() == ["Left", "Right"]

    for task <- tasks do
      assert Resolver.role_member("Approver") in candidate_ids(task)
      assert requester in task.excluded_principal_ids
    end
  end

  test "the routing carries on past a completed task" do
    requester = Ash.UUID.generate()
    decide("Approver", requester)

    task = start!(created_by_id: requester)
    approver = Resolver.role_member("Approver")
    AshBpmn.complete_task!(task, outcome: "approved", actor: %{id: approver})

    [after_task] =
      AshBpmn.Test.Token
      |> Ash.Query.filter(instance_id == ^task.instance_id and node_id == "End")
      |> Ash.read!(authorize?: false)

    assert after_task.routing["approver_role"] == "Approver"
    assert after_task.routing["requested_by_id"] == requester
  end

  defp decide(role, requester) do
    DecisionResolver.register("approval.who", fn _inputs ->
      %{outputs: %{"approver_role" => role, "requested_by_id" => requester}}
    end)
  end

  defp start!(attrs) do
    [task] = start_all!("decided_assignment.bpmn", attrs)
    task
  end

  defp start_all!(fixture, attrs) do
    xml = File.read!("test/fixtures/#{fixture}")

    defn =
      Definition.create!(%{
        key: "routing_assignment_#{System.unique_integer([:positive])}",
        name: "Routing assignment",
        xml: xml
      })

    if is_nil(defn.graph), do: raise("compile failed: #{inspect(defn.errors)}")
    defn = Definition.publish!(defn)

    subject =
      case AshBpmn.Test.Subject.create!(%{
             name: "routing_assignment",
             amount: 100,
             is_privileged: false,
             created_by_id: Keyword.fetch!(attrs, :created_by_id)
           }) do
        {:ok, subject} -> subject
        subject -> subject
      end

    {:ok, instance} =
      AshBpmn.start_instance(AshBpmn.Test.Domain, definition: defn, subject: subject)

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
end
