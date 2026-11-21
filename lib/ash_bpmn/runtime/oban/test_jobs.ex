# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.Runtime.Oban.TestJobs do
  @moduledoc """
  ETS-backed storage for scheduled jobs in inline test mode.

  Inline mode executes immediate jobs synchronously and *stores* scheduled ones, because a test
  that ran a four-hour escalation the instant it was armed would prove nothing. This is where
  the stored ones live until a test decides to fire them.

  ## There is no clock here, and that used to mean there was no time at all

  `fire!/2` matches on kind and task id and **never looks at `scheduled_at`**. That is fine for
  "make the escalation happen now", and it is the reason a bug in how a timer's instant is
  computed was invisible to the whole suite: a thirty-minute reminder scheduled thirty seconds
  or thirty days out fired identically, and no test anywhere asserted a `scheduled_at` value.

  `fire_due!/1` is the answer — a virtual clock. It fires everything due at or before a given
  instant, **in due order**, and leaves the rest stored. That makes "the reminder fires before
  the escalation" and "nothing fires early" ordinary assertions instead of impossible ones.
  """

  @table :ash_bpmn_test_jobs
  @owner :ash_bpmn_test_jobs_owner

  @doc """
  Ensures the ETS table exists. Called from insert_inline.

  Safe to call from any number of processes at once, and the table outlives the caller.

  An ETS table dies with the process that created it. This used to create the table in
  whichever process stored the first timer, usually a test process or a LiveView, so the
  table vanished when that test ended and took every job other tests had stored with it.
  It also checked for the table and then created it, so two async tests storing their first
  timers at the same moment raised "table name already exists".

  The table is now created by a small process registered as `#{inspect(@owner)}` that holds
  it for the life of the VM. Inline mode runs only in tests and has no supervision tree to
  join, so that process is unsupervised on purpose. A caller that loses the race to start it
  finds the winner's table and carries on.
  """
  def ensure_started do
    if :ets.whereis(@table) == :undefined, do: start_owner()
    :ok
  end

  defp start_owner do
    caller = self()
    ref = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        # Registering first makes the name the lock: only one process can hold it, so only
        # one ever creates the table. A process that cannot register lost the race.
        try do
          Process.register(self(), @owner)
        rescue
          ArgumentError -> exit(:normal)
        end

        :ets.new(@table, [:set, :public, :named_table])
        send(caller, {ref, :ready})
        hold_table()
      end)

    receive do
      {^ref, :ready} ->
        Process.demonitor(monitor, [:flush])

      {:DOWN, ^monitor, :process, ^pid, _reason} ->
        await_owner()
    end
  end

  # The owner answers only once it has created the table, because it registers before it
  # creates it and reads its mailbox after.
  defp hold_table do
    receive do
      {:ready?, from, ref} ->
        send(from, {ref, :ready})
        hold_table()

      :stop ->
        :ok
    end
  end

  # Lost the race: ask the winner, which answers once its table exists.
  defp await_owner do
    monitor = Process.monitor(@owner)
    send(@owner, {:ready?, self(), monitor})

    receive do
      {^monitor, :ready} ->
        Process.demonitor(monitor, [:flush])
        :ok

      {:DOWN, ^monitor, :process, _, reason} ->
        raise "the #{inspect(@owner)} process exited before creating #{inspect(@table)}: " <>
                inspect(reason)
    end
  end

  @doc "Stores a timer job record."
  def store(record) do
    ensure_started()
    :ets.insert(@table, {record.id, record})
    :ok
  end

  @doc """
  Removes every stored job whose `meta` contains `match`, and reports how many.

  The inline counterpart of `AshBpmn.Runtime.Oban.cancel_all/1`, so cancel-by-owner behaves the
  same shape in tests as the indexed `meta @> ...` query does in production.
  """
  @spec remove_matching(map()) :: {:ok, non_neg_integer()}
  def remove_matching(match) when is_map(match) do
    ensure_started()

    wanted = Map.new(match, fn {k, v} -> {to_string(k), v} end)

    removed =
      all()
      |> Enum.filter(fn record ->
        meta = Map.new(record[:meta] || %{}, fn {k, v} -> {to_string(k), v} end)
        Enum.all?(wanted, fn {k, v} -> Map.get(meta, k) == v end)
      end)
      |> Enum.map(fn record -> remove(record.id) end)
      |> length()

    {:ok, removed}
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
  Fires every stored job due at or before `now`, oldest first, and returns how many ran.

  The virtual clock. Without it, inline mode has no notion of time passing: `fire!/2` names a
  job and runs it whenever you ask, so ordering between two timers on the same task, and the
  question of whether a timer was scheduled for the right instant at all, are both untestable.

  Jobs not yet due are left stored, which is the half that makes "nothing fired early" an
  assertion rather than a hope.
  """
  @spec fire_due!(DateTime.t()) :: non_neg_integer()
  def fire_due!(now \\ DateTime.utc_now()) do
    ensure_started()

    due =
      all()
      |> Enum.filter(fn record ->
        case record[:scheduled_at] do
          nil -> true
          at -> DateTime.compare(at, now) != :gt
        end
      end)
      # Due order, not insertion order: a reminder armed after an escalation but due before it
      # must still fire first, and insertion order would hide that.
      |> Enum.sort_by(& &1.scheduled_at, DateTime)

    Enum.each(due, fn record ->
      remove(record.id)
      run!(record)
    end)

    length(due)
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

      run!(record)
    else
      raise "No timer job found for kind=#{inspect(kind)} task_id=#{inspect(task_id)}"
    end
  end

  # Every shape `Oban.Worker.perform/1` may legally return. A timer that snoozes or cancels
  # itself is ordinary -- "not due yet, check again" is the natural idiom for a catch that is
  # still waiting -- and used to raise `CaseClauseError` here, which made it untestable.
  defp run!(record) do
    job = %Oban.Job{
      id: record.id,
      args: record.args,
      scheduled_at: record[:scheduled_at],
      meta: record[:meta] || %{}
    }

    case record.worker.perform(job) do
      :ok ->
        :ok

      {:ok, _} ->
        :ok

      :discard ->
        :ok

      {:discard, _} ->
        :ok

      {:cancel, _} ->
        :ok

      {:snooze, _seconds} ->
        :ok

      {:error, reason} ->
        raise "#{inspect(record.worker)} returned {:error, #{inspect(reason)}}"
    end
  end
end
