# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.CancelCascadeTest do
  @moduledoc """
  Cancelling an instance cancels the instances its call activities started, all the way down,
  in one step, and says who did it and why.

  A child left running after its parent was cancelled does its work for nobody: its
  completion finds the parent's token dead and wakes nothing.
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

  test "cancelling the parent cancels a call-activity child; the event carries actor and reason" do
    parent = start_parent!(publish_child!())
    [child] = children_of(parent)
    [task] = tasks_of(child)
    actor = %{id: Ash.UUID.generate()}

    assert {:ok, cancelled} =
             AshBpmn.cancel_instance(parent, actor: actor, reason: "withdrawn by the clinic")

    assert cancelled.status == :cancelled
    assert reload(child).status == :cancelled
    assert reload_task(task).status == :cancelled
    refute Enum.any?(tokens_of(child), &live?/1)
    refute Enum.any?(tokens_of(parent), &live?/1)

    assert [event] = cancelled_events(parent)
    assert event.data["cancelled_by_id"] == actor.id
    assert event.data["reason"] == "withdrawn by the clinic"
    refute Map.has_key?(event.data, "cascaded_from_instance_id")

    assert [child_event] = cancelled_events(child)
    assert child_event.data["cancelled_by_id"] == actor.id
    assert child_event.data["reason"] == "withdrawn by the clinic"
    assert child_event.data["cascaded_from_instance_id"] == parent.id
  end

  test "the cascade reaches the whole call tree" do
    grandchild_key = publish_child!()
    child_key = key()
    publish!(call_parent_xml(grandchild_key), child_key)

    parent = start_parent!(child_key)
    [child] = children_of(parent)
    [grandchild] = children_of(child)

    AshBpmn.cancel_instance!(parent, reason: "duplicate request")

    assert reload(child).status == :cancelled
    assert reload(grandchild).status == :cancelled
    assert Enum.all?(tasks_of(grandchild), &(&1.status == :cancelled))

    assert [event] = cancelled_events(grandchild)
    assert event.data["cascaded_from_instance_id"] == parent.id
    assert event.data["reason"] == "duplicate request"
  end

  test "a child's task decided after the cancel moves nothing" do
    parent = start_parent!(publish_child!())
    [child] = children_of(parent)
    [task] = tasks_of(child)

    AshBpmn.cancel_instance!(parent)

    assert {:error, _} =
             AshBpmn.complete_task(reload_task(task),
               outcome: :approved,
               actor: candidate_actor(task)
             )

    refute AshBpmn.Test.Invoker.recorded_calls()
           |> Enum.any?(fn {_id, action, _ts} -> action == "after_child" end)

    assert reload(parent).status == :cancelled
  end

  test "an actor without an id and no reason are recorded as nil" do
    parent = start_parent!(publish_child!())

    AshBpmn.cancel_instance!(parent)

    assert [event] = cancelled_events(parent)
    assert event.data == %{"cancelled_by_id" => nil, "reason" => nil}
  end

  test "an instance that is not running is refused, and nothing is written" do
    parent = start_parent!(publish_child!())
    AshBpmn.cancel_instance!(parent)

    assert {:error, _} = AshBpmn.cancel_instance(parent, reason: "again")

    assert [event] = cancelled_events(parent)
    refute event.data["reason"]
    assert_raise Ash.Error.Invalid, fn -> AshBpmn.cancel_instance!(parent) end
  end

  test "a cancel refused inside the caller's transaction leaves that transaction to commit" do
    parent = start_parent!(publish_child!())
    AshBpmn.cancel_instance!(parent)

    assert {:ok, {:error, _}} =
             AshBpmn.TestRepo.transaction(fn -> AshBpmn.cancel_instance(parent) end)
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp key, do: "cc_#{System.unique_integer([:positive])}"

  defp publish!(xml, k) do
    defn = Definition.create!(%{key: k, name: k, xml: xml})
    if is_nil(defn.graph), do: raise("compile failed: #{inspect(defn.errors)}")
    Definition.publish!(defn)
  end

  # A child that parks on an approval, so it is still running when the parent is cancelled.
  defp publish_child! do
    k = key()
    publish!(File.read!("test/fixtures/access_request.bpmn"), k)
    k
  end

  defp call_parent_xml(child_key) do
    "test/fixtures/call_parent.bpmn"
    |> File.read!()
    |> String.replace("CHILD_KEY", child_key)
  end

  defp start_parent!(child_key) do
    defn = publish!(call_parent_xml(child_key), key())

    {:ok, subject} =
      AshBpmn.Test.Subject.create!(%{
        name: "cc",
        amount: 0,
        is_privileged: true,
        created_by_id: Ash.UUID.generate()
      })

    {:ok, parent} =
      AshBpmn.start_instance(AshBpmn.Test.Domain, definition: defn, subject: subject)

    parent
  end

  defp live?(token), do: token.status in [:active, :executing, :waiting]

  defp read(resource, filter) do
    resource
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(^filter)
    |> Ash.read!(authorize?: false)
  end

  defp reload(instance), do: hd(read(Instance, id: instance.id))
  defp reload_task(task), do: hd(read(HumanTask, id: task.id))
  defp children_of(instance), do: read(Instance, parent_instance_id: instance.id)
  defp tasks_of(instance), do: read(HumanTask, instance_id: instance.id)
  defp tokens_of(instance), do: read(Token, instance_id: instance.id)

  defp cancelled_events(instance),
    do: read(ProcessEvent, instance_id: instance.id, kind: :instance_cancelled)
end
