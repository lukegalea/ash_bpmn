# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.TestRepo.Migrations.AddSubjectPropertyIds do
  @moduledoc "A list of scalars for the multi-instance tests to fan out over."

  use Ecto.Migration

  def up do
    alter table(:bpmn_test_subjects) do
      add :property_ids, {:array, :text}, null: false, default: fragment("'{}'")
    end
  end

  def down do
    alter table(:bpmn_test_subjects), do: remove(:property_ids)
  end
end
