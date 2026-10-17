# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmnDev.Repo.Migrations.AddTaskExclusions do
  @moduledoc """
  The principals maker-checker subtracted from a task's candidate set. See the equivalent
  migration under `priv/test_repo/migrations` and `AshBpmn.Candidacy`.
  """

  use Ecto.Migration

  def up do
    alter table(:bpmn_human_tasks) do
      add :excluded_principal_ids, {:array, :uuid}, null: false, default: fragment("'{}'")
    end
  end

  def down do
    alter table(:bpmn_human_tasks), do: remove(:excluded_principal_ids)
  end
end
