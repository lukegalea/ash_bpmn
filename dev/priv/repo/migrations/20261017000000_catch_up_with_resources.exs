# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmnDev.Repo.Migrations.CatchUpWithResources do
  @moduledoc """
  Brings the demo's tables up to the resources they back.

  The library's own test schema gained these columns one migration at a time
  (`priv/test_repo/migrations`: the waiting-token state, an instance's trigger
  depth, the call-activity parent link, supersession). The demo's migrations
  were never given the same steps, so on a fresh database `mix dev.setup`
  failed in the seeds (`column b0.parent_instance_id does not exist`) and
  `/instances` returned 500. This is those steps, for the demo's tables only:
  the demo has no tenant-scoped resources, no timer ledger and no signal log.

  Hand-written, like every migration in this repository: the resources here are
  instantiated by macro and carry no codegen snapshots to diff against.
  """

  use Ecto.Migration

  @instance_columns [
    {:parent_instance_id, :uuid},
    {:parent_token_id, :uuid},
    {:superseded_by_instance_id, :uuid},
    {:superseded_at, :utc_datetime_usec}
  ]

  @token_columns [
    {:parked_at, :utc_datetime_usec},
    {:correlation_key, :text},
    {:subscription_signature, :text},
    {:lookback_until, :utc_datetime_usec}
  ]

  def up do
    alter table(:bpmn_instances) do
      add :trigger_depth, :integer, null: false, default: 0

      for {name, type} <- @instance_columns do
        add name, type
      end
    end

    create index(:bpmn_instances, [:parent_token_id], name: "bpmn_instances_parent_token_index")

    create index(:bpmn_instances, [:superseded_by_instance_id],
             where: "superseded_by_instance_id IS NOT NULL",
             name: "bpmn_instances_superseded_by_index"
           )

    alter table(:bpmn_tokens) do
      for {name, type} <- @token_columns do
        add name, type
      end
    end

    create index(:bpmn_tokens, [:subscription_signature, :instance_id],
             where: "status = 'waiting'",
             name: "bpmn_tokens_waiting_index"
           )
  end

  def down do
    drop index(:bpmn_tokens, [:subscription_signature, :instance_id],
           name: "bpmn_tokens_waiting_index"
         )

    alter table(:bpmn_tokens) do
      for {name, _type} <- @token_columns do
        remove name
      end
    end

    drop index(:bpmn_instances, [:superseded_by_instance_id],
           name: "bpmn_instances_superseded_by_index"
         )

    drop index(:bpmn_instances, [:parent_token_id], name: "bpmn_instances_parent_token_index")

    alter table(:bpmn_instances) do
      remove :trigger_depth

      for {name, _type} <- @instance_columns do
        remove name
      end
    end
  end
end
