# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.TestRepo.Migrations.CreateSignals do
  @moduledoc """
  The signal log, in both the non-tenant and tenant shapes.

  Indexed on `(name, emitted_at)` because that is the only way signals are ever read: a
  subscription hears one name, and the sweep works forward from a cursor over recent history.
  Nothing queries a signal's payload and nothing looks up a signal by id except a dispatch row
  that already has it.
  """

  use Ecto.Migration

  def up do
    create table(:bpmn_signals, primary_key: false) do
      add :id, :uuid, primary_key: true, null: false
      add :name, :text, null: false
      add :payload, :map, null: false, default: fragment("'{}'::jsonb")
      add :emitted_at, :utc_datetime_usec, null: false
      add :instance_id, :uuid
      add :node_id, :text
      add :depth, :integer, null: false, default: 0
    end

    create index(:bpmn_signals, [:name, :emitted_at], name: "bpmn_signals_name_index")

    create table(:tenant_bpmn_signals, primary_key: false) do
      add :id, :uuid, primary_key: true, null: false
      add :name, :text, null: false
      add :payload, :map, null: false, default: fragment("'{}'::jsonb")
      add :emitted_at, :utc_datetime_usec, null: false
      add :instance_id, :uuid
      add :node_id, :text
      add :depth, :integer, null: false, default: 0
      add :organization_id, :uuid, null: false
    end

    # Tenant-leading, because every read under attribute multitenancy carries the tenant and
    # an index that does not lead with it cannot serve one tenant without touching the others.
    create index(:tenant_bpmn_signals, [:organization_id, :name, :emitted_at],
             name: "tenant_bpmn_signals_name_index"
           )
  end

  def down do
    drop table(:tenant_bpmn_signals)
    drop table(:bpmn_signals)
  end
end
