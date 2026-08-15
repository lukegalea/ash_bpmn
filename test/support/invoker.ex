# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.Test.Invoker do
  @moduledoc """
  Test double for `AshBpmn.ActionInvoker`.

  Records invoked action names in an ETS table (`:ash_bpmn_test_calls`) and
  returns `:ok`.  Tests can assert which actions were invoked by inspecting
  the table.

  Implements the `AshBpmn.ActionInvoker` callback signature (without the
  `@behaviour` annotation, which requires Lane C's module to be compiled).
  """

  @table :ash_bpmn_test_calls

  @doc """
  Invokes an action, recording the call.

  Callback: `invoke(action :: String.t(), ctx :: map()) ::
              :ok | {:ok, map()} | {:error, term()}`
  """
  def invoke(action, _ctx) do
    if :ets.whereis(@table) != :undefined do
      :ets.insert(@table, {System.unique_integer([:positive]), action, DateTime.utc_now()})
    end

    :ok
  end

  @doc "Returns all recorded invocations (list of `{id, action, timestamp}` tuples)."
  def recorded_calls do
    if :ets.whereis(@table) != :undefined do
      :ets.tab2list(@table) |> Enum.sort_by(&elem(&1, 0))
    else
      []
    end
  end

  @doc "Clears all recorded invocations."
  def clear_calls do
    if :ets.whereis(@table) != :undefined do
      :ets.delete_all_objects(@table)
    end

    :ok
  end
end
