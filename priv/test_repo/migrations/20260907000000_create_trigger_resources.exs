# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.TestRepo.Migrations.CreateTriggerResources do
  @moduledoc """
  Tenant-scoped tables for the triggers extension resources:
  Subscription (TRD §4.1), Cursor (§4.2) and Dispatch (§4.3).

  Same shape as the tenant BPMN tables: `organization_id` added and every
  unique index gains the tenant column. The dispatch identities are **partial**
  unique indexes — the nil side must not participate, because Postgres treats
  NULLs as distinct and an unqualified unique index would dedupe nothing on a
  catch delivery.
  """

  use Ecto.Migration

  def up do
    create table(:tenant_bpmn_subscriptions, primary_key: false) do
      add(:id, :uuid, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:organization_id, :uuid, null: false)
      add(:key, :text, null: false)
      add(:version, :integer, null: false)
      add(:status, :text, null: false, default: "draft")
      add(:enabled, :boolean, null: false, default: true)
      add(:source, :text, null: false, default: "standalone")
      add(:definition_id, :uuid)
      add(:node_id, :text)
      add(:match_resource, :text, null: false)
      add(:match_action, :text)
      add(:match_action_type, :text)
      add(:kind, :text, null: false, default: "message")
      add(:signal_name, :text)
      add(:guard_feel, :text)
      add(:subject_of, :text, null: false, default: "event.record_id")
      add(:correlation_key_feel, :text)
      add(:route_kind, :text, null: false, default: "static")
      add(:process_key, :text)
      add(:decision_key, :text)
      add(:variable_mapping, :map, default: %{})
      add(:max_starts_per_event, :integer, null: false, default: 1)
      add(:lookback_minutes, :integer, null: false, default: 0)
      add(:compiled, :map, default: nil)
      add(:inserted_at, :utc_datetime_usec, null: false)
      add(:updated_at, :utc_datetime_usec, null: false)
    end

    create unique_index(:tenant_bpmn_subscriptions, [:organization_id, :key, :version])

    create unique_index(:tenant_bpmn_subscriptions, [:organization_id, :key, :status],
             where: "status = 'draft'"
           )

    create index(:tenant_bpmn_subscriptions, [:organization_id, :match_resource])

    create table(:tenant_bpmn_cursors, primary_key: false) do
      add(:id, :uuid, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:organization_id, :uuid, null: false)
      add(:last_sequence, :integer, null: false, default: 0)
      add(:last_dispatched_at, :utc_datetime_usec)
      add(:inserted_at, :utc_datetime_usec, null: false)
      add(:updated_at, :utc_datetime_usec, null: false)
    end

    # One cursor per tenant, enforced by the database rather than by the
    # sweeper remembering.
    create unique_index(:tenant_bpmn_cursors, [:organization_id])

    create table(:tenant_bpmn_dispatches, primary_key: false) do
      add(:id, :uuid, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:organization_id, :uuid, null: false)
      add(:subscription_id, :uuid)
      add(:waiting_token_id, :uuid)
      add(:event_id, :uuid, null: false)
      add(:event_sequence, :bigint, null: false)
      add(:event_occurred_at, :utc_datetime_usec, null: false)
      add(:kind, :text, null: false)
      add(:status, :text, null: false)
      add(:reason, :text)
      add(:process_key, :text)
      add(:instance_id, :uuid)
      add(:decision_key, :text)
      add(:fired_rule, :text)
      add(:correlation_id, :text)
      add(:depth, :integer, null: false, default: 0)
      add(:inserted_at, :utc_datetime_usec, null: false)
      add(:updated_at, :utc_datetime_usec, null: false)
    end

    # Both sides of G-1, partial so the nil side never participates.
    create unique_index(:tenant_bpmn_dispatches, [:organization_id, :subscription_id, :event_id],
             where: "subscription_id IS NOT NULL"
           )

    create unique_index(:tenant_bpmn_dispatches, [:organization_id, :waiting_token_id, :event_id],
             where: "waiting_token_id IS NOT NULL"
           )

    create index(:tenant_bpmn_dispatches, [:organization_id, :event_sequence])
  end

  def down do
    drop(table(:tenant_bpmn_dispatches))
    drop(table(:tenant_bpmn_cursors))
    drop(table(:tenant_bpmn_subscriptions))
  end
end
