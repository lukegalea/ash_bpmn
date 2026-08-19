# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.FeelTest do
  @moduledoc """
  The FEEL adapter, and specifically the three things about it that are easy to get wrong and
  silent when you do.

  This file replaces `expr_test.exs`, which was not ported. Porting it would have re-encoded
  three semantics FEEL deliberately contradicts — `"a" > "b"` is false, `x != nil` is false
  when nil, and every error is false — so the useful part to carry over was not the assertions
  but the coverage: what the compiler accepts, what evaluation does with a missing path, and
  what a gateway does with each answer.
  """

  use ExUnit.Case, async: true

  alias AshBpmn.Feel

  describe "compile/1" do
    test "accepts a FEEL expression and stores its source" do
      assert {:ok, %{"language" => "feel", "text" => "subject.amount > 100"}} =
               Feel.compile("  subject.amount > 100  ")
    end

    test "rejects an unparseable expression with the engine's message" do
      assert {:error, message} = Feel.compile("subject.amount >")
      assert is_binary(message)
      refute message == ""
    end

    test "rejects an empty expression rather than storing a condition that is never true" do
      assert {:error, "expression is empty"} = Feel.compile("   ")
    end

    test "refuses an expression larger than the parse budget" do
      huge = "1 = 1 and " |> String.duplicate(2_000)
      assert {:error, message} = Feel.compile(huge)
      assert message =~ "over the"
    end
  end

  describe "evaluate_condition/3" do
    test "true takes the branch" do
      {:ok, stored} = Feel.compile("subject.amount > 100")
      ctx = %{"subject" => Feel.to_feel_value(%{amount: 200})}
      assert {:ok, true} = Feel.evaluate_condition(stored, ctx)
    end

    test "false is an ordinary answer" do
      {:ok, stored} = Feel.compile("subject.amount > 100")
      ctx = %{"subject" => Feel.to_feel_value(%{amount: 50})}
      assert {:ok, false} = Feel.evaluate_condition(stored, ctx)
    end

    # The distinction the whole design rests on: a missing path is not `false`, it is "no
    # answer". The gateway treats both the same way, but records them differently.
    test "a missing path is null, not false" do
      {:ok, stored} = Feel.compile("subject.nonexistent > 100")
      ctx = %{"subject" => Feel.to_feel_value(%{amount: 200})}
      assert {:ok, nil} = Feel.evaluate_condition(stored, ctx)
    end

    test "a type mismatch is null, not false" do
      {:ok, stored} = Feel.compile("subject.name > 100")
      ctx = %{"subject" => Feel.to_feel_value(%{name: "hello"})}
      assert {:ok, nil} = Feel.evaluate_condition(stored, ctx)
    end

    test "an expression that is not a boolean is an error, not a false branch" do
      {:ok, stored} = Feel.compile("subject.amount + 1")
      ctx = %{"subject" => Feel.to_feel_value(%{amount: 200})}
      assert {:error, message} = Feel.evaluate_condition(stored, ctx)
      assert message =~ "not a boolean"
    end

    test "a nil condition is not an answer" do
      assert {:ok, nil} = Feel.evaluate_condition(nil, %{})
    end

    test "string comparison is lexicographic, which the previous language refused" do
      {:ok, stored} = Feel.compile(~s|subject.name > "abc"|)
      ctx = %{"subject" => Feel.to_feel_value(%{name: "xyz"})}
      assert {:ok, true} = Feel.evaluate_condition(stored, ctx)
    end
  end

  describe "to_feel_value/2" do
    # The single most consequential conversion in the adapter. Boxic parses a numeric literal
    # to a Decimal, and comparing a Decimal against an Elixir integer is a type error, which
    # FEEL folds to null, which a gateway reads as "branch not taken". A wrong route with no
    # error anywhere is exactly the failure mode this whole change exists to remove.
    test "integers and floats become Decimal, or every numeric comparison silently fails" do
      assert %Decimal{} = Feel.to_feel_value(200)
      assert %Decimal{} = Feel.to_feel_value(1.5)
      assert Decimal.equal?(Feel.to_feel_value(200), Decimal.new(200))
    end

    test "booleans stay booleans" do
      assert Feel.to_feel_value(true) == true
      assert Feel.to_feel_value(false) == false
    end

    test "struct fields become string keys" do
      assert %{"amount" => amount, "name" => "x"} = Feel.to_feel_value(%{amount: 1, name: "x"})
      assert Decimal.equal?(amount, Decimal.new(1))
    end

    # Dropping rather than nilling is deliberate. A dropped key is a missing path is null --
    # "we do not know" -- where nil would assert that we do.
    test "unloaded relationships are dropped, so the path is missing rather than nil" do
      converted = Feel.to_feel_value(%{amount: 1, author: %Ash.NotLoaded{type: :relationship}})
      refute Map.has_key?(converted, "author")
      assert Map.has_key?(converted, "amount")
    end

    # And for a forbidden field it is the only safe behaviour: nilling it would let a value
    # the actor may not read influence which branch the process takes.
    test "forbidden fields are dropped, so a hidden value cannot influence routing" do
      converted = Feel.to_feel_value(%{amount: 1, salary: %Ash.ForbiddenField{field: :salary}})
      refute Map.has_key?(converted, "salary")
    end

    test "recursion is depth-bounded" do
      deep = %{a: %{b: %{c: %{d: %{e: 1}}}}}
      assert is_map(Feel.to_feel_value(deep))
    end

    test "atoms become strings so they compare against FEEL string literals" do
      assert Feel.to_feel_value(:approved) == "approved"
    end
  end

  describe "print/1" do
    test "renders the source, because the source is what is stored" do
      {:ok, stored} = Feel.compile("subject.amount > 100")
      assert Feel.print(stored) == "subject.amount > 100"
      assert Feel.print(nil) == ""
    end
  end
end
