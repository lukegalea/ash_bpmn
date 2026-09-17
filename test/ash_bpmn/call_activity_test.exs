# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.CallActivityTest do
  @moduledoc """
  Process-as-action: start a child and wait for it.

  Earned by vendor onboarding, which is the same track whichever award produced it and today
  can only be drawn by copying it into every parent diagram -- so a change to onboarding means
  editing each copy, and the copies drift.
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

  test "the child runs and the parent carries on after it" do
    {parent, _child_key} = start!()

    assert invoked?("do_something"), "the child's own work should have run"
    assert invoked?("after_child"), "and then the parent's"
    assert reload(parent).status == :completed
  end

  test "the child names the token waiting for it" do
    {parent, _} = start!(child: "approval")

    [child] = children_of(parent)
    parked = token_at(parent, "Onboard")

    assert child.parent_instance_id == parent.id
    assert child.parent_token_id == parked.id

    # Parked with no signature and no key. There is nothing to correlate -- a call activity is
    # woken by *its* child and by nothing else -- and advertising an interest would let the
    # correlator match on it.
    assert parked.status == :waiting
    refute parked.subscription_signature
    refute parked.correlation_key
  end

  test "the parent waits while the child does" do
    # The child here parks on an approval, so nothing completes and the parent must sit still.
    {parent, _} = start!(child: "approval")

    assert reload(parent).status == :running
    assert token_at(parent, "Onboard").status == :waiting
    refute invoked?("after_child")
  end

  test "completing the child's approval releases the parent" do
    {parent, _} = start!(child: "approval")
    [child] = children_of(parent)

    task =
      HumanTask
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(instance_id == ^child.id)
      |> Ash.read!(authorize?: false)
      |> List.first()

    {:ok, _} = AshBpmn.complete_task(task, outcome: :approved, actor: %{id: Ash.UUID.generate()})

    assert reload(parent).status == :completed
    assert invoked?("after_child")
  end

  test "both halves are recorded, because they are different findings" do
    # "It was never started" and "it never came back" are the two things that go wrong, and
    # one row could not tell them apart.
    {parent, _} = start!()

    kinds = parent |> events() |> Enum.map(& &1.kind)
    assert :child_started in kinds
    assert :child_completed in kinds
  end

  test "the child inherits the depth, so a process that calls itself is bounded" do
    {parent, _} = start!()
    [child] = children_of(parent)

    assert child.trigger_depth == (reload(parent).trigger_depth || 0) + 1
  end

  describe "refusing" do
    test "a call activity with no ash:process is refused" do
      xml =
        String.replace(
          File.read!("test/fixtures/call_parent.bpmn"),
          ~r|<bpmn2:extensionElements>.*?</bpmn2:extensionElements>|s,
          "",
          global: false
        )

      defn = Definition.create!(%{key: key(), name: "C", xml: xml})
      refute defn.graph
      assert Enum.map_join(defn.errors, " ", & &1["message"]) =~ "no ash:process"
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp key, do: "ca_#{System.unique_integer([:positive])}"

  defp publish!(fixture, k) do
    xml = File.read!("test/fixtures/#{fixture}")
    defn = Definition.create!(%{key: k, name: k, xml: xml})
    if is_nil(defn.graph), do: raise("compile failed: #{inspect(defn.errors)}")
    Definition.publish!(defn)
  end

  defp start!(opts \\ []) do
    child_fixture = if opts[:child] == "approval", do: "access_request.bpmn", else: "linear.bpmn"
    child_key = key()
    publish!(child_fixture, child_key)

    parent_xml =
      File.read!("test/fixtures/call_parent.bpmn")
      |> String.replace("CHILD_KEY", child_key)

    parent_defn =
      Definition.create!(%{key: key(), name: "parent", xml: parent_xml})

    if is_nil(parent_defn.graph), do: raise("compile failed: #{inspect(parent_defn.errors)}")
    parent_defn = Definition.publish!(parent_defn)

    {:ok, subject} =
      AshBpmn.Test.Subject.create!(%{name: "ca", amount: 0, is_privileged: true})

    {:ok, parent} =
      AshBpmn.start_instance(AshBpmn.Test.Domain, definition: parent_defn, subject: subject)

    {parent, child_key}
  end

  defp children_of(parent) do
    Instance
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(parent_instance_id == ^parent.id)
    |> Ash.read!(authorize?: false)
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

  defp token_at(instance, node_id) do
    Token
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(instance_id == ^instance.id and node_id == ^node_id)
    |> Ash.read!(authorize?: false)
    |> List.first()
  end

  defp events(instance) do
    ProcessEvent
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(instance_id == ^instance.id)
    |> Ash.read!(authorize?: false)
  end
end
