# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.Runtime.Oban do
  @moduledoc """
  Oban shim — production delegates to real Oban; test mode runs inline.

  When `AshBpmn.Config.oban_testing() == :inline`:
    * `insert/3` without `scheduled_at` — executes `worker.perform/1` synchronously.
    * `unique:` is **not** honoured; see the comment on `insert_inline/3` for why
      implementing it would not make the only two callers testable.
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

  @doc """
  Cancels every pending job whose `meta` contains `match`.

  The answer to "cancel every timer this token owns" without keeping a second index of job
  ids. Oban stores `meta` as `jsonb` and ships a **GIN index on it**, so a containment lookup
  is indexed rather than a scan — which is why this is a query and not a stored id list.

  That matters more than it sounds. The existing id-list approach (`HumanTask.timer_job_ids`)
  has a window: the jobs are inserted, then the ids are written to the row, and a crash in
  between leaves live jobs that nothing can name. A `meta` query has no such window, because
  the identifying data is written *into the job itself*, in the same statement that creates it.

  Every timer this library inserts must therefore carry its owner in `meta`. A timer inserted
  without it is uncancellable by query, and becomes a ghost that fires against a token that
  moved on. `timer_meta/2` is the one constructor for that, and it exists so the invariant has
  a single place to hold.

  Only pending states are cancelled (`scheduled`, `available`, `retryable`): a job already
  running cannot be reliably stopped — Oban's kill signal is best-effort and loses the race
  when the job completes first — so the handler's own guard, not this call, is what keeps a
  fired timer from acting on a stale token.
  """
  @spec cancel_all(map()) :: {:ok, non_neg_integer()}
  def cancel_all(match) when is_map(match) and map_size(match) > 0 do
    if AshBpmn.Config.oban_testing() == :inline do
      AshBpmn.Runtime.Oban.TestJobs.remove_matching(match)
    else
      import Ecto.Query, only: [where: 3]

      Oban.Job
      |> where([j], j.state in ["scheduled", "available", "retryable"])
      |> where([j], fragment("? @> ?", j.meta, ^match))
      |> Oban.cancel_all_jobs()
    end
  end

  @doc """
  The `meta` every timer job must carry, so `cancel_all/1` can find it again.

  `kind` is included so a caller can cancel one kind of timer without touching the others --
  defusing an escalation while leaving a reminder armed, for instance.
  """
  @spec timer_meta(map()) :: map()
  def timer_meta(fields) when is_map(fields) do
    fields
    |> Map.new(fn {k, v} -> {to_string(k), v} end)
    |> Map.put("ash_bpmn", true)
  end

  # ── Inline mode ──────────────────────────────────────────────────────────

  # `unique:` is read by production and ignored here, and that is a limitation rather than an
  # oversight -- but it is one that has to be written down, because the obvious fix is worse
  # than the gap.
  #
  # Inline mode has no queue. An immediate job goes straight from insert to executed; it is
  # never `:available` and never `:scheduled`. Both callers that pass `unique:` restrict it to
  # exactly those states (`triggers/nudge.ex` and `triggers/sweep_worker.ex`), so a faithful
  # inline implementation would correctly dedupe nothing and the two tests anyone would write
  # against it -- "the second nudge inside five seconds is dropped" -- still could not pass.
  #
  # The trap is what comes next: faced with a test that will not go green, the temptation is
  # to widen the states until it does, at which point inline dedupes where production does
  # not and the suite is asserting a behaviour the system does not have. Better an
  # acknowledged blind spot than a green test for a fiction. The debounce is production
  # behaviour and needs a test with a real Oban queue behind it.
  defp insert_inline(worker_module, args, opts) do
    AshBpmn.Runtime.Oban.TestJobs.ensure_started()

    if Keyword.has_key?(opts, :scheduled_at) do
      # Timer — store, do NOT execute
      id = System.unique_integer([:positive])
      scheduled_at = Keyword.get(opts, :scheduled_at)
      meta = Keyword.get(opts, :meta, %{})

      job = %Oban.Job{
        id: id,
        args: args,
        scheduled_at: scheduled_at,
        worker: worker_module,
        meta: meta
      }

      # `meta` is carried through deliberately. It is what `cancel_all/1` matches on, so a
      # store that dropped it would make cancel-by-owner work in production and silently do
      # nothing in tests -- the worst possible split, because the tests would still be green.
      AshBpmn.Runtime.Oban.TestJobs.store(%{
        id: id,
        worker: worker_module,
        args: args,
        scheduled_at: scheduled_at,
        meta: meta
      })

      {:ok, job}
    else
      # Immediate — execute synchronously
      id = System.unique_integer([:positive])
      job = %Oban.Job{id: id, args: args}

      # Every shape `Oban.Worker.perform/1` is allowed to return, because a worker that snoozes
      # or cancels itself is ordinary and used to crash the suite with a `CaseClauseError` --
      # which made "check again later", the natural idiom for a timer whose condition has not
      # arrived, untestable.
      case worker_module.perform(job) do
        :ok ->
          {:ok, job}

        {:ok, _result} ->
          {:ok, job}

        :discard ->
          {:ok, job}

        {:discard, _reason} ->
          {:ok, job}

        {:cancel, _reason} ->
          {:ok, job}

        # Inline mode has no clock to snooze against. Recording it rather than re-running keeps
        # the call total and lets a test assert the worker asked to be retried.
        {:snooze, seconds} ->
          {:ok, %{job | meta: Map.put(job.meta || %{}, "snoozed_for", seconds)}}

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

    case Oban.insert(changeset) do
      # The unique-insert trap, and it is a quiet one.
      #
      # `insert_unique` takes `pg_try_advisory_xact_lock` to serialize the conflict check. When
      # that lock is *not* granted, Oban does not error -- it applies the changeset in memory
      # and hands back `{:ok, %Job{conflict?: true, id: nil}}`. No row was written. A caller
      # that reads `{:ok, _}` as "the job is armed" silently loses it, and for a timer that
      # means a token waits forever for something that was never scheduled.
      #
      # A non-nil id with `conflict?: true` is the ordinary dedupe outcome and is a success --
      # that is the nudge's debounce doing its job.
      {:ok, %Oban.Job{id: nil, conflict?: true}} ->
        {:error,
         {:not_inserted,
          "unique insert for #{inspect(worker_module)} could not take the advisory lock; " <>
            "no row was written"}}

      other ->
        other
    end
  end
end
