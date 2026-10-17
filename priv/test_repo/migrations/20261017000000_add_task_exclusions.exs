# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.TestRepo.Migrations.AddTaskExclusions do
  @moduledoc """
  The principals maker-checker subtracted from a task's candidate set.

  Their candidate rows were never written; the ids are kept on the task as well so that,
  once team candidates can claim, an excluded person cannot act through a candidate team
  they belong to. See `AshBpmn.Candidacy`. Existing rows get `{}`: their exclusions were
  not recorded, and the rows that subtraction removed stay removed.
  """

  use Ecto.Migration

  def up do
    for table <- [:bpmn_human_tasks, :tenant_bpmn_human_tasks] do
      alter table(table) do
        add :excluded_principal_ids, {:array, :uuid}, null: false, default: fragment("'{}'")
      end
    end
  end

  def down do
    for table <- [:bpmn_human_tasks, :tenant_bpmn_human_tasks] do
      alter table(table), do: remove(:excluded_principal_ids)
    end
  end
end
