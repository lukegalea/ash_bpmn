# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.Test.DecisionResolver do
  @moduledoc """
  Test double for `AshBpmn.DecisionResolver`.

  Deliberately a *table*, not a function that computes something. The point of the seam is
  that this package does not know what a decision is, so the double should not pretend to
  either: it looks a reference up and returns whatever was registered for it, which is exactly
  as much as the engine is entitled to assume.

  It also implements the twenty-line-host case the behaviour's moduledoc claims is possible,
  and so acts as a check on that claim.
  """

  @behaviour AshBpmn.DecisionResolver

  @table :ash_bpmn_test_decisions

  @doc "Registers a decision. `fun` receives the inputs and returns the result map."
  def register(ref, fun) when is_function(fun, 1) do
    ensure_table()
    :ets.insert(@table, {ref, fun})
    :ok
  end

  @doc "Forgets every registered decision. Call between tests."
  def reset do
    ensure_table()
    :ets.delete_all_objects(@table)
    :ok
  end

  @impl true
  def decide(ref, inputs, _context) do
    case lookup(ref) do
      {:ok, fun} -> {:ok, fun.(inputs)}
      :error -> {:error, {:no_such_decision, ref}}
    end
  end

  @impl true
  def exists?(ref) do
    match?({:ok, _}, lookup(ref))
  end

  defp lookup(ref) do
    ensure_table()

    case :ets.lookup(@table, ref) do
      [{^ref, fun}] -> {:ok, fun}
      [] -> :error
    end
  end

  defp ensure_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set])
    end
  rescue
    ArgumentError -> :ok
  end
end
