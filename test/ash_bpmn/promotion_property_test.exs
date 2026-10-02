# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.PromotionPropertyTest.BranchOne do
  @moduledoc false
  defstruct [:alpha, :beta]
end

defmodule AshBpmn.PromotionPropertyTest.BranchTwo do
  @moduledoc false
  defstruct [:gamma, :delta]
end

defmodule AshBpmn.PromotionPropertyTest do
  @moduledoc """
  The promotion contract as a property (AST-98, UP-BPMN-STRUCT/AC-2).

  For random nested maps and structs of depth ≤ 4 with scalar leaves, promoting
  any leaf by its dotted path yields exactly that leaf's string value; promoting
  a non-leaf — an intermediate map, a struct node, a `Date`/`DateTime` value
  struct, a list — returns a structured error naming the node, the path and the
  value's type, and never raises.

  The generator is seeded, so the run is deterministic: the same trees every
  time, no flakes, and a failure reproduces by re-running the file.
  """

  use ExUnit.Case, async: true

  alias AshBpmn.PromotionPropertyTest.BranchOne
  alias AshBpmn.PromotionPropertyTest.BranchTwo
  alias AshBpmn.Runtime.Promotion

  @seed_for_leaves {98, 10, 26}
  @seed_for_refusals {98, 10, 27}
  @trees 200
  @max_depth 4
  @keys ["alpha", "beta", "gamma", "delta", "score", "verdict", "tier", "amount"]

  test "promoting any scalar leaf by its dotted path yields exactly that leaf's string value" do
    :rand.seed(:exsss, @seed_for_leaves)

    assertions =
      Enum.reduce(1..@trees, 0, fn i, count ->
        tree = gen_tree()
        {leaves, _refusals} = classify(tree)

        for {path, value} <- leaves do
          name = path |> String.split(".") |> List.last()
          entry = %{"name" => name, "from" => path, "required" => true}

          assert {:ok, %{^name => promoted}} = Promotion.promote([entry], tree, "node-#{i}")
          assert promoted == leaf_string(value)
        end

        count + length(leaves)
      end)

    # The seed is fixed, so this floor is an exact property of the run: a
    # generator regression that stops producing leaves fails here, loudly.
    assert assertions > 300, "expected hundreds of leaf cases, got #{assertions}"
  end

  test "promoting a non-leaf returns a structured error and never raises" do
    :rand.seed(:exsss, @seed_for_refusals)

    refusals =
      Enum.flat_map(1..@trees, fn i ->
        tree = gen_tree()
        {_leaves, refusals_here} = classify(tree)

        for {path, value} <- refusals_here do
          name = path |> String.split(".") |> List.last()
          entry = %{"name" => name, "from" => path, "required" => false}

          assert {:error, message} = Promotion.promote([entry], tree, "node-#{i}")
          assert message =~ "node-#{i}"
          assert message =~ path
          assert message =~ "not a scalar"
          assert message =~ type_name(value)

          {path, value}
        end
      end)

    assert length(refusals) > 200, "expected hundreds of refusal cases, got #{length(refusals)}"
  end

  # ── The generator ────────────────────────────────────────────────────

  # The root is always a container; every other node rolls for its kind. Depth
  # ≤ 4 with scalar (and value-struct) leaves, maps and structs interleaved.
  defp gen_tree, do: if(:rand.uniform(4) == 1, do: gen_struct(0), else: gen_map(0))

  defp gen_node(depth) do
    roll = :rand.uniform(10)

    cond do
      depth >= @max_depth -> gen_leaf()
      roll <= 2 -> gen_struct(depth)
      roll <= 4 -> gen_leaf()
      true -> gen_map(depth)
    end
  end

  defp gen_map(depth) do
    @keys
    |> Enum.take_random(:rand.uniform(3))
    |> Map.new(fn key -> {key, gen_node(depth + 1)} end)
  end

  defp gen_struct(depth) do
    case :rand.uniform(2) do
      1 -> %BranchOne{alpha: gen_node(depth + 1), beta: gen_node(depth + 1)}
      2 -> %BranchTwo{gamma: gen_node(depth + 1), delta: gen_node(depth + 1)}
    end
  end

  # Scalars promote to their string value; `Date`/`DateTime` are value structs a
  # promotion refuses by name rather than flattens; `Decimal` is a scalar.
  defp gen_leaf do
    case :rand.uniform(9) do
      1 -> "leaf-#{:rand.uniform(999)}"
      2 -> :rand.uniform(999)
      3 -> :rand.uniform() * 100
      4 -> :rand.uniform(2) == 1
      5 -> nil
      6 -> Decimal.new(:rand.uniform(9999))
      7 -> Date.add(~D[2026-10-02], :rand.uniform(30))
      8 -> DateTime.add(~U[2026-10-02T00:00:00Z], :rand.uniform(86_400))
      9 -> "leaf-#{:rand.uniform(999)}"
    end
  end

  # ── Classification: every dotted path, and what promoting it should do ──

  defp classify(tree) do
    {leaves, refusals} = walk(tree, [], {[], []})
    {Enum.reverse(leaves), Enum.reverse(refusals)}
  end

  defp walk(node, prefix, acc) do
    cond do
      container?(node) ->
        acc =
          if prefix == [] do
            acc
          else
            push_refusal(acc, {path_string(prefix), node})
          end

        node
        |> children()
        |> Enum.reduce(acc, fn {key, child}, inner -> walk(child, [key | prefix], inner) end)

      scalar?(node) ->
        push_leaf(acc, {path_string(prefix), node})

      true ->
        # A value struct that is not a scalar: a leaf promotion refuses.
        push_refusal(acc, {path_string(prefix), node})
    end
  end

  # The prefix is built by prepending, so it reads root-last; join it root-first.
  defp path_string(prefix), do: prefix |> Enum.reverse() |> Enum.join(".")

  defp push_leaf({leaves, refusals}, entry), do: {[entry | leaves], refusals}
  defp push_refusal({leaves, refusals}, entry), do: {leaves, [entry | refusals]}

  defp container?(%mod{}) when mod in [BranchOne, BranchTwo], do: true
  defp container?(value) when is_map(value) and not is_struct(value), do: true
  defp container?(_value), do: false

  defp children(node) when is_struct(node), do: node |> Map.from_struct() |> children()

  defp children(node) when is_map(node) do
    Enum.map(node, fn
      {key, child} when is_atom(key) -> {Atom.to_string(key), child}
      pair -> pair
    end)
  end

  defp scalar?(value) do
    is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value) or
      is_struct(value, Decimal)
  end

  # ── Mirrors of the promotion gate's own conversions, so the expectation is
  #    stated in the test rather than read back out of the implementation ──

  defp leaf_string(nil), do: ""
  defp leaf_string(value) when is_boolean(value), do: to_string(value)
  defp leaf_string(%Decimal{} = value), do: Decimal.to_string(value, :normal)
  defp leaf_string(value) when is_binary(value), do: value
  defp leaf_string(value), do: to_string(value)

  # Custom structs are normalised to plain maps before the gate checks the value,
  # so a refusal names `map` for them; `Decimal`/`Date`/`DateTime` are preserved,
  # and name themselves.
  defp type_name(%mod{}) when mod in [BranchOne, BranchTwo], do: "map"
  defp type_name(%mod{}), do: inspect(mod)
  defp type_name(value) when is_map(value), do: "map"
  defp type_name(value) when is_list(value), do: "list"
  defp type_name(_value), do: "term"
end
