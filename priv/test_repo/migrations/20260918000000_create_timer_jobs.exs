# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.TestRepo.Migrations.CreateTimerJobs do
  @moduledoc """
  The timer ledger, in both its untenanted and tenant-scoped shapes.

  One row per timer the engine armed. It is an audit record over Oban and not a scheduler --
  see `AshBpmn.Resources.TimerJob` for why that distinction is the whole design. Nothing reads
  `due_at` to decide when to act; `Oban.Stager` does the waiting, as it already did.

  The table exists because Oban forgets. `Oban.Plugins.Pruner` deletes completed, cancelled and
  discarded jobs after `max_age`, and a cancelled Oban job never carried a reason for its
  cancellation in the first place. "Why did this escalation never fire?" is therefore
  unanswerable from `oban_jobs` a week later, and these rows are what survives.

  ## The indexes

  The query that matters is **"show me every timer that was cancelled without firing"**. Fired
  timers left a `:timer_fired` process event and usually a visible effect, so they are traceable
  from either end; still-scheduled timers are sitting in `oban_jobs` where anyone can look at
  them. Cancelled timers are the set with no other evidence anywhere, which is exactly why they
  are worth an index -- and they are a small minority of the rows, which is why the index is
  partial rather than over the whole table.

  `(task_id)` is the other direction: the forensic trail usually starts from a task somebody is
  looking at, and "what was armed here, and what became of it?" should not be a scan.

  The tenant copy leads with `organization_id`, for the same reason every tenant index in this
  schema does: every query under attribute multitenancy carries it, and a tenant-leading index
  is the one Postgres can use for a single tenant's cancelled timers without reading the others'.
  """

  use Ecto.Migration

  def up do
    create table(:bpmn_timer_jobs, primary_key: false) do
      add(:id, :uuid, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:instance_id, :uuid)
      add(:token_id, :uuid)
      add(:task_id, :uuid)
      add(:node_id, :text)
      add(:kind, :text, null: false)
      add(:due_at, :utc_datetime_usec, null: false)
      # bigint: Oban's job ids come from a bigserial, and a timer ledger outlives the jobs it
      # names -- so this column will still be receiving ids long after an int would have run out.
      add(:oban_job_id, :bigint)
      add(:status, :text, null: false, default: "scheduled")
      add(:fired_at, :utc_datetime_usec)
      add(:cancelled_at, :utc_datetime_usec)
      add(:cancel_reason, :text)
      add(:data, :map, default: %{})
      add(:inserted_at, :utc_datetime_usec, null: false)
      add(:updated_at, :utc_datetime_usec, null: false)
    end

    create(
      index(:bpmn_timer_jobs, [:due_at],
        where: "status = 'cancelled'",
        name: "bpmn_timer_jobs_cancelled_index"
      )
    )

    create(index(:bpmn_timer_jobs, [:task_id]))

    create table(:tenant_bpmn_timer_jobs, primary_key: false) do
      add(:id, :uuid, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:organization_id, :uuid, null: false)
      add(:instance_id, :uuid)
      add(:token_id, :uuid)
      add(:task_id, :uuid)
      add(:node_id, :text)
      add(:kind, :text, null: false)
      add(:due_at, :utc_datetime_usec, null: false)
      add(:oban_job_id, :bigint)
      add(:status, :text, null: false, default: "scheduled")
      add(:fired_at, :utc_datetime_usec)
      add(:cancelled_at, :utc_datetime_usec)
      add(:cancel_reason, :text)
      add(:data, :map, default: %{})
      add(:inserted_at, :utc_datetime_usec, null: false)
      add(:updated_at, :utc_datetime_usec, null: false)
    end

    create(
      index(:tenant_bpmn_timer_jobs, [:organization_id, :due_at],
        where: "status = 'cancelled'",
        name: "tenant_bpmn_timer_jobs_cancelled_index"
      )
    )

    create(index(:tenant_bpmn_timer_jobs, [:organization_id, :task_id]))
  end

  def down do
    drop(table(:tenant_bpmn_timer_jobs))
    drop(table(:bpmn_timer_jobs))
  end
end
