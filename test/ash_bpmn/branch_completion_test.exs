# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.BranchCompletionTest do
  @moduledoc """
  When an end event ends the branch and when it ends the process.

  These are not the same thing, and treating them as the same meant a parallel fork whose
  branches each had their own end event could not run: the first branch completed the
  instance and the second failed `StatusIsRunning`, retried, and failed again to
  `max_attempts`. The interpreter's comment claimed `complete_instance` was "idempotent about
  that", which is the kind of claim worth testing rather than reading.
  """

  use AshBpmn.DataCase, async: false

  require Ash.Query

  alias AshBpmn.Runtime.Oban.TestJobs
  alias AshBpmn.Test.{Definition, Instance, ProcessEvent, Token}

  setup do
    AshBpmn.Test.Invoker.clear_calls()
    TestJobs.clear()
    :ok
  end

  test "a fork whose branches have their own end events completes" do
    instance = start!("fork_two_ends.bpmn")

    assert reload(instance).status == :completed
    assert invoked?("a")
    assert invoked?("b")
  end

  test "the first branch to finish records a branch completion, not an instance one" do
    # The distinction the log needs: a process with one branch still running has not
    # completed, and a reader seeing `:instance_completed` twice would have no way to tell a
    # finished process from a half-finished one.
    instance = start!("fork_two_ends.bpmn")

    events = events(instance)
    branch = Enum.filter(events, &(&1.kind == :branch_completed))
    completed = Enum.filter(events, &(&1.kind == :instance_completed))

    assert length(branch) == 1
    assert length(completed) == 1
    assert hd(branch).data["branches_remaining"] == 1
  end

  test "a branch parked on an approval keeps the instance running" do
    # `:waiting` counts as live. A branch waiting for a person has not finished, and
    # completing the instance around it would strand the token exactly as cancelling used to.
    instance = start!("fork_wait.bpmn")

    parked =
      Token
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(instance_id == ^instance.id and status == :waiting)
      |> Ash.read!(authorize?: false)

    assert [_] = parked, "the approval branch should still be parked"

    # The other branch reached its end event. The process has not.
    assert reload(instance).status == :running
    assert [_] = Enum.filter(events(instance), &(&1.kind == :branch_completed))
    assert events(instance) |> Enum.filter(&(&1.kind == :instance_completed)) == []
  end

  test "a single-branch process still completes on its one end event" do
    # The control. Nothing about the change should alter the ordinary case, which is the one
    # every other test in this suite exercises.
    instance = start!("linear.bpmn")
    assert reload(instance).status == :completed
    assert events(instance) |> Enum.filter(&(&1.kind == :branch_completed)) == []
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp start!(fixture, _opts \\ []) do
    xml = File.read!("test/fixtures/#{fixture}")

    defn =
      Definition.create!(%{key: "bc_#{System.unique_integer([:positive])}", name: "BC", xml: xml})

    if is_nil(defn.graph), do: raise("compile failed: #{inspect(defn.errors)}")
    defn = Definition.publish!(defn)

    {:ok, subject} =
      AshBpmn.Test.Subject.create!(%{name: "bc", amount: 0, is_privileged: false})

    {:ok, instance} =
      AshBpmn.start_instance(AshBpmn.Test.Domain, definition: defn, subject: subject)

    instance
  end

  defp invoked?(action) do
    Enum.any?(AshBpmn.Test.Invoker.recorded_calls(), fn {_id, a, _ts} -> a == action end)
  end

  defp reload(instance) do
    Instance
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^instance.id)
    |> Ash.read_one!(authorize?: false)
  end

  defp events(instance) do
    ProcessEvent
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(instance_id == ^instance.id)
    |> Ash.read!(authorize?: false)
  end
end
