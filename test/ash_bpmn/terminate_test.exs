# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.TerminateTest do
  @moduledoc """
  The terminate end event: an end that ends the process rather than the branch.
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
    test "a terminate marker on an end event compiles, and is visible in the snapshot" do
      defn = compile!("terminate.bpmn")

      assert defn.graph["nodes"]["End_terminated"]["terminate"] == true
      assert defn.graph["nodes"]["End_terminated"]["outcome"] == "withdrawn"

      # The ordinary end event on the other branch must not have picked it up. If the flag
      # leaked onto every end event, the first branch to finish would kill the rest and this
      # whole feature would be indistinguishable from a bug.
      refute defn.graph["nodes"]["End_approved"]["terminate"]
    end

    test "a terminate marker on a start event is refused, naming the node" do
      # Refused rather than ignored, for the reason the whole unsupported-child check exists:
      # a marker the engine silently drops means the diagram and the system are about
      # different processes, and the diagram is what people reason from.
      xml = File.read!("test/fixtures/refusal_terminate_on_start.bpmn")
      defn = Definition.create!(%{key: unique_key("bad_terminate"), name: "Bad", xml: xml})

      refute defn.graph
      assert Enum.any?(defn.errors, &(&1["path"] == "Start_1"))

      message = Enum.map_join(defn.errors, " ", & &1["message"])
      assert message =~ "terminateEventDefinition"
      assert message =~ "endEvent"
    end
  end

  describe "running" do
    test "a branch reaching terminate kills the branch parked on an approval" do
      defn = publish!("terminate.bpmn")
      {:ok, instance} = start!(defn)

      instance = reload_instance(instance)
      assert instance.status == :completed
      assert instance.outcome == "withdrawn"

      tokens = tokens_for(instance)

      # Nothing is left waiting. This is the assertion the feature exists for: the approval
      # branch had no job to cancel and no worker to interrupt, so anything that stopped only
      # what was *running* would have left it parked on an instance that had finished.
      assert Enum.all?(tokens, &(&1.status in [:consumed, :dead])),
             "live tokens remain: #{inspect(Enum.map(tokens, &{&1.node_id, &1.status}))}"

      approval_token = Enum.find(tokens, &(&1.node_id == "SlowApproval"))
      assert approval_token.status == :dead

      # The terminating branch itself is consumed: it reached an end, it was not cut off.
      terminating = Enum.find(tokens, &(&1.node_id == "End_terminated"))
      assert terminating.status == :consumed
    end

    test "the termination is recorded once, naming what it took down" do
      defn = publish!("terminate.bpmn")
      {:ok, instance} = start!(defn)

      events = events_for(instance)
      terminated = Enum.filter(events, &(&1.kind == :instance_terminated))

      assert [event] = terminated
      assert event.data["terminated_by_node_id"] == "End_terminated"
      assert event.data["outcome"] == "withdrawn"
      assert event.data["tokens_killed"] == 1
      assert event.data["killed_node_ids"] == ["SlowApproval"]

      # The instance still completes, and still says so. Terminating is how it ended, not a
      # substitute for having ended.
      assert Enum.any?(events, &(&1.kind == :instance_completed))
    end

    test "the open approval task survives as a row, because it is history" do
      # The token is dead; the task is not retracted. Someone was asked to approve something
      # and the request was withdrawn before they answered -- deleting the task would erase
      # that, and "there is no record of ever having asked you" is the wrong answer.
      defn = publish!("terminate.bpmn")
      {:ok, instance} = start!(defn)

      tasks =
        HumanTask
        |> Ash.Query.for_read(:read)
        |> Ash.Query.filter(instance_id == ^instance.id)
        |> Ash.read!(authorize?: false)

      assert [task] = tasks
      assert task.node_id == "SlowApproval"
    end
  end

  describe "an ordinary end event still only ends its own branch" do
    test "the parallel fixture completes without anything being killed" do
      defn = publish!("parallel.bpmn")
      {:ok, instance} = start!(defn)

      events = events_for(instance)
      refute Enum.any?(events, &(&1.kind == :instance_terminated))

      # Deliberately *not* asserting that no token is dead, which is what this test tried
      # first. A parallel join kills the tokens it merges, so `:dead` today means both "cut
      # off" and "merged into a join" -- an overload worth fixing, since a branch that reached
      # its join finished and a branch that was terminated did not, but not by widening this
      # change. The event log is what distinguishes them, and it is what is asserted here.
      assert Enum.any?(events, &(&1.kind == :instance_completed))
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp unique_key(prefix), do: "#{prefix}_#{System.unique_integer([:positive])}"

  defp compile!(fixture) do
    xml = File.read!("test/fixtures/#{fixture}")
    defn = Definition.create!(%{key: unique_key("t"), name: "T", xml: xml})
    if is_nil(defn.graph), do: raise("compile failed: #{inspect(defn.errors)}")
    defn
  end

  defp publish!(fixture) do
    defn = compile!(fixture)

    # Through the resource's own `publish` action, not an UPDATE. Raw SQL here would skip
    # `ErrorsEmpty`, which is the validation that stops a definition with compile errors
    # being published -- so a test using SQL could publish something the application never
    # would, and then assert on its behaviour.
    Definition.publish!(defn)
  end

  defp start!(defn) do
    {:ok, subject} =
      AshBpmn.Test.Subject.create!(%{name: "terminate", amount: 0, is_privileged: false})

    AshBpmn.start_instance(AshBpmn.Test.Domain, definition: defn, subject: subject)
  end

  defp reload_instance(instance) do
    Instance
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^instance.id)
    |> Ash.read_one!(authorize?: false)
  end

  defp tokens_for(instance) do
    Token
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(instance_id == ^instance.id)
    |> Ash.read!(authorize?: false)
  end

  defp events_for(instance) do
    ProcessEvent
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(instance_id == ^instance.id)
    |> Ash.Query.sort(recorded_at: :asc)
    |> Ash.read!(authorize?: false)
  end
end
