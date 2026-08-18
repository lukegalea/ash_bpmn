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
  end
end
