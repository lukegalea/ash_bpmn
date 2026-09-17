# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.TestRepo.Migrations.AddTokenWaitingState do
  @moduledoc """
  Adds the parked-token columns and the partial index the correlator queries through.

  `status` itself needs no migration: it is a string column with the check living in Ash's
  `one_of` constraint rather than in Postgres, so adding `:waiting` to the allowed set is a
  resource change alone. That is worth stating because the absence of a schema change here
  looks like an omission otherwise.

  The index is the reason this migration exists at all. Waking a token means asking "which
  waiting tokens could this event be for?", and that question is asked once per matching
  event. Without an index it is a sequential scan over every token the system has ever
  created, the overwhelming majority of them long consumed. A partial index on
  `status = 'waiting'` is instead proportional to the number of tokens actually parked, which
  is a working set rather than a history.
  """

  use Ecto.Migration

  @waiting_columns [
    {:parked_at, :utc_datetime_usec},
    {:correlation_key, :text},
    {:subscription_signature, :text},
    {:lookback_until, :utc_datetime_usec}
  ]

  def up do
    for table <- [:bpmn_tokens, :tenant_bpmn_tokens] do
      alter table(table) do
        for {name, type} <- @waiting_columns do
          add name, type
        end
      end
    end

    # Signature first: it is the equality predicate, and the correlator always has one.
    create index(:bpmn_tokens, [:subscription_signature, :instance_id],
             where: "status = 'waiting'",
             name: "bpmn_tokens_waiting_index"
           )

    # The tenant copy leads with the tenant column, because every query under attribute
    # multitenancy carries it and a tenant-leading index is the one Postgres can use for a
    # single tenant's waiting set without scanning the others'.
    create index(:tenant_bpmn_tokens, [:organization_id, :subscription_signature, :instance_id],
             where: "status = 'waiting'",
             name: "tenant_bpmn_tokens_waiting_index"
           )
  end

  def down do
    drop index(:bpmn_tokens, [:subscription_signature, :instance_id],
           name: "bpmn_tokens_waiting_index"
         )

    drop index(:tenant_bpmn_tokens, [:organization_id, :subscription_signature, :instance_id],
           name: "tenant_bpmn_tokens_waiting_index"
         )

    for table <- [:bpmn_tokens, :tenant_bpmn_tokens] do
      alter table(table) do
        for {name, _type} <- @waiting_columns do
          remove name
        end
      end
    end
  end
end
