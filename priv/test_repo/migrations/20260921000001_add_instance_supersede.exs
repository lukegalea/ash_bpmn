# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.TestRepo.Migrations.AddInstanceSupersede do
  @moduledoc """
  The restart link: which instance took over an instance's work, and when.

  `status` itself needs no migration. It is a text column whose allowed values live in Ash's
  `one_of` constraint rather than in Postgres, so admitting `:superseded` is a resource change
  alone — worth saying, because the absence of a schema change for a new status reads like an
  omission otherwise.

  The index is partial and points *backwards*. The successor link is written on the instance
  that stopped, so "what was this instance restarted from?" is a reverse lookup, and unindexed
  that is a sequential scan of every instance the system has ever run. Restricted to the rows
  that actually carry a successor it is proportional to the number of restarts, which is a
  handful in any installation where restarts are the deliberate operator action they are meant
  to be.
  """

  use Ecto.Migration

  @columns [
    {:superseded_by_instance_id, :uuid},
    {:superseded_at, :utc_datetime_usec}
  ]

  def up do
    for table <- [:bpmn_instances, :tenant_bpmn_instances] do
      alter table(table) do
        for {name, type} <- @columns do
          add name, type
        end
      end
    end

    create index(:bpmn_instances, [:superseded_by_instance_id],
             where: "superseded_by_instance_id IS NOT NULL",
             name: "bpmn_instances_superseded_by_index"
           )

    # Tenant-leading, because every read on a tenant-scoped table carries the tenant and an
    # index that does not lead with it is an index the planner walks past.
    create index(:tenant_bpmn_instances, [:organization_id, :superseded_by_instance_id],
             where: "superseded_by_instance_id IS NOT NULL",
             name: "tenant_bpmn_instances_superseded_by_index"
           )
  end

  def down do
    drop index(:bpmn_instances, [:superseded_by_instance_id],
           name: "bpmn_instances_superseded_by_index"
         )

    drop index(:tenant_bpmn_instances, [:organization_id, :superseded_by_instance_id],
           name: "tenant_bpmn_instances_superseded_by_index"
         )

    for table <- [:bpmn_instances, :tenant_bpmn_instances] do
      alter table(table) do
        for {name, _type} <- @columns do
          remove name
        end
      end
    end
  end
end
