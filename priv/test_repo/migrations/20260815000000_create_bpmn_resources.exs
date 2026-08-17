# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.TestRepo.Migrations.CreateBpmnResources do
  @moduledoc false

  use Ecto.Migration

  def up do
    create table(:bpmn_definitions, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
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

    create unique_index(:bpmn_definitions, [:key, :version])
    create unique_index(:bpmn_definitions, [:key, :status], where: "status = 'draft'")

    create table(:bpmn_instances, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
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

    create table(:bpmn_tokens, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :instance_id, :uuid, null: false
      add :node_id, :text, null: false
      add :status, :text, null: false, default: "active"
      add :parent_token_id, :uuid
      add :fork_id, :uuid
      add :attempts, :integer, null: false, default: 0
      add :inserted_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    create table(:bpmn_human_tasks, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
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

    create unique_index(:bpmn_human_tasks, [:subject_type, :subject_id, :node_id],
      where: "status IN ('open','claimed')"
    )

    create table(:bpmn_task_candidates, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :task_id, :uuid, null: false
      add :principal_type, :text, null: false
      add :principal_id, :uuid, null: false
      add :inserted_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    create unique_index(:bpmn_task_candidates, [:task_id, :principal_type, :principal_id])

    create table(:bpmn_process_events, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
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

    create table(:bpmn_test_subjects, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :name, :text, null: false
      add :amount, :integer, default: 0
      add :is_privileged, :boolean, default: false
      add :created_by_id, :uuid
      add :inserted_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end
  end

  def down do
    drop table(:bpmn_test_subjects)
    drop table(:bpmn_process_events)
    drop table(:bpmn_task_candidates)
    drop table(:bpmn_human_tasks)
    drop table(:bpmn_tokens)
    drop table(:bpmn_instances)
    drop table(:bpmn_definitions)
  end
end
