# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.ClaimRaceTest do
  @moduledoc """
  Concurrent claims on one task, on separate connections: exactly one wins.

  The sandbox runs a test on one connection, which serialises a race out of existence, so
  this module runs outside it (`Ecto.Adapters.SQL.Sandbox.unboxed_run/2`): every claimer has
  its own connection and its own transaction, and the rows are real commits that the test
  deletes when it is done. Synchronous, so no sandboxed test runs while those rows exist.
  """
  use ExUnit.Case, async: false

  require Ash.Query

  alias AshBpmn.Test.{HumanTask, ProcessEvent, TaskCandidate}
  alias AshBpmn.TestRepo
  alias Ecto.Adapters.SQL.Sandbox

  @claimers 8

  test "of several people claiming one task at once, exactly one wins" do
    actors = for _ <- 1..@claimers, do: %{id: Ash.UUID.generate()}

    task =
      unboxed(fn ->
        task =
          HumanTask.create!(%{
            node_id: "claim_race_#{System.unique_integer([:positive])}",
            name: "Race",
            subject_type: "AshBpmn.Test.Subject",
            subject_id: Ash.UUID.generate()
          })

        for actor <- actors do
          TaskCandidate.create!(%{
            task_id: task.id,
            principal_type: :user,
            principal_id: actor.id
          })
        end

        task
      end)

    on_exit(fn -> unboxed(fn -> delete_task!(task.id) end) end)

    test_pid = self()

    claimers =
      for actor <- actors do
        Task.async(fn ->
          unboxed(fn ->
            send(test_pid, {:ready, self()})

            receive do
              :go -> AshBpmn.claim_task(task, actor: actor)
            end
          end)
        end)
      end

    pids = for _ <- actors, do: receive(do: ({:ready, pid} -> pid))
    Enum.each(pids, &send(&1, :go))

    results = Task.await_many(claimers, 30_000)

    winners = for {{:ok, claimed}, actor} <- Enum.zip(results, actors), do: {claimed, actor}
    assert [{claimed, winner}] = winners, "expected one winner, got #{inspect(results)}"
    assert Enum.count(results, &match?({:error, _}, &1)) == @claimers - 1

    {stored, claim_events} =
      unboxed(fn ->
        {Ash.get!(HumanTask, task.id),
         ProcessEvent
         |> Ash.Query.filter(task_id == ^task.id and kind == :task_claimed)
         |> Ash.read!()}
      end)

    assert claimed.assignee_id == winner.id
    assert stored.assignee_id == winner.id
    assert [event] = claim_events
    assert event.data["assignee_id"] == winner.id
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(TestRepo, fun)

  defp delete_task!(task_id) do
    {:ok, uuid} = Ecto.UUID.dump(task_id)
    TestRepo.query!("DELETE FROM bpmn_process_events WHERE task_id = $1", [uuid])
    TestRepo.query!("DELETE FROM bpmn_task_candidates WHERE task_id = $1", [uuid])
    TestRepo.query!("DELETE FROM bpmn_human_tasks WHERE id = $1", [uuid])
  end
end
