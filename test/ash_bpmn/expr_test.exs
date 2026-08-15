# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

# Helper struct for struct traversal tests
defmodule MyStruct do
  defstruct [:name, :level]
end

defmodule AshBpmn.ExprTest do
  use ExUnit.Case, async: true

  alias AshBpmn.Expr

  # ── Parse: basic comparisons ──────────────────────────────────────────────

  test "parses simple equality" do
    assert {:ok, %{"cmp" => ["subject.status", "==", "active"]}} =
             Expr.parse("subject.status == \"active\"")
  end

  test "parses simple inequality" do
    assert {:ok, %{"cmp" => ["subject.role", "!=", "admin"]}} =
             Expr.parse("subject.role != 'admin'")
  end

  test "parses numeric comparison" do
    assert {:ok, %{"cmp" => ["subject.total_amount", ">", 100]}} =
             Expr.parse("subject.total_amount > 100")
  end

  test "parses float comparison" do
    assert {:ok, %{"cmp" => ["task.value", ">=", 3.14]}} =
             Expr.parse("task.value >= 3.14")
  end

  test "parses less-than comparison" do
    assert {:ok, %{"cmp" => ["env.count", "<", 50]}} =
             Expr.parse("env.count < 50")
  end

  test "parses less-than-or-equal comparison" do
    assert {:ok, %{"cmp" => ["env.limit", "<=", 10]}} =
             Expr.parse("env.limit <= 10")
  end

  # ── Parse: boolean literals ─────────────────────────────────────────────

  test "parses boolean true literal" do
    assert {:ok, %{"cmp" => ["subject.active", "==", true]}} =
             Expr.parse("subject.active == true")
  end

  test "parses boolean false literal" do
    assert {:ok, %{"cmp" => ["subject.deleted", "!=", false]}} =
             Expr.parse("subject.deleted != false")
  end

  # ── Parse: in-list ────────────────────────────────────────────────────────

  test "parses in-list with single item" do
    assert {:ok, %{"in" => ["subject.role", ["admin"]]}} =
             Expr.parse("subject.role in [\"admin\"]")
  end

  test "parses in-list with multiple items" do
    assert {:ok, %{"in" => ["subject.status", ["pending", "active"]]}} =
             Expr.parse("subject.status in [\"pending\", \"active\"]")
  end

  test "parses in-list with numeric items" do
    assert {:ok, %{"in" => ["subject.level", [1, 2, 3]]}} =
             Expr.parse("subject.level in [1, 2, 3]")
  end

  # ── Parse: precedence (and > or) ──────────────────────────────────────────

  test "parses or expression" do
    assert {:ok, %{"or" => [%{"cmp" => ["a", "==", 1]}, %{"cmp" => ["b", "==", 2]}]}} =
             Expr.parse("a == 1 or b == 2")
  end

  test "parses and expression" do
    assert {:ok, %{"and" => [%{"cmp" => ["a", "==", 1]}, %{"cmp" => ["b", "==", 2]}]}} =
             Expr.parse("a == 1 and b == 2")
  end

  test "and has higher precedence than or" do
    assert {:ok,
            %{
              "or" => [
                %{"and" => [%{"cmp" => ["a", "==", 1]}, %{"cmp" => ["b", "==", 2]}]},
                %{"cmp" => ["c", "==", 3]}
              ]
            }} =
             Expr.parse("a == 1 and b == 2 or c == 3")
  end

  test "parens-free: or then and" do
    # "a == 1 or b == 2 and c == 3" should parse as: a==1 or (b==2 and c==3)
    assert {:ok,
            %{
              "or" => [
                %{"cmp" => ["a", "==", 1]},
                %{"and" => [%{"cmp" => ["b", "==", 2]}, %{"cmp" => ["c", "==", 3]}]}
              ]
            }} =
             Expr.parse("a == 1 or b == 2 and c == 3")
  end

  # ── Parse: not ───────────────────────────────────────────────────────────

  test "parses not expression" do
    assert {:ok, %{"not" => %{"cmp" => ["subject.active", "==", true]}}} =
             Expr.parse("not subject.active == true")
  end

  test "parses double not" do
    assert {:ok, %{"not" => %{"not" => %{"cmp" => ["a", "==", 1]}}}} =
             Expr.parse("not not a == 1")
  end

  # ── Parse: dotted paths ──────────────────────────────────────────────────

  test "parses simple path" do
    assert {:ok, %{"cmp" => ["foo", "==", "bar"]}} = Expr.parse("foo == \"bar\"")
  end

  test "parses two-segment path" do
    assert {:ok, %{"cmp" => ["subject.name", "==", "test"]}} =
             Expr.parse("subject.name == \"test\"")
  end

  test "parses three-segment path" do
    assert {:ok, %{"cmp" => ["subject.role.is_privileged", "==", true]}} =
             Expr.parse("subject.role.is_privileged == true")
  end

  # ── Parse: strings (double and single quoted) ─────────────────────────────

  test "parses double-quoted string" do
    assert {:ok, %{"cmp" => ["x", "==", "hello world"]}} =
             Expr.parse("x == \"hello world\"")
  end

  test "parses single-quoted string" do
    assert {:ok, %{"cmp" => ["x", "==", "hello world"]}} =
             Expr.parse("x == 'hello world'")
  end

  # ── Parse: errors ────────────────────────────────────────────────────────

  test "error on unexpected token" do
    assert {:error, msg} = Expr.parse("&&&")
    assert is_binary(msg)
  end

  test "error on incomplete expression" do
    assert {:error, msg} = Expr.parse("subject.name ==")
    assert is_binary(msg)
  end

  # ── Eval: basic comparisons ───────────────────────────────────────────────

  test "eval simple equality true" do
    ast = %{"cmp" => ["subject.status", "==", "active"]}
    assert {:ok, true} = Expr.eval(ast, %{"subject" => %{"status" => "active"}})
  end

  test "eval simple equality false" do
    ast = %{"cmp" => ["subject.status", "==", "active"]}
    assert {:ok, false} = Expr.eval(ast, %{"subject" => %{"status" => "inactive"}})
  end

  test "eval numeric greater-than" do
    ast = %{"cmp" => ["subject.amount", ">", 100]}
    assert {:ok, true} = Expr.eval(ast, %{"subject" => %{"amount" => 200}})
  end

  test "eval numeric greater-than false" do
    ast = %{"cmp" => ["subject.amount", ">", 100]}
    assert {:ok, false} = Expr.eval(ast, %{"subject" => %{"amount" => 50}})
  end

  # ── Eval: nil semantics ───────────────────────────────────────────────────

  test "eval nil == nil is true" do
    ast = %{"cmp" => ["subject.foo", "==", nil]}
    assert {:ok, true} = Expr.eval(ast, %{"subject" => %{"foo" => nil}})
  end

  test "eval nil != nil is false" do
    ast = %{"cmp" => ["subject.foo", "!=", nil]}
    assert {:ok, false} = Expr.eval(ast, %{"subject" => %{"foo" => nil}})
  end

  test "eval nil == value is false" do
    ast = %{"cmp" => ["subject.foo", "==", "bar"]}
    assert {:ok, false} = Expr.eval(ast, %{"subject" => %{"foo" => nil}})
  end

  test "eval nil > 0 is false (nil only supports == and !=)" do
    ast = %{"cmp" => ["subject.foo", ">", 0]}
    assert {:ok, false} = Expr.eval(ast, %{"subject" => %{"foo" => nil}})
  end

  test "eval nil < 0 is false" do
    ast = %{"cmp" => ["subject.foo", "<", 0]}
    assert {:ok, false} = Expr.eval(ast, %{"subject" => %{"foo" => nil}})
  end

  # ── Eval: missing path → false ────────────────────────────────────────────

  test "eval missing path returns false" do
    ast = %{"cmp" => ["subject.nonexistent.deep.field", "==", "value"]}
    assert {:ok, false} = Expr.eval(ast, %{"subject" => %{"name" => "test"}})
  end

  test "eval missing top-level key returns false" do
    ast = %{"cmp" => ["nonexistent", "==", "value"]}
    assert {:ok, false} = Expr.eval(ast, %{"subject" => %{}})
  end

  # ── Eval: string comparison ──────────────────────────────────────────────

  test "eval string != only" do
    ast = %{"cmp" => ["subject.name", ">", "alice"]}
    assert {:ok, false} = Expr.eval(ast, %{"subject" => %{"name" => "bob"}})
  end

  test "eval string < only" do
    ast = %{"cmp" => ["subject.name", "<", "alice"]}
    assert {:ok, false} = Expr.eval(ast, %{"subject" => %{"name" => "bob"}})
  end

  # ── Eval: in-list ─────────────────────────────────────────────────────────

  test "eval in-list true" do
    ast = %{"in" => ["subject.role", ["admin", "editor"]]}
    assert {:ok, true} = Expr.eval(ast, %{"subject" => %{"role" => "admin"}})
  end

  test "eval in-list false" do
    ast = %{"in" => ["subject.role", ["admin", "editor"]]}
    assert {:ok, false} = Expr.eval(ast, %{"subject" => %{"role" => "viewer"}})
  end

  test "eval in-list missing path returns false" do
    ast = %{"in" => ["subject.missing", ["a", "b"]]}
    assert {:ok, false} = Expr.eval(ast, %{"subject" => %{}})
  end

  # ── Eval: boolean operators ──────────────────────────────────────────────

  test "eval or true" do
    ast = %{"or" => [%{"cmp" => ["a", "==", 1]}, %{"cmp" => ["b", "==", 2]}]}
    assert {:ok, true} = Expr.eval(ast, %{"a" => 1, "b" => 99})
  end

  test "eval or false" do
    ast = %{"or" => [%{"cmp" => ["a", "==", 1]}, %{"cmp" => ["b", "==", 2]}]}
    assert {:ok, false} = Expr.eval(ast, %{"a" => 99, "b" => 99})
  end

  test "eval and true" do
    ast = %{"and" => [%{"cmp" => ["a", "==", 1]}, %{"cmp" => ["b", "==", 2]}]}
    assert {:ok, true} = Expr.eval(ast, %{"a" => 1, "b" => 2})
  end

  test "eval and false" do
    ast = %{"and" => [%{"cmp" => ["a", "==", 1]}, %{"cmp" => ["b", "==", 2]}]}
    assert {:ok, false} = Expr.eval(ast, %{"a" => 1, "b" => 99})
  end

  test "eval not true" do
    ast = %{"not" => %{"cmp" => ["a", "==", 1]}}
    assert {:ok, true} = Expr.eval(ast, %{"a" => 99})
  end

  test "eval not false" do
    ast = %{"not" => %{"cmp" => ["a", "==", 1]}}
    assert {:ok, false} = Expr.eval(ast, %{"a" => 1})
  end

  # ── Eval: struct traversal ────────────────────────────────────────────────

  test "eval traverses structs via Map.get" do
    struct_module = struct(MyStruct, name: "test", level: 3)
    ast = %{"cmp" => ["subject.name", "==", "test"]}
    assert {:ok, true} = Expr.eval(ast, %{"subject" => struct_module})
  end

  test "eval struct with numeric field" do
    struct_module = struct(MyStruct, name: "test", level: 3)
    ast = %{"cmp" => ["subject.level", ">", 2]}
    assert {:ok, true} = Expr.eval(ast, %{"subject" => struct_module})
  end

  test "eval struct missing field returns false" do
    struct_module = struct(MyStruct, name: "test", level: 3)
    ast = %{"cmp" => ["subject.nonexistent", "==", "value"]}
    assert {:ok, false} = Expr.eval(ast, %{"subject" => struct_module})
  end

  # ── Eval: numeric comparison across int/float ────────────────────────────

  test "eval int vs float comparison" do
    ast = %{"cmp" => ["subject.amount", ">=", 100.0]}
    assert {:ok, true} = Expr.eval(ast, %{"subject" => %{"amount" => 100}})
  end

  test "eval float vs int comparison" do
    ast = %{"cmp" => ["subject.amount", "<", 200]}
    assert {:ok, true} = Expr.eval(ast, %{"subject" => %{"amount" => 100.5}})
  end

  # ── Eval: complex expressions ────────────────────────────────────────────

  test "eval complex or/and/not" do
    ast = %{
      "or" => [
        %{"and" => [%{"cmp" => ["a", ">", 5]}, %{"not" => %{"cmp" => ["b", "==", "skip"]}}]},
        %{"cmp" => ["c", "in", ["x", "y"]]}
      ]
    }

    assert {:ok, true} = Expr.eval(ast, %{"a" => 10, "b" => "ok", "c" => "z"})
  end

  test "eval complex expression false" do
    ast = %{
      "and" => [
        %{"or" => [%{"cmp" => ["a", "==", 1]}, %{"cmp" => ["b", "==", 2]}]},
        %{"cmp" => ["c", "==", 3]}
      ]
    }

    assert {:ok, false} = Expr.eval(ast, %{"a" => 99, "b" => 99, "c" => 99})
  end

  # ── Eval: task and env paths ─────────────────────────────────────────────

  test "eval task.outcome path" do
    ast = %{"cmp" => ["task.outcome", "==", "approved"]}
    assert {:ok, true} = Expr.eval(ast, %{"task" => %{"outcome" => "approved"}})
  end

  test "eval env path" do
    ast = %{"cmp" => ["env.max_amount", ">", 1000]}
    assert {:ok, true} = Expr.eval(ast, %{"env" => %{"max_amount" => 5000}})
  end

  # ── Round-trip property tests ───────────────────────────────────────────

  test "round-trip parse+eval for op > with numbers" do
    assert {:ok, ast} = Expr.parse("subject.value > 42")
    assert {:ok, false} = Expr.eval(ast, %{"subject" => %{"value" => 42}})
  end

  test "round-trip parse+eval for op >= with numbers" do
    assert {:ok, ast} = Expr.parse("subject.value >= 42")
    assert {:ok, true} = Expr.eval(ast, %{"subject" => %{"value" => 42}})
  end

  test "round-trip parse+eval for op < with numbers" do
    assert {:ok, ast} = Expr.parse("subject.value < 100")
    assert {:ok, true} = Expr.eval(ast, %{"subject" => %{"value" => 42}})
  end

  test "round-trip parse+eval for op <= with numbers" do
    assert {:ok, ast} = Expr.parse("subject.value <= 42")
    assert {:ok, true} = Expr.eval(ast, %{"subject" => %{"value" => 42}})
  end

  test "round-trip parse+eval for op == with numbers" do
    assert {:ok, ast} = Expr.parse("subject.value == 42")
    assert {:ok, true} = Expr.eval(ast, %{"subject" => %{"value" => 42}})
  end

  test "round-trip parse+eval for op != with numbers" do
    assert {:ok, ast} = Expr.parse("subject.value != 42")
    assert {:ok, false} = Expr.eval(ast, %{"subject" => %{"value" => 42}})
  end

  test "round-trip parse+eval for op == with strings" do
    assert {:ok, ast} = Expr.parse(~s(subject.name == "alice"))
    assert {:ok, true} = Expr.eval(ast, %{"subject" => %{"name" => "alice"}})
  end

  test "round-trip parse+eval for op != with strings" do
    assert {:ok, ast} = Expr.parse(~s(subject.name != "alice"))
    assert {:ok, false} = Expr.eval(ast, %{"subject" => %{"name" => "alice"}})
  end
end
