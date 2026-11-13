# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.DiffTest do
  @moduledoc """
  Two versions of a process definition compared over the graph the engine runs, never the
  XML (`AshBpmn.Diff`).
  """

  use ExUnit.Case, async: true

  alias AshBpmn.Diff

  defp definition(graph), do: %{graph: graph}

  defp graph(condition, overrides \\ %{}) do
    Map.merge(
      %{
        "start" => "S",
        "nodes" => %{"S" => %{"type" => "startEvent"}, "E" => %{"type" => "endEvent"}},
        "flows" => %{"F" => %{"from" => "S", "to" => "E", "condition" => condition}}
      },
      overrides
    )
  end

  describe "diff/2" do
    test "a changed condition is one routing change, named by flow and property" do
      assert [
               %{
                 aspect: :routing,
                 kind: :changed,
                 subject: "F",
                 option: "condition",
                 from: nil,
                 to: "urgent"
               }
             ] = Diff.diff(definition(graph(nil)), definition(graph("urgent")))
    end

    test "the same graph has no changes, whatever the XML says" do
      old = %{graph: graph(nil), xml: "<bpmn2:definitions/>"}
      new = %{graph: graph(nil), xml: "<moved-shapes/>"}
      assert Diff.diff(old, new) == []
    end

    test "steps are added, removed and changed by node id" do
      old = graph(nil)

      new =
        graph(nil, %{
          "nodes" => %{
            "S" => %{"type" => "startEvent", "name" => "Begin"},
            "T" => %{"type" => "serviceTask", "action" => "check"}
          }
        })

      changes = Diff.diff(definition(old), definition(new))

      assert %{
               aspect: :steps,
               kind: :removed,
               subject: "E",
               option: nil,
               from: %{"type" => "endEvent"},
               to: nil
             } in changes

      assert %{
               aspect: :steps,
               kind: :added,
               subject: "T",
               option: nil,
               from: nil,
               to: %{"type" => "serviceTask", "action" => "check"}
             } in changes

      assert %{
               aspect: :steps,
               kind: :changed,
               subject: "S",
               option: "name",
               from: nil,
               to: "Begin"
             } in changes
    end

    test "a new start node is a start change" do
      changes =
        Diff.diff(definition(graph(nil)), definition(graph(nil, %{"start" => "E"})))

      assert [%{aspect: :start, kind: :changed, subject: nil, from: "S", to: "E"}] = changes
    end

    test "a definition that did not compile compares as empty" do
      changes = Diff.diff(definition(nil), definition(graph(nil)))

      assert Enum.map(changes, &{&1.aspect, &1.kind, &1.subject}) == [
               {:steps, :added, "E"},
               {:steps, :added, "S"},
               {:routing, :added, "F"},
               {:start, :changed, nil}
             ]

      assert Diff.diff(definition(nil), %{}) == []
    end

    test "every change is a plain map in one of the aspects" do
      changes = Diff.diff(definition(graph(nil)), definition(graph("x", %{"start" => "E"})))
      aspects = Keyword.keys(Diff.aspects())

      assert changes != []

      for change <- changes do
        refute is_struct(change)
        assert change.aspect in aspects
        assert Map.keys(change) |> Enum.sort() == [:aspect, :from, :kind, :option, :subject, :to]
      end
    end
  end

  describe "over compiled definitions" do
    test "moving shapes and reformatting change nothing; a condition and a task do" do
      xml = File.read!("test/fixtures/exclusive.bpmn")
      old = %{graph: AshBpmn.Compiler.compile!(xml)}

      reformatted = String.replace(xml, "\n    ", "\n        ")
      assert Diff.diff(old, %{graph: AshBpmn.Compiler.compile!(reformatted)}) == []

      edited =
        xml
        |> String.replace(~s(name="Task A"), ~s(name="Task A, renamed"))
        |> String.replace("subject.amount > 100", "subject.amount > 500")

      changes = Diff.diff(old, %{graph: AshBpmn.Compiler.compile!(edited)})

      assert Enum.any?(changes, &match?(%{aspect: :steps, subject: "Task_A", kind: :changed}, &1))

      assert Enum.any?(
               changes,
               &match?(%{aspect: :routing, subject: "Flow_cond", kind: :changed}, &1)
             )
    end
  end
end
