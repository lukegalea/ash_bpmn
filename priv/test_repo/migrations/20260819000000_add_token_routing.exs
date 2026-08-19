# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.TestRepo.Migrations.AddTokenRouting do
  @moduledoc """
  Adds `routing` to the token tables, for the signals a business rule task promotes.

  A separate migration rather than an edit to the one that created the tables: that one has
  already run everywhere it is going to run, and editing an applied migration means the schema
  is whatever each database happened to be created from. This is also what a host adopting the
  new attribute will generate for itself.

  jsonb rather than a column per signal, because the signal names live in the diagram and not
  in the schema — the whole point of promoting them is that a modeller can add one without a
  deploy.
  """

  use Ecto.Migration

  def up do
    alter table(:bpmn_tokens) do
      add :routing, :map, null: false, default: fragment("'{}'::jsonb")
    end

    alter table(:tenant_bpmn_tokens) do
      add :routing, :map, null: false, default: fragment("'{}'::jsonb")
    end
  end

  def down do
    alter table(:bpmn_tokens), do: remove(:routing)
    alter table(:tenant_bpmn_tokens), do: remove(:routing)
  end
end
