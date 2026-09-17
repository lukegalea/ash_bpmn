# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.ErrorEndTest do
  @moduledoc """
  Error end events: a diagram saying "this ends badly, on purpose".

  That sentence could not be said before. `mark_failed` is reachable from exactly one place --
  retry exhaustion -- and means the engine gave up. An error end event means the opposite: the
  process worked exactly as designed, and the design says no.
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

  test "the errorRef resolves across the process boundary into the snapshot" do
    # The declaration is a sibling of <process>, and the graph builder is handed only the
    # process element -- so resolving this at all required carrying the table across that
    # boundary. Without it the lookup is empty and every such document refuses.
    defn = compile!()
    error = defn.graph["nodes"]["End_declined"]["error"]

    assert error["ref"] == "Error_Declined"
    assert error["code"] == "DECLINED"
    assert error["name"] == "Application declined"
  end

  test "reaching it ends the instance :errored, not :failed" do
    {instance, _} = start!()

    instance = reload(instance)

    # The distinction is the whole feature. `:failed` means page somebody; `:errored` means
    # the answer was no.
    assert instance.status == :errored
    refute instance.status == :failed
    assert instance.outcome == "declined"
  end

  test "it kills the branches still running, like a terminate does" do
    {instance, _} = start!()

    tokens =
      Token
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(instance_id == ^instance.id)
      |> Ash.read!(authorize?: false)

    approval = Enum.find(tokens, &(&1.node_id == "SlowApproval"))
    assert approval.status == :dead

    refute Enum.any?(tokens, &(&1.status in [:active, :executing, :waiting]))
  end

  test "the log records what was thrown, and does not say the instance failed" do
    {instance, _} = start!()

    events = events(instance)
    assert [event] = Enum.filter(events, &(&1.kind == :instance_errored))

    assert event.data["error_code"] == "DECLINED"
    assert event.data["error_ref"] == "Error_Declined"
    assert event.data["killed_node_ids"] == ["SlowApproval"]

    # Neither of the other two endings. Anything counting failures or completions must not
    # pick this up.
    refute Enum.any?(events, &(&1.kind == :instance_failed))
    refute Enum.any?(events, &(&1.kind == :instance_completed))
  end

  test "retrying an errored instance is refused, with a reason" do
    # Retry reactivates every dead token and re-enqueues it. On an errored instance those
    # dead tokens are branches the error end event killed on purpose, so retrying would
    # restart a process that already produced its answer.
    {instance, _} = start!()

    assert {:error, message} = AshBpmn.retry_instance(reload(instance))
    assert message =~ "designed outcome"
    assert message =~ "Start a new instance"
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp compile! do
    xml = File.read!("test/fixtures/error_end.bpmn")

    defn =
      Definition.create!(%{key: "ee_#{System.unique_integer([:positive])}", name: "EE", xml: xml})

    if is_nil(defn.graph), do: raise("compile failed: #{inspect(defn.errors)}")
    defn
  end

  defp start! do
    defn = compile!()

    # Through the resource's own `publish` action, not an UPDATE. Raw SQL here would skip
    # `ErrorsEmpty`, which is the validation that stops a definition with compile errors
    # being published -- so a test using SQL could publish something the application never
    # would, and then assert on its behaviour.
    defn = Definition.publish!(defn)

    {:ok, subject} =
      AshBpmn.Test.Subject.create!(%{name: "error", amount: 0, is_privileged: false})

    {:ok, instance} =
      AshBpmn.start_instance(AshBpmn.Test.Domain, definition: defn, subject: subject)

    {instance, defn}
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
