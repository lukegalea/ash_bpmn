# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.TestRepo.Migrations.AddInstanceParent do
  @moduledoc """
  The parent link a call activity creates.

  Indexed on `parent_token_id` because that is how a completing child finds the token waiting
  for it, which happens once per child completion and must not scan.
  """

  use Ecto.Migration

  def up do
    for table <- [:bpmn_instances, :tenant_bpmn_instances] do
      alter table(table) do
        add :parent_instance_id, :uuid
        add :parent_token_id, :uuid
      end
    end

    create index(:bpmn_instances, [:parent_token_id], name: "bpmn_instances_parent_token_index")

    create index(:tenant_bpmn_instances, [:organization_id, :parent_token_id],
             name: "tenant_bpmn_instances_parent_token_index"
           )
  end

  def down do
    drop index(:bpmn_instances, [:parent_token_id], name: "bpmn_instances_parent_token_index")

    drop index(:tenant_bpmn_instances, [:organization_id, :parent_token_id],
           name: "tenant_bpmn_instances_parent_token_index"
         )

    for table <- [:bpmn_instances, :tenant_bpmn_instances] do
      alter table(table) do
        remove :parent_instance_id
        remove :parent_token_id
      end
    end
  end
end
