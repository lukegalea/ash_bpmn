# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

# A second instantiation of all six resource macros, this time with
# `tenant?: true`.
#
# Nothing exercised that option before. The macros generated an
# `organization_id` attribute and an attribute-multitenancy strategy, the tables
# the suite ran against had no such column, and `AshBpmn.start_instance/2` threw
# the `:tenant` option away -- three facts that were individually invisible and
# jointly meant the feature did not work.
#
# These modules deliberately carry **no policies of their own**, so the tenancy
# suite is also, incidentally, a test that the engine's own calls are recognised
# by the bypass the macros generate. A host would add its policies here.

defmodule AshBpmn.TenantTest.Definition do
  @moduledoc false
  use AshBpmn.Resources.Definition,
    domain: AshBpmn.TenantTest.Domain,
    repo: AshBpmn.TestRepo,
    table: "tenant_bpmn_definitions",
    tenant?: true
end

defmodule AshBpmn.TenantTest.Instance do
  @moduledoc false
  use AshBpmn.Resources.Instance,
    domain: AshBpmn.TenantTest.Domain,
    repo: AshBpmn.TestRepo,
    definition: AshBpmn.TenantTest.Definition,
    table: "tenant_bpmn_instances",
    tenant?: true
end

defmodule AshBpmn.TenantTest.Token do
  @moduledoc false
  use AshBpmn.Resources.Token,
    domain: AshBpmn.TenantTest.Domain,
    repo: AshBpmn.TestRepo,
    instance: AshBpmn.TenantTest.Instance,
    table: "tenant_bpmn_tokens",
    tenant?: true
end

defmodule AshBpmn.TenantTest.HumanTask do
  @moduledoc false
  use AshBpmn.Resources.HumanTask,
    domain: AshBpmn.TenantTest.Domain,
    repo: AshBpmn.TestRepo,
    instance: AshBpmn.TenantTest.Instance,
    token: AshBpmn.TenantTest.Token,
    task_candidate: AshBpmn.TenantTest.TaskCandidate,
    table: "tenant_bpmn_human_tasks",
    tenant?: true
end

defmodule AshBpmn.TenantTest.TaskCandidate do
  @moduledoc false
  use AshBpmn.Resources.TaskCandidate,
    domain: AshBpmn.TenantTest.Domain,
    repo: AshBpmn.TestRepo,
    task: AshBpmn.TenantTest.HumanTask,
    table: "tenant_bpmn_task_candidates",
    tenant?: true
end

defmodule AshBpmn.TenantTest.ProcessEvent do
  @moduledoc false
  use AshBpmn.Resources.ProcessEvent,
    domain: AshBpmn.TenantTest.Domain,
    repo: AshBpmn.TestRepo,
    instance: AshBpmn.TenantTest.Instance,
    table: "tenant_bpmn_process_events",
    tenant?: true
end

# The triggers extension's three resources, tenant-scoped — the version
# sequence is per key *within the tenant*, and the cursor is one row per
# tenant, so attribute multitenancy is not optional for these.
defmodule AshBpmn.TenantTest.TimerJob do
  @moduledoc false
  use AshBpmn.Resources.TimerJob,
    domain: AshBpmn.TenantTest.Domain,
    repo: AshBpmn.TestRepo,
    instance: AshBpmn.TenantTest.Instance,
    token: AshBpmn.TenantTest.Token,
    task: AshBpmn.TenantTest.HumanTask,
    table: "tenant_bpmn_timer_jobs",
    tenant?: true
end

defmodule AshBpmn.TenantTest.Signal do
  @moduledoc false
  use AshBpmn.Resources.Signal,
    domain: AshBpmn.TenantTest.Domain,
    repo: AshBpmn.TestRepo,
    table: "tenant_bpmn_signals",
    tenant?: true
end

defmodule AshBpmn.TenantTest.Subscription do
  @moduledoc false
  use AshBpmn.Resources.Subscription,
    domain: AshBpmn.TenantTest.Domain,
    repo: AshBpmn.TestRepo,
    table: "tenant_bpmn_subscriptions",
    tenant?: true
end

defmodule AshBpmn.TenantTest.Cursor do
  @moduledoc false
  use AshBpmn.Resources.Cursor,
    domain: AshBpmn.TenantTest.Domain,
    repo: AshBpmn.TestRepo,
    table: "tenant_bpmn_cursors",
    tenant?: true
end

defmodule AshBpmn.TenantTest.Dispatch do
  @moduledoc false
  use AshBpmn.Resources.Dispatch,
    domain: AshBpmn.TenantTest.Domain,
    repo: AshBpmn.TestRepo,
    subscription: AshBpmn.TenantTest.Subscription,
    token: AshBpmn.TenantTest.Token,
    table: "tenant_bpmn_dispatches",
    tenant?: true
end

# The re-drive ledger, with the policy a host writes for it (the macro generates none: a
# re-drive is a person's act) and the host's authority check.
defmodule AshBpmn.TenantTest.Redrive do
  @moduledoc false
  use AshBpmn.Resources.Redrive,
    domain: AshBpmn.TenantTest.Domain,
    repo: AshBpmn.TestRepo,
    dispatch: AshBpmn.TenantTest.Dispatch,
    subscription: AshBpmn.TenantTest.Subscription,
    authority: {TriggerTest.RedriveAuthority, :check, [:standing]},
    table: "tenant_bpmn_redrives",
    tenant?: true

  policies do
    policy always() do
      authorize_if actor_attribute_equals(:operator?, true)
    end
  end
end

# A subject that belongs to a tenant, for the tests that a timer reads its data in the
# instance's tenant and never another's (DESIGN.md §11.3). Plain Ash, no BPMN macro: a host's
# subject is the host's own resource.
defmodule AshBpmn.TenantTest.Subject do
  @moduledoc false
  use Ash.Resource,
    domain: AshBpmn.TenantTest.Domain,
    data_layer: AshPostgres.DataLayer

  @ash_bpmn_kind :not_bpmn

  def ash_bpmn_kind, do: @ash_bpmn_kind

  postgres do
    table "tenant_bpmn_test_subjects"
    repo AshBpmn.TestRepo
  end

  multitenancy do
    strategy :attribute
    attribute :organization_id
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
    end

    attribute :notice_at, :utc_datetime_usec do
      public? true
    end

    attribute :organization_id, :uuid do
      allow_nil? false
      public? true
    end

    timestamps()
  end

  actions do
    defaults [:read]

    create :create do
      accept [:name, :notice_at]
    end
  end
end

defmodule AshBpmn.TenantTest.Domain do
  @moduledoc false
  use Ash.Domain

  resources do
    resource AshBpmn.TenantTest.Definition
    resource AshBpmn.TenantTest.Instance
    resource AshBpmn.TenantTest.Token
    resource AshBpmn.TenantTest.HumanTask
    resource AshBpmn.TenantTest.TaskCandidate
    resource AshBpmn.TenantTest.ProcessEvent
    resource AshBpmn.TenantTest.Subscription
    resource AshBpmn.TenantTest.Cursor
    resource AshBpmn.TenantTest.Dispatch
    resource AshBpmn.TenantTest.TimerJob
    resource AshBpmn.TenantTest.Signal
    resource AshBpmn.TenantTest.Redrive
    resource AshBpmn.TenantTest.Subject
  end
end
