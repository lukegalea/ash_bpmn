# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.Runtime.Oban do
  @moduledoc """
  Oban shim — production delegates to real Oban; test mode runs inline.

  When `AshBpmn.Config.oban_testing() == :inline`:
    * `insert/3` without `scheduled_at` — executes `worker.perform/1` synchronously.
    * `insert/3` with `scheduled_at` — stores in TestJobs ETS table (does NOT execute).
    * `cancel_job/1` — removes from TestJobs.

  Production (`nil`) — delegates to real `Oban.insert/2` and `Oban.cancel_job/1`.

  Workers should `use Oban.Worker, queue: :dynamic` and override `queue/0` to
  call `AshBpmn.Config.queue/0` so queue name is read at runtime.
  """

  @doc """
  Inserts an Oban job.

  In inline mode:
    * Without `scheduled_at` — executes worker.perform/1 synchronously and returns {:ok, job}.
    * With `scheduled_at` — stores in TestJobs for later manual firing.

  In production mode — delegates to Oban.insert/2.
  """
  @spec insert(module(), map(), keyword()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def insert(worker_module, args, opts \\ []) do
    if AshBpmn.Config.oban_testing() == :inline do
      insert_inline(worker_module, args, opts)
    else
      insert_production(worker_module, args, opts)
    end
  end

  @doc "Cancels an Oban job by id."
  @spec cancel_job(integer()) :: :ok
  def cancel_job(job_id) do
    if AshBpmn.Config.oban_testing() == :inline do
      AshBpmn.Runtime.Oban.TestJobs.remove(job_id)
      :ok
    else
      Oban.cancel_job(job_id)
    end
  end

  # ── Inline mode ──────────────────────────────────────────────────────────

  defp insert_inline(worker_module, args, opts) do
    AshBpmn.Runtime.Oban.TestJobs.ensure_started()

    if Keyword.has_key?(opts, :scheduled_at) do
      # Timer — store, do NOT execute
      id = System.unique_integer([:positive])
      scheduled_at = Keyword.get(opts, :scheduled_at)
      job = %Oban.Job{id: id, args: args, scheduled_at: scheduled_at, worker: worker_module}

      AshBpmn.Runtime.Oban.TestJobs.store(%{
        id: id,
        worker: worker_module,
        args: args,
        scheduled_at: scheduled_at
      })

      {:ok, job}
    else
      # Immediate — execute synchronously
      id = System.unique_integer([:positive])
      job = %Oban.Job{id: id, args: args}

      case worker_module.perform(job) do
        :ok ->
          {:ok, job}

        {:ok, _result} ->
          {:ok, job}

        {:discard, _} ->
          {:ok, job}

        {:error, reason} ->
          raise "AshBpmn inline Oban worker #{inspect(worker_module)} returned {:error, #{inspect(reason)}}"
      end
    end
  end

  # ── Production mode ──────────────────────────────────────────────────────

  defp insert_production(worker_module, args, opts) do
    # The queue has to be supplied **here**, not left to the worker.
    #
    # `Oban.Worker.new/2` reads the queue from the worker's compile-time `use` options, and
    # these workers deliberately declare none so that `config :ash_bpmn, queue:` can decide.
    # Overriding the `queue/0` callback does not affect insertion -- so without this every job
    # landed on `:default`, the configured queue sat empty, and a host that had carefully given
    # process work its own queue got none of the isolation it configured.
    #
    # Silent, too: the jobs ran, just not where anyone was looking. Found by draining `:bpmn`
    # in a host application and getting nothing while processes were plainly advancing.
    opts = Keyword.put_new(opts, :queue, AshBpmn.Config.queue())

    changeset = worker_module.new(args, opts)
    Oban.insert(changeset)
  end
end
