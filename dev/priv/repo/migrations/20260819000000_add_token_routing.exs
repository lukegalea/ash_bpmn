# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmnDev.Repo.Migrations.AddTokenRouting do
  @moduledoc """
  Adds `routing` to the token table, for the signals a business rule task promotes.

  See the equivalent migration under `priv/test_repo/migrations` for why this is a new
  migration rather than an edit to the one that created the table.
  """

  use Ecto.Migration

  def up do
    alter table(:bpmn_tokens) do
      add :routing, :map, null: false, default: fragment("'{}'::jsonb")
    end
  end

  def down do
    alter table(:bpmn_tokens), do: remove(:routing)
  end
end
