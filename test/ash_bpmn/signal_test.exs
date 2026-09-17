# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.SignalTest do
  @moduledoc """
  Throwing a signal, and the lap counter that stops one going round forever.
  """

  use AshBpmn.DataCase, async: false

  require Ash.Query

  alias AshBpmn.Test.{Definition, Instance, Signal}

  test "a host throws a signal with no instance behind it" do
    # The ordinary case for a host: something happened in the application and processes may
    # care. Nobody need be listening -- a signal caught by nothing is a fact that happened,
    # not an error.
    assert {:ok, signal} =
             AshBpmn.emit_signal("contract.countersigned", payload: %{"ref" => "C-1"})

    assert signal.name == "contract.countersigned"
    assert signal.payload == %{"ref" => "C-1"}
    refute signal.instance_id

    # Depth one: the host's call is the first hop.
    assert signal.depth == 1
  end

  test "a signal thrown by a process names it, and counts one lap further" do
    instance = instance!(trigger_depth: 3)

    assert {:ok, signal} =
             AshBpmn.emit_signal("review.done", instance: instance, node_id: "Throw_1")

    assert signal.instance_id == instance.id
    assert signal.node_id == "Throw_1"

    # The whole point of the column. A process started three hops deep throws at four, so a
    # cycle through signals is counted rather than restarting at zero every lap -- which is
    # what happened while depth lived only on the dispatch row.
    assert signal.depth == 4
  end

  test "an instance defaults to depth zero, so a person's process starts at one" do
    instance = instance!()
    assert instance.trigger_depth == 0

    assert {:ok, signal} = AshBpmn.emit_signal("x", instance: instance)
    assert signal.depth == 1
  end

  test "a signal is history: there is no way to edit or delete one" do
    # Editing one would rewrite something subscriptions have already acted on; deleting one
    # would leave dispatch rows pointing at nothing.
    actions =
      Ash.Resource.Info.actions(Signal) |> Enum.map(& &1.type) |> Enum.uniq() |> Enum.sort()

    assert actions == [:create, :read]
  end

  defp instance!(opts \\ []) do
    xml = File.read!("test/fixtures/linear.bpmn")

    defn =
      Definition.create!(%{key: "sig_#{System.unique_integer([:positive])}", name: "S", xml: xml})

    {:ok, subject} =
      AshBpmn.Test.Subject.create!(%{name: "sig", amount: 0, is_privileged: false})

    Instance.create!(%{
      subject_type: "AshBpmn.Test.Subject",
      subject_id: subject.id,
      definition_id: defn.id,
      trigger_depth: Keyword.get(opts, :trigger_depth, 0)
    })
  end
end
