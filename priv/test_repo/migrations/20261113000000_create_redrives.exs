# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.TestRepo.Migrations.CreateRedrives do
  @moduledoc """
  The re-drive ledger (`AshBpmn.Resources.Redrive`) on the tenant test tables. A host
  generates the same table from the resource macro with `mix ash.codegen`.
  """

  use Ecto.Migration

  def up do
    create table(:tenant_bpmn_redrives, primary_key: false) do
      add(:id, :uuid, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:organization_id, :uuid, null: false)
      add(:failed_dispatch_id, :uuid, null: false)
      add(:subscription_id, :uuid)
      add(:event_id, :uuid)
      add(:event_sequence, :bigint)
      add(:outcome, :text, null: false)
      add(:reason, :text)
      add(:dispatch_id, :uuid)
      add(:redriven_by_id, :uuid)
      add(:inserted_at, :utc_datetime_usec, null: false)
      add(:updated_at, :utc_datetime_usec, null: false)
    end

    create index(:tenant_bpmn_redrives, [:organization_id, :failed_dispatch_id])
  end

  def down do
    drop(table(:tenant_bpmn_redrives))
  end
end
