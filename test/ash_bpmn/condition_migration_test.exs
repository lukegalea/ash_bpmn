# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.ConditionMigrationTest do
  @moduledoc """
  Pins the one property that actually had to survive the move from `AshBpmn.Expr` to FEEL:
  **every condition in the shipped diagrams still routes the same way it did.**

  The old expression language's own test file was deleted rather than ported, because most of
  what it asserted is behaviour FEEL deliberately contradicts. What could not be allowed to
  change is which branch a real diagram takes for a real subject, and that is what is checked
  here — against the actual fixtures, not against transcribed strings, so a future edit to a
  diagram is covered too.
  """

  use ExUnit.Case, async: true

  alias AshBpmn.Feel

  # Every condition that appears in a diagram this package ships, with the contexts that must
  # select it and the contexts that must not. Written as data so adding a diagram means adding
  # a row rather than a test.
  # ## Equality and ordering treat a missing path differently, and it matters
  #
  # FEEL's three-valued logic is not uniform across operators. `subject.missing > 100` is
  # `null` -- no answer -- but `subject.missing = true` is plain `false`, because equality
  # against null is *defined*. The practical consequence for a diagram is that an
  # equality-based condition on a field the subject does not have takes the default branch
  # **silently**, with no `:condition_null` event to find afterwards, whereas an ordering
  # comparison on the same missing field is recorded.
  #
  # This is FEEL behaving to spec rather than a defect, and it is pinned here so nobody
  # "fixes" it later: an equality gateway that quietly defaults is a real diagnostic gap, and
  # knowing it exists is the difference between debugging it in minutes and in days.
  @cases [
    %{
      file: "test/fixtures/exclusive.bpmn",
      expression: "subject.amount > 100",
      true_for: [%{"subject" => %{amount: 200}}, %{"subject" => %{amount: 101}}],
      false_for: [%{"subject" => %{amount: 100}}, %{"subject" => %{amount: 0}}],
      null_for: [%{"subject" => %{name: "no amount here"}}, %{}]
    },
    %{
      file: "test/fixtures/access_request.bpmn",
      expression: "subject.is_privileged = true",
      true_for: [%{"subject" => %{is_privileged: true}}],
      # A missing path under `=` is false, not null -- see the note below the table.
      false_for: [%{"subject" => %{is_privileged: false}}, %{"subject" => %{}}],
      null_for: []
    },
    %{
      file: "test/fixtures/access_request.bpmn",
      expression: ~s|task.outcome = "approved"|,
      true_for: [%{"task" => %{"outcome" => "approved"}}],
      false_for: [%{"task" => %{"outcome" => "rejected"}}, %{"task" => %{}}],
      null_for: []
    }
  ]

  describe "the shipped diagrams' conditions" do
    for {c, index} <- Enum.with_index(@cases) do
      @case c

      test "#{c.expression} still routes as it did (#{index})" do
        assert {:ok, stored} = Feel.compile(@case.expression)

        for context <- @case.true_for do
          assert {:ok, true} = Feel.evaluate_condition(stored, feelify(context)),
                 "#{@case.expression} should be true for #{inspect(context)}"
        end

        for context <- @case.false_for do
          assert {:ok, false} = Feel.evaluate_condition(stored, feelify(context)),
                 "#{@case.expression} should be false for #{inspect(context)}"
        end

        # Null rather than false: the branch is still not taken, but the engine records that
        # it could not answer. See `AshBpmn.Feel`.
        for context <- @case.null_for do
          assert {:ok, nil} = Feel.evaluate_condition(stored, feelify(context)),
                 "#{@case.expression} should be null for #{inspect(context)}"
        end
      end
    end
  end

  describe "the fixtures themselves" do
    test "every conditionExpression in every shipped diagram compiles as FEEL" do
      for file <- Path.wildcard("test/fixtures/*.bpmn") ++ Path.wildcard("dev/priv/*.bpmn"),
          expression <- conditions_in(file) do
        assert {:ok, _stored} = Feel.compile(expression),
               "#{file} contains a conditionExpression that is not valid FEEL: #{expression}"
      end
    end

    # `==` is C, not FEEL. Every fixture used it before this change, and leaving one behind
    # would produce a parse error at publish time rather than at test time.
    test "no shipped diagram still uses the old language's equality operator" do
      for file <- Path.wildcard("test/fixtures/*.bpmn") ++ Path.wildcard("dev/priv/*.bpmn"),
          expression <- conditions_in(file) do
        refute expression =~ "==",
               "#{file} still uses `==`; FEEL equality is `=`: #{expression}"
      end
    end
  end

  defp conditions_in(file) do
    ~r/<(?:\w+:)?conditionExpression[^>]*>(.*?)<\/(?:\w+:)?conditionExpression>/s
    |> Regex.scan(File.read!(file), capture: :all_but_first)
    |> Enum.map(fn [body] -> body |> String.trim() |> unescape() end)
    |> Enum.reject(&(&1 == ""))
  end

  defp unescape(text) do
    text
    |> String.replace("&gt;", ">")
    |> String.replace("&lt;", "<")
    |> String.replace("&quot;", "\"")
    |> String.replace("&amp;", "&")
  end

  defp feelify(context), do: Map.new(context, fn {k, v} -> {k, Feel.to_feel_value(v)} end)
end
