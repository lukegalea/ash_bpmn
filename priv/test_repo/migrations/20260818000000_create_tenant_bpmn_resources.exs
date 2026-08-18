# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.TestRepo.Migrations.CreateTenantBpmnResources do
  @moduledoc """
  A second, tenant-scoped copy of the BPMN tables.

  `tenant?: true` on the resource macros had never been exercised: the tables the
  suite ran against had no `organization_id` at all, so nothing could have caught
  `AshBpmn.start_instance/2` discarding the `:tenant` option it documented.

  These tables exist so that it can be. They are the same shape as their
  untenanted twins with `organization_id` added, and every unique index gains the
  tenant column -- otherwise one organization's open approval on a subject would
  block another organization's, which is a data leak wearing a constraint
  violation as a disguise.
  """

  use Ecto.Migration

  def up do
    create table(:tenant_bpmn_definitions, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :organization_id, :uuid, null: false
      add :key, :text, null: false
      add :name, :text, null: false
      add :version, :integer, null: false
      add :status, :text, null: false, default: "draft"
      add :xml, :text, null: false
      add :graph, :map, default: nil
      add :errors, {:array, :map}, default: []
      add :content_hash, :text, null: false
      add :inserted_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    create unique_index(:tenant_bpmn_definitions, [:organization_id, :key, :version])
    create unique_index(:tenant_bpmn_definitions, [:organization_id, :key, :status],
      where: "status = 'draft'"
    )

    create table(:tenant_bpmn_instances, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :organization_id, :uuid, null: false
      add :definition_id, :uuid, null: false
      add :subject_type, :text, null: false
      add :subject_id, :uuid, null: false
      add :correlation_id, :text
      add :status, :text, null: false, default: "running"
      add :started_by_id, :uuid
      add :outcome, :text
      add :inserted_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    create table(:tenant_bpmn_tokens, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :organization_id, :uuid, null: false
      add :instance_id, :uuid, null: false
      add :node_id, :text, null: false
      add :status, :text, null: false, default: "active"
      add :parent_token_id, :uuid
      add :fork_id, :uuid
      add :attempts, :integer, null: false, default: 0
      add :inserted_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    create table(:tenant_bpmn_human_tasks, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :organization_id, :uuid, null: false
      add :instance_id, :uuid
      add :token_id, :uuid
      add :node_id, :text, null: false
      add :name, :text, null: false
      add :status, :text, null: false, default: "open"
      add :assignee_type, :text
      add :assignee_id, :uuid
      add :claimed_at, :utc_datetime_usec
      add :due_at, :utc_datetime_usec
      add :outcome, :text
      add :decided_by_id, :uuid
      add :delegated_from_id, :uuid
      add :timer_job_ids, {:array, :integer}, default: []
      add :comment, :text
      add :on_complete, :map, default: %{}
      add :subject_type, :text
      add :subject_id, :uuid
      add :inserted_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    create unique_index(
      :tenant_bpmn_human_tasks,
      [:organization_id, :subject_type, :subject_id, :node_id],
      where: "status IN ('open','claimed')"
    )

    create table(:tenant_bpmn_task_candidates, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :organization_id, :uuid, null: false
      add :task_id, :uuid, null: false
      add :principal_type, :text, null: false
      add :principal_id, :uuid, null: false
      add :inserted_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    create unique_index(
      :tenant_bpmn_task_candidates,
      [:organization_id, :task_id, :principal_type, :principal_id]
    )

    create table(:tenant_bpmn_process_events, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :organization_id, :uuid, null: false
      add :instance_id, :uuid
      add :token_id, :uuid
      add :node_id, :text
      add :task_id, :uuid
      add :kind, :text, null: false
      add :data, :map, default: %{}
      add :recorded_at, :utc_datetime_usec, null: false
      add :inserted_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end
  end

  def down do
    drop table(:tenant_bpmn_process_events)
    drop table(:tenant_bpmn_task_candidates)
    drop table(:tenant_bpmn_human_tasks)
    drop table(:tenant_bpmn_tokens)
    drop table(:tenant_bpmn_instances)
    drop table(:tenant_bpmn_definitions)
  end
end
