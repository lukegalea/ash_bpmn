# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.TestRepo.Migrations.AddTaskFollowUpAt do
  @moduledoc """
  A task's follow-up date, and an index for the `:overdue` read (DESIGN.md §11.5).

  `follow_up_at` is written when the task is created, from `<ash:schedule followUp/>` or a
  `RequireApproval` change's `follow_up_in`. Existing rows get NULL: no follow-up date was
  declared for them. The index is partial, over live tasks only, as the `:overdue` read is.
  A host gets both from `mix ash.codegen`.
  """

  use Ecto.Migration

  def up do
    for table <- [:bpmn_human_tasks, :tenant_bpmn_human_tasks] do
      alter table(table) do
        add :follow_up_at, :utc_datetime_usec
      end

      create index(table, [:due_at], where: "status IN ('open','claimed')")
    end
  end

  def down do
    for table <- [:bpmn_human_tasks, :tenant_bpmn_human_tasks] do
      drop index(table, [:due_at])
      alter table(table), do: remove(:follow_up_at)
    end
  end
end
