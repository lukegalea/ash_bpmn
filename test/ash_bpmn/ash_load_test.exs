# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.AshLoadTest do
  @moduledoc """
  `ash:load`: a node declaring what its expressions need on the subject.

  The subject is read live on every advance, which is what stops the process becoming a
  second source of truth about the domain. The price of that is a starved context — an
  unloaded calculation is a missing path, a missing path is FEEL null, and a condition over
  it is quietly never true rather than an error. These tests pin both halves: what happens
  without the declaration, and what changes with it.
  """

  use AshBpmn.DataCase, async: false

  require Ash.Query

  alias AshBpmn.Runtime.Oban.TestJobs
  alias AshBpmn.Subject
  alias AshBpmn.Test.{Definition, Instance}

  setup do
    AshBpmn.Test.Invoker.clear_calls()
    TestJobs.clear()
    :ok
  end

  describe "the load statement" do
    test "dotted paths nest, and siblings merge rather than overwrite" do
      assert Subject.load_statement(["doubled_amount"]) == [doubled_amount: []]
    end
  end

  describe "compiling" do
    test "the declaration lands on the node, whatever kind of node it is" do
      defn = compile!(File.read!("test/fixtures/ash_load.bpmn"))
      assert defn.graph["nodes"]["Gate_1"]["load"] == ["doubled_amount"]

      # Only on the node that declared it.
      refute defn.graph["nodes"]["Large"]["load"]
    end

    test "an ash:load with no paths is refused" do
      xml =
        String.replace(
          File.read!("test/fixtures/ash_load.bpmn"),
          ~s(<ash:path name="doubled_amount"/>),
          ""
        )

      defn = Definition.create!(%{key: key(), name: "L", xml: xml})
      refute defn.graph
      assert errors(defn) =~ "loads nothing"
    end

    test "an ash:path with no name is refused" do
      xml =
        String.replace(
          File.read!("test/fixtures/ash_load.bpmn"),
          ~s(<ash:path name="doubled_amount"/>),
          "<ash:path/>"
        )

      defn = Definition.create!(%{key: key(), name: "L", xml: xml})
      refute defn.graph
      assert errors(defn) =~ "no name"
    end
  end

  describe "routing" do
    test "a declared calculation is loaded, and the gateway routes on its value" do
      # amount 60, doubled 120, so the large branch.
      {instance, _} = start!(60, declared: true)

      assert invoked?("handle_large")
      refute invoked?("handle_small")
      assert reload(instance).status == :completed
    end

    test "the same diagram without the declaration takes the default branch" do
      # This is the behaviour the feature exists to fix, and it is asserted rather than
      # described: the calculation is not loaded, `subject.doubled_amount` is a missing path,
      # FEEL answers null, the condition is not true, and the gateway falls to its declared
      # default. Nothing errors and nothing warns -- which is exactly why a modeller could
      # not work out why their gateway never fired.
      {instance, _} = start!(60, declared: false)

      assert invoked?("handle_small")
      refute invoked?("handle_large")
      assert reload(instance).status == :completed
    end

    test "a declared path the resource does not have does not crash the advance" do
      # A modelling error, and it must not take the instance down: FEEL already answers a
      # missing path as null, which is the same answer the node would have got had the load
      # never been declared. Crashing every instance of a published definition would be a
      # worse response to a typo than an unanswerable condition.
      xml =
        String.replace(
          File.read!("test/fixtures/ash_load.bpmn"),
          ~s(name="doubled_amount"),
          ~s(name="no_such_thing")
        )

      {:ok, subject} = subject!(60)

      {:ok, instance} =
        AshBpmn.start_instance(AshBpmn.Test.Domain, definition: publish!(xml), subject: subject)

      assert reload(instance).status == :completed
      assert invoked?("handle_small")
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp key, do: "load_#{System.unique_integer([:positive])}"

  defp errors(defn), do: Enum.map_join(defn.errors, " ", & &1["message"])

  defp compile!(xml) do
    defn = Definition.create!(%{key: key(), name: "L", xml: xml})
    if is_nil(defn.graph), do: raise("compile failed: #{inspect(defn.errors)}")
    defn
  end

  defp publish!(xml), do: xml |> compile!() |> Definition.publish!()

  defp subject!(amount),
    do: AshBpmn.Test.Subject.create!(%{name: "load", amount: amount, is_privileged: false})

  defp start!(amount, declared: declared) do
    xml = File.read!("test/fixtures/ash_load.bpmn")

    xml =
      if declared do
        xml
      else
        String.replace(xml, ~r|<ash:load>.*?</ash:load>|s, "")
      end

    {:ok, subject} = subject!(amount)

    {:ok, instance} =
      AshBpmn.start_instance(AshBpmn.Test.Domain, definition: publish!(xml), subject: subject)

    {instance, subject}
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
end
