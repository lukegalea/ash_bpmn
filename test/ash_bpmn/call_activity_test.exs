# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.CallActivityTest do
  @moduledoc """
  Process-as-action: start a child and wait for it.

  Earned by patient triage, which is the same track whichever referral produced it and today
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

    {:ok, _} = AshBpmn.complete_task(task, outcome: :approved, actor: candidate_actor(task))

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

  describe "who started it" do
    test "the child is accountable to whoever started the parent" do
      starter = Ash.UUID.generate()
      {parent, _} = start!(child: "approval", started_by_id: starter)
      [child] = children_of(parent)

      assert reload(parent).started_by_id == starter
      assert child.started_by_id == starter
    end

    test "a grandchild is accountable to the same person" do
      starter = Ash.UUID.generate()
      grandchild_key = key()
      publish!("access_request.bpmn", grandchild_key)
      middle = publish_parent!(grandchild_key)
      top = publish_parent!(middle.key)

      parent = start_parent!(top, started_by_id: starter)
      [child] = children_of(parent)
      [grandchild] = children_of(child)

      assert child.started_by_id == starter
      assert grandchild.started_by_id == starter
    end

    test "a parent that names nobody passes nobody on, not the engine" do
      {parent, _} = start!(child: "approval")
      [child] = children_of(parent)

      assert reload(parent).started_by_id == nil
      assert child.started_by_id == nil
    end

    test "an instance started outside a call activity keeps the starter it was given" do
      starter = Ash.UUID.generate()
      other = Ash.UUID.generate()
      {parent, child_key} = start!(child: "approval", started_by_id: starter)

      # Started directly, under the same subject and process key as the call activity's
      # child, but not by it: it inherits nothing from the running parent.
      {:ok, direct} =
        AshBpmn.start_instance(AshBpmn.Test.Domain,
          process: child_key,
          subject_type: reload(parent).subject_type,
          subject_id: reload(parent).subject_id,
          started_by_id: other
        )

      {:ok, unnamed} =
        AshBpmn.start_instance(AshBpmn.Test.Domain,
          process: child_key,
          subject_type: reload(parent).subject_type,
          subject_id: reload(parent).subject_id
        )

      assert direct.started_by_id == other
      assert direct.parent_instance_id == nil
      assert unnamed.started_by_id == nil
    end
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

  describe "version binding" do
    test "latest is the default and writes nothing new into the snapshot" do
      defn = Definition.create!(%{key: key(), name: "C", xml: parent_xml("child")})
      assert defn.graph["nodes"]["Onboard"]["call_process"] == %{"key" => "child"}
    end

    test "a pinned binding carries its version" do
      defn = Definition.create!(%{key: key(), name: "C", xml: parent_xml("child", pin: "2")})

      assert defn.graph["nodes"]["Onboard"]["call_process"] == %{
               "key" => "child",
               "binding" => "pinned",
               "version" => 2
             }
    end

    test "a pinned child keeps v1 after v2 publishes" do
      child_key = key()
      v1 = publish!("linear.bpmn", child_key)
      pinned = publish_parent!(child_key, pin: "1")
      latest = publish_parent!(child_key)

      before = start_parent!(pinned)
      assert [%{definition_id: definition_id}] = children_of(before)
      assert definition_id == v1.id

      v2 = publish!("linear.bpmn", child_key)
      assert v2.version == 2

      after_pinned = start_parent!(pinned)
      assert [%{definition_id: ^definition_id}] = children_of(after_pinned)
      assert reload(after_pinned).status == :completed

      [started] = Enum.filter(events(after_pinned), &(&1.kind == :child_started))
      assert started.data["child_definition_id"] == v1.id

      # And the default binding moves on, which is the difference.
      after_latest = start_parent!(latest)
      assert [%{definition_id: v2_id}] = children_of(after_latest)
      assert v2_id == v2.id
    end

    test "a pinned version that has been retired does not start" do
      child_key = key()
      v1 = publish!("linear.bpmn", child_key)
      _v2 = publish!("linear.bpmn", child_key)
      Definition.retire!(v1)

      assert {:error, message} =
               AshBpmn.start_instance(AshBpmn.Test.Domain,
                 process: child_key,
                 version: 1,
                 subject_type: "Subject",
                 subject_id: Ash.UUID.generate()
               )

      assert message =~ "retired"
    end

    test "a binding the compiler cannot honour is refused" do
      for {attrs, message} <- [
            {~s(binding="newest"), ~s(must be "latest" or "pinned")},
            {~s(binding="pinned"), "requires a version"},
            {~s(version="1"), "would be ignored"},
            {~s(binding="pinned" version="v1"), "positive integer"},
            {~s(binding="pinned" version="0"), "positive integer"}
          ] do
        xml =
          String.replace(
            File.read!("test/fixtures/call_parent.bpmn"),
            ~s(key="CHILD_KEY"),
            ~s(key="child" #{attrs})
          )

        defn = Definition.create!(%{key: key(), name: "C", xml: xml})
        refute defn.graph, "expected #{attrs} to be refused"
        assert Enum.map_join(defn.errors, " ", & &1["message"]) =~ message
      end
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp parent_xml(child_key, opts \\ []) do
    pin = if opts[:pin], do: ~s( binding="pinned" version="#{opts[:pin]}"), else: ""

    "test/fixtures/call_parent.bpmn"
    |> File.read!()
    |> String.replace(~s(key="CHILD_KEY"), ~s(key="#{child_key}"#{pin}))
  end

  defp publish_parent!(child_key, opts \\ []) do
    defn = Definition.create!(%{key: key(), name: "parent", xml: parent_xml(child_key, opts)})
    if is_nil(defn.graph), do: raise("compile failed: #{inspect(defn.errors)}")
    Definition.publish!(defn)
  end

  defp start_parent!(parent_defn, opts \\ []) do
    {:ok, subject} =
      AshBpmn.Test.Subject.create!(%{
        name: "ca",
        amount: 0,
        is_privileged: true,
        created_by_id: Ash.UUID.generate()
      })

    {:ok, parent} =
      AshBpmn.start_instance(
        AshBpmn.Test.Domain,
        [definition: parent_defn, subject: subject] ++ Keyword.take(opts, [:started_by_id])
      )

    parent
  end

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
      AshBpmn.Test.Subject.create!(%{
        name: "ca",
        amount: 0,
        is_privileged: true,
        created_by_id: Ash.UUID.generate()
      })

    {:ok, parent} =
      AshBpmn.start_instance(
        AshBpmn.Test.Domain,
        [definition: parent_defn, subject: subject] ++ Keyword.take(opts, [:started_by_id])
      )

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
