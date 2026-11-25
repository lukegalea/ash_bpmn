# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.Runtime.TimerLedger do
  @moduledoc false

  # The bookkeeping every timer path shares: its ledger row, its skip record, the guard a
  # firing checks against its own row, and the arming of a cycle's next repetition
  # (DESIGN.md §11.3, §11.4).
  #
  # Every function is a no-op on the ledger when the host has not installed
  # `AshBpmn.Resources.TimerJob`, which is a supported configuration. The keys and events do
  # not depend on it.

  require Ash.Query

  alias AshBpmn.Runtime.Oban
  alias AshBpmn.Runtime.TimerMoment
  alias AshBpmn.Scope

  @doc "Creates a ledger row, or returns nil when the ledger is not installed."
  def row(resources, scope, attrs) do
    if resources.timer_job && attrs.kind do
      resources.timer_job.create!(attrs, Scope.engine(scope))
    end
  end

  @doc """
  What a ledger row keeps of a timer's args. `"armed_at"` is the instant the timer was first
  armed, kept through every repetition and every reschedule: it is what a duration, and a cycle
  with no start, count from.
  """
  def data(args) do
    Map.take(args, ["key", "index", "repetition", "until", "late", "attached_to", "armed_at"])
  end

  @doc """
  When the timer on `row` was first armed: its `"armed_at"`, or, for a row armed before that
  was recorded, the row's own `inserted_at`.
  """
  def armed_at(%{data: %{"armed_at" => iso}} = row) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, at, _} -> at
      _ -> row.inserted_at
    end
  end

  def armed_at(row), do: row.inserted_at

  @doc """
  The firing's own ledger row, when the job carries its id and the ledger is installed.
  """
  def own_row(resources, args, scope) do
    case {resources.timer_job, args["timer_job_id"]} do
      {nil, _} ->
        nil

      {_, nil} ->
        nil

      {timer_job, id} ->
        timer_job
        |> Ash.Query.for_read(:read)
        |> Ash.Query.filter(id == ^id)
        |> Ash.read_one!(Scope.engine(scope))
    end
  end

  @doc """
  Whether this firing's ledger row says the timer was cancelled: rescheduled, claimed, ended
  with its task. Oban's cancel is best-effort against a job already promoted, so a firing that
  escaped its cancel finds out here and does nothing.
  """
  def cancelled?(resources, args, scope) do
    match?(%{status: :cancelled}, own_row(resources, args, scope))
  end

  @doc "Records a firing on its ledger row (by id, or the legacy lookup the caller supplies)."
  def record_fired(_resources, nil, _scope), do: :ok

  def record_fired(resources, row, scope) do
    if row.status == :scheduled, do: resources.timer_job.record_fired(row, Scope.engine(scope))
    :ok
  end

  @doc """
  Writes the `:timer_skipped` event for `count` repetitions that were past when they came to
  be armed. One event, however many were missed (DESIGN.md §11.3).
  """
  def skipped!(resources, scope, event, args, count, due_at) do
    resources.process_event.create!(
      Map.merge(event, %{
        kind: :timer_skipped,
        data: %{
          "timer_kind" => args["kind"] || "boundary",
          "key" => args["key"],
          "repetition" => args["repetition"],
          "due_at" => due_at && DateTime.to_iso8601(due_at),
          "reason" => "past",
          "count" => count
        }
      }),
      Scope.engine(scope)
    )
  end

  @doc """
  Cancels the scheduled ledger rows that match `filter` (a keyword of equality filters)
  with `reason`.
  """
  def cancel_rows(resources, filter, reason, scope) do
    if resources.timer_job do
      resources.timer_job
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(status == :scheduled)
      |> Ash.Query.do_filter(filter)
      |> Ash.read!(Scope.engine(scope))
      |> Enum.each(&resources.timer_job.record_cancelled(&1, reason, Scope.engine(scope)))
    end

    :ok
  end

  @doc """
  The boundary timers a token's activity armed, cancelled in Oban and on the ledger, because
  the activity has ended.
  """
  def cancel_boundaries(resources, token_id, reason, scope) do
    {:ok, count} = Oban.cancel_all(%{"token_id" => token_id, "kind" => "boundary"})
    cancel_rows(resources, [token_id: token_id, kind: :boundary], reason, scope)
    {:ok, count}
  end

  @doc """
  Arms the repetition after the one just fired, if the cycle has one left.

  `owner` says what the timer belongs to: `{:task, task}` or `{:boundary, token}`. The next
  repetition at or after now is armed; any between are missed and recorded as one
  `:timer_skipped` event. An earlier delivery of this same firing may already have armed the
  next repetition: it is replaced, not doubled, because both carry the same key.

  Returns the new Oban job id, or nil when nothing was armed.
  """
  def arm_next(resources, owner, worker, args, scope) do
    %{"cycle" => cycle, "repetition" => repetition} = args
    next = TimerMoment.next_repetition(cycle, repetition + 1, DateTime.utc_now())
    {owner_id, node_id, index, event, meta, ledger} = owner_fields(owner, args)

    key = fn rep -> TimerMoment.key(owner_id, node_id, index, rep) end

    if next.missed > 0 do
      skipped!(
        resources,
        scope,
        event,
        Map.merge(args, %{"key" => key.(repetition + 1), "repetition" => repetition + 1}),
        next.missed,
        next[:last_due_at]
      )
    end

    case next.due_at do
      nil ->
        nil

      due_at ->
        next_key = key.(next.repetition)
        supersede(resources, next_key, ledger, scope)

        next_args =
          args
          |> Map.drop(["timer_job_id", "late", "missed", "skip"])
          |> Map.merge(%{
            "key" => next_key,
            "repetition" => next.repetition,
            "due_at" => DateTime.to_iso8601(due_at)
          })

        row = row(resources, scope, Map.merge(ledger, %{due_at: due_at, data: data(next_args)}))
        next_args = if row, do: Map.put(next_args, "timer_job_id", row.id), else: next_args

        {:ok, job} =
          Oban.insert(worker, Scope.to_job_args(scope, next_args),
            scheduled_at: due_at,
            meta: Oban.timer_meta(Map.put(meta, :key, next_key))
          )

        row && resources.timer_job.attach_job!(row, job.id, Scope.engine(scope))
        job.id
    end
  end

  defp owner_fields({:task, task}, args) do
    {task.id, task.node_id, args["index"],
     %{
       instance_id: task.instance_id,
       token_id: task.token_id,
       node_id: task.node_id,
       task_id: task.id
     }, %{task_id: task.id, kind: "task"},
     %{
       instance_id: task.instance_id,
       token_id: task.token_id,
       task_id: task.id,
       node_id: task.node_id,
       kind: timer_kind(args["kind"])
     }}
  end

  defp owner_fields({:boundary, token}, args) do
    boundary_id = args["boundary_id"]

    {token.id, args["attached_to"], boundary_id,
     %{instance_id: token.instance_id, token_id: token.id, node_id: boundary_id},
     %{token_id: token.id, kind: "boundary"},
     %{instance_id: token.instance_id, token_id: token.id, node_id: boundary_id, kind: :boundary}}
  end

  # A copy of the next repetition armed by an earlier delivery of the firing that is arming it
  # now. Cancelled in Oban by its key, and on the ledger as `:superseded`, so exactly one is
  # left.
  defp supersede(resources, key, ledger, scope) do
    Oban.cancel_all(%{"key" => key})

    if resources.timer_job do
      resources.timer_job
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(status == :scheduled and node_id == ^ledger.node_id)
      |> Ash.Query.do_filter(owner_filter(ledger))
      |> Ash.read!(Scope.engine(scope))
      |> Enum.filter(&(&1.data["key"] == key))
      |> Enum.each(&resources.timer_job.record_cancelled(&1, :superseded, Scope.engine(scope)))
    end
  end

  defp owner_filter(%{task_id: id}) when not is_nil(id), do: [task_id: id]
  defp owner_filter(%{token_id: id}), do: [token_id: id]

  @doc false
  # Mapped explicitly rather than through `String.to_existing_atom/1`: the kind arrives from
  # the diagram, and an unrecognized one loses its ledger row rather than failing the step.
  def timer_kind("remind"), do: :remind
  def timer_kind("escalate"), do: :escalate
  def timer_kind("expire"), do: :expire
  def timer_kind(_), do: nil
end
