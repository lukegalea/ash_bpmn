# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.Test.Invoker do
  @moduledoc """
  Test double for `AshBpmn.ActionInvoker`.

  Records invoked action names in an ETS table (`:ash_bpmn_test_calls`) and,
  by default, returns `:ok`.  Tests can assert which actions were invoked by
  inspecting the table, and can stage a result (or an exception) for the next
  invocations with `set_result/1`.

  The `ctx` each invocation received is recorded separately
  (`recorded_ctxs/0`), so tests can assert what the engine passed without
  changing the shape `recorded_calls/0` has always returned.

  Implements the `AshBpmn.ActionInvoker` callback signature (without the
  `@behaviour` annotation, which requires Lane C's module to be compiled).
  """

  @table :ash_bpmn_test_calls
  @result_table :ash_bpmn_test_invoker_result
  @ctx_table :ash_bpmn_test_invoker_ctxs

  @doc """
  Invokes an action, recording the call and the ctx it received, then returns
  the staged result (default `:ok`).

  Callback: `invoke(action :: String.t(), ctx :: map()) ::
              :ok | {:ok, map()} | {:error, term()}`
  """
  def invoke(action, ctx) do
    ensure_result_table()

    if :ets.whereis(@table) != :undefined do
      :ets.insert(@table, {System.unique_integer([:positive]), action, DateTime.utc_now()})
      :ets.insert(@ctx_table, {System.unique_integer([:positive]), action, ctx})
    end

    current_result()
  end

  @doc """
  Stages what `invoke/2` returns from now on. Pass `:ok` (the default), an
  `{:ok, map()}` tuple, an `{:error, term()}` tuple, or an exception struct
  to raise.
  """
  def set_result(:ok), do: store(:ok)
  def set_result({:ok, map} = value) when is_map(map), do: store(value)
  def set_result({:error, _reason} = value), do: store(value)

  def set_result(%{__struct__: _} = exception), do: store({:__raise__, exception})

  @doc "Returns all recorded invocations (list of `{id, action, timestamp}` tuples)."
  def recorded_calls do
    if :ets.whereis(@table) != :undefined do
      :ets.tab2list(@table) |> Enum.sort_by(&elem(&1, 0))
    else
      []
    end
  end

  @doc "Returns all recorded ctxs (list of `{id, action, ctx}` tuples), oldest first."
  def recorded_ctxs do
    if :ets.whereis(@ctx_table) != :undefined do
      :ets.tab2list(@ctx_table) |> Enum.sort_by(&elem(&1, 0))
    else
      []
    end
  end

  @doc "Clears all recorded invocations, ctxs and staged results."
  def clear_calls do
    if :ets.whereis(@table) != :undefined do
      :ets.delete_all_objects(@table)
    end

    if :ets.whereis(@ctx_table) != :undefined do
      :ets.delete_all_objects(@ctx_table)
    end

    reset_result()
  end

  defp store(value) do
    ensure_result_table()
    :ets.insert(@result_table, {:result, value})
    :ok
  end

  defp current_result do
    ensure_result_table()

    case :ets.lookup(@result_table, :result) do
      [{:result, :ok}] -> :ok
      [{:result, {:ok, map}}] when is_map(map) -> {:ok, map}
      [{:result, {:error, reason}}] -> {:error, reason}
      [{:result, {:__raise__, exception}}] -> raise exception
      [] -> :ok
    end
  end

  defp reset_result do
    ensure_result_table()
    :ets.delete_all_objects(@result_table)
    :ok
  end

  defp ensure_result_table do
    if :ets.whereis(@result_table) == :undefined do
      :ets.new(@result_table, [:named_table, :public, :set])
    end

    if :ets.whereis(@ctx_table) == :undefined do
      :ets.new(@ctx_table, [:named_table, :public, :set])
    end

    :ok
  end
end

defmodule AshBpmn.Test.VerifyingInvoker do
  @moduledoc """
  An `ActionInvoker` double that also exports `exists?/1`, so the compiler's
  publish-time action verification has something real to ask.

  Known actions are registered by ref; when `:raise` is registered, `exists?/1`
  raises, exercising the compiler's fail-safe path.
  """

  @table :ash_bpmn_test_actions

  @doc "Registers a known action ref, or `:raise` to make every lookup crash."
  def register(:raise) do
    ensure_table()
    :ets.insert(@table, {:raise, true})
    :ok
  end

  def register(ref) when is_binary(ref) do
    ensure_table()
    :ets.insert(@table, {ref, true})
    :ok
  end

  @doc "Forgets every registered action."
  def reset do
    ensure_table()
    :ets.delete_all_objects(@table)
    :ok
  end

  @doc "Callback: `exists?(action :: String.t()) :: boolean`."
  def exists?(ref) do
    ensure_table()

    if :ets.lookup(@table, :raise) != [] do
      raise "catalogue unavailable"
    end

    :ets.lookup(@table, ref) != []
  end

  @doc "Callback: `invoke/2`, a plain `:ok`."
  def invoke(_action, _ctx), do: :ok

  defp ensure_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set])
    end

    :ok
  end
end
