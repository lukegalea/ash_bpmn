# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.TestRepo.Migrations.RecipesDelivery do
  @moduledoc """
  The columns the delivery fixes need, on the test tables.

    * `tenant_bpmn_dispatches.error` -- what a funnel that raised said, on the `:failed` row
      the sweep writes for it.
    * The `(subscription_id, event_id)` identity no longer counts `:failed` rows, so a failed
      event can be driven again while a second start stays impossible.
    * `tenant_bpmn_subscriptions.effective_sequence` / `retired_sequence` -- the event window a
      version is in force for, stamped when a later version supersedes it.

  A host generates the same change from the resource macros with `mix ash.codegen`.
  """

  use Ecto.Migration

  def up do
    alter table(:tenant_bpmn_dispatches), do: add(:error, :text)

    drop index(:tenant_bpmn_dispatches, [:organization_id, :subscription_id, :event_id])

    create unique_index(:tenant_bpmn_dispatches, [:organization_id, :subscription_id, :event_id],
             where: "subscription_id IS NOT NULL AND status <> 'failed'"
           )

    alter table(:tenant_bpmn_subscriptions) do
      add(:effective_sequence, :bigint)
      add(:retired_sequence, :bigint)
    end
  end

  def down do
    alter table(:tenant_bpmn_subscriptions) do
      remove(:effective_sequence)
      remove(:retired_sequence)
    end

    drop index(:tenant_bpmn_dispatches, [:organization_id, :subscription_id, :event_id])

    create unique_index(:tenant_bpmn_dispatches, [:organization_id, :subscription_id, :event_id],
             where: "subscription_id IS NOT NULL"
           )

    alter table(:tenant_bpmn_dispatches), do: remove(:error)
  end
end
