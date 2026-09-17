# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.MultiInstanceTest do
  @moduledoc """
  An activity run once per element of a list.

  Earned by an RFQ awarded per property: one request covers several properties, each award
  needs its own compliance track, and the count is not known when the diagram is drawn.
  """

  use AshBpmn.DataCase, async: false

  require Ash.Query

  alias AshBpmn.Runtime.Oban.TestJobs
  alias AshBpmn.Test.{Definition, Instance, ProcessEvent, Subject, Token}

  setup do
    AshBpmn.Test.Invoker.clear_calls()
    TestJobs.clear()
    :ok
  end

  test "one instance per element, and the activity runs that many times" do
    instance = start!(["p1", "p2", "p3"])

    assert invocations("onboard") == 3
    assert reload(instance).status == :completed
  end

  test "each instance carries its own element, and nothing else" do
    instance = start!(["p1", "p2"])

    # The token that *arrived* at the node sits there too, consumed, with no element -- it is
    # the one that fanned out. The instances are the ones carrying a fork id.
    instances = instance_tokens(instance, "Onboard")

    assert Enum.map(instances, & &1.routing["property_id"]) |> Enum.sort() == ["p1", "p2"]

    # One fork id shared by them, which is what the join counts on.
    assert instances |> Enum.map(& &1.fork_id) |> Enum.uniq() |> length() == 1
  end

  test "what follows runs once, not once per element" do
    # The property the join exists for. Letting each instance follow its outgoing flow would
    # run the rest of the process N times before anything noticed.
    instance = start!(["p1", "p2", "p3"])

    assert invocations("notify") == 1
    assert length(tokens_at(instance, "Notify")) == 1
  end

  test "the element does not travel past the join" do
    # Each instance ran for one element; carrying any single one of them onward would make
    # the continuation look like it belonged to whichever branch finished last.
    instance = start!(["p1", "p2"])

    assert [continuation] = tokens_at(instance, "Notify")
    refute Map.has_key?(continuation.routing, "property_id")
  end

  test "an empty collection is done, not broken" do
    # "Do this for each of none" is finished. Refusing it would make an ordinary empty list a
    # runtime failure on a diagram that is perfectly correct.
    instance = start!([])

    assert invocations("onboard") == 0
    assert invocations("notify") == 1
    assert reload(instance).status == :completed
  end

  test "a null collection is an error, because it is not an empty list" do
    # A path that does not resolve and a list with nothing in it are different facts, and
    # treating the first as the second would silently skip work somebody drew.
    xml =
      String.replace(
        File.read!("test/fixtures/multi_instance.bpmn"),
        ~s(from="subject.property_ids"),
        ~s(from="subject.no_such_field")
      )

    assert {:error, error} = start_xml(xml, [])
    assert Exception.message(error) =~ "not an empty list"
  end

  test "a collection of records is refused at run time, not quietly copied onto tokens" do
    # The rule the whole design rests on: tokens carry routing, not business data. Fanning out
    # records would put the subject's contents on N tokens and make the process a second
    # source of truth about them.
    xml =
      String.replace(
        File.read!("test/fixtures/multi_instance.bpmn"),
        ~s(from="subject.property_ids"),
        ~s(from="[subject]")
      )

    assert {:error, error} = start_xml(xml, [])
    assert Exception.message(error) =~ "is not a scalar"
  end

  test "the fan-out is recorded with its width" do
    instance = start!(["p1", "p2", "p3"])

    entered =
      events(instance)
      |> Enum.filter(&(&1.kind == :node_entered and &1.data["instances"]))
      |> List.first()

    assert entered.data["instances"] == 3
    assert entered.data["as"] == "property_id"
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp start!(ids), do: start_xml!(File.read!("test/fixtures/multi_instance.bpmn"), ids)

  defp start_xml!(xml, ids) do
    {:ok, instance} = start_xml(xml, ids)
    instance
  end

  defp start_xml(xml, ids) do
    defn =
      Definition.create!(%{key: "mi_#{System.unique_integer([:positive])}", name: "MI", xml: xml})

    if is_nil(defn.graph), do: raise("compile failed: #{inspect(defn.errors)}")
    defn = Definition.publish!(defn)

    {:ok, subject} =
      Subject.create!(%{name: "mi", amount: 0, is_privileged: false, property_ids: ids})

    AshBpmn.start_instance(AshBpmn.Test.Domain, definition: defn, subject: subject)
  end

  defp invocations(action) do
    AshBpmn.Test.Invoker.recorded_calls()
    |> Enum.count(fn {_id, a, _ts} -> a == action end)
  end

  defp reload(instance) do
    Instance
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^instance.id)
    |> Ash.read_one!(authorize?: false)
  end

  defp instance_tokens(instance, node_id) do
    instance |> tokens_at(node_id) |> Enum.reject(&is_nil(&1.fork_id))
  end

  defp tokens_at(instance, node_id) do
    Token
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(instance_id == ^instance.id and node_id == ^node_id)
    |> Ash.read!(authorize?: false)
  end

  defp events(instance) do
    ProcessEvent
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(instance_id == ^instance.id)
    |> Ash.read!(authorize?: false)
  end
end
