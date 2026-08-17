# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.Runtime.Oban.TestJobs do
  @moduledoc """
  ETS-backed storage for timer jobs in inline test mode.

  Provides `all/0`, `fire!/2`, `clear/0`, and `ensure_started/0`.
  The table is a public named ETS table created on first use.
  """

  @table :ash_bpmn_test_jobs

  @doc "Ensures the ETS table exists. Called from insert_inline."
  def ensure_started do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:set, :public, :named_table])
    end

    :ok
  end

  @doc "Stores a timer job record."
  def store(record) do
    ensure_started()
    :ets.insert(@table, {record.id, record})
    :ok
  end

  @doc "Removes a job by id."
  def remove(job_id) do
    ensure_started()
    :ets.delete(@table, job_id)
    :ok
  end

  @doc "Returns all stored timer jobs."
  @spec all() :: [map()]
  def all do
    ensure_started()

    :ets.tab2list(@table)
    |> Enum.map(fn {_id, record} -> record end)
    |> Enum.sort_by(& &1.id)
  end

  @doc "Clears all stored timer jobs."
  def clear do
    ensure_started()
    :ets.delete_all_objects(@table)
    :ok
  end

  @doc """
  Fires a stored timer job by kind and task_id.

  Finds the first matching stored job, calls its worker's `perform/1`,
  and removes it from storage.
  """
  @spec fire!(String.t(), String.t()) :: :ok | no_return()
  def fire!(kind, task_id) do
    ensure_started()

    record =
      :ets.tab2list(@table)
      |> Enum.map(fn {_id, rec} -> rec end)
      |> Enum.find(fn rec ->
        is_map(rec.args) and
          rec.args["kind"] == kind and
          rec.args["task_id"] == task_id
      end)

    if record do
      remove(record.id)

      job = %Oban.Job{id: record.id, args: record.args}

      case record.worker.perform(job) do
        :ok ->
          :ok

        {:ok, _} ->
          :ok

        {:discard, _} ->
          :ok

        {:error, reason} ->
          raise "TimerWorker #{record.worker} returned {:error, #{inspect(reason)}}"
      end
    else
      raise "No timer job found for kind=#{inspect(kind)} task_id=#{inspect(task_id)}"
    end
  end
end
