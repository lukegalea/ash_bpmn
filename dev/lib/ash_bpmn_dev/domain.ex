# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmnDev.Bpmn do
  @moduledoc """
  The demo host domain. A real application instantiates the six BPMN resources
  into one of its own domains exactly like this.
  """

  use Ash.Domain

  resources do
    resource AshBpmnDev.Bpmn.Definition
    resource AshBpmnDev.Bpmn.Instance
    resource AshBpmnDev.Bpmn.Token
    resource AshBpmnDev.Bpmn.HumanTask
    resource AshBpmnDev.Bpmn.TaskCandidate
    resource AshBpmnDev.Bpmn.ProcessEvent
    resource AshBpmnDev.AccessRequest
  end
end

defmodule AshBpmnDev.Bpmn.Definition do
  @moduledoc false
  use AshBpmn.Resources.Definition,
    domain: AshBpmnDev.Bpmn,
    repo: AshBpmnDev.Repo

  policies do
    bypass do
      authorize_if always()
    end
  end
end

defmodule AshBpmnDev.Bpmn.Instance do
  @moduledoc false
  use AshBpmn.Resources.Instance,
    domain: AshBpmnDev.Bpmn,
    repo: AshBpmnDev.Repo,
    definition: AshBpmnDev.Bpmn.Definition

  policies do
    bypass do
      authorize_if always()
    end
  end
end

defmodule AshBpmnDev.Bpmn.Token do
  @moduledoc false
  use AshBpmn.Resources.Token,
    domain: AshBpmnDev.Bpmn,
    repo: AshBpmnDev.Repo,
    instance: AshBpmnDev.Bpmn.Instance

  policies do
    bypass do
      authorize_if always()
    end
  end
end

defmodule AshBpmnDev.Bpmn.HumanTask do
  @moduledoc false
  use AshBpmn.Resources.HumanTask,
    domain: AshBpmnDev.Bpmn,
    repo: AshBpmnDev.Repo,
    instance: AshBpmnDev.Bpmn.Instance,
    token: AshBpmnDev.Bpmn.Token

  policies do
    bypass do
      authorize_if always()
    end
  end
end

defmodule AshBpmnDev.Bpmn.TaskCandidate do
  @moduledoc false
  use AshBpmn.Resources.TaskCandidate,
    domain: AshBpmnDev.Bpmn,
    repo: AshBpmnDev.Repo,
    task: AshBpmnDev.Bpmn.HumanTask

  policies do
    bypass do
      authorize_if always()
    end
  end
end

defmodule AshBpmnDev.Bpmn.ProcessEvent do
  @moduledoc false
  use AshBpmn.Resources.ProcessEvent,
    domain: AshBpmnDev.Bpmn,
    repo: AshBpmnDev.Repo,
    instance: AshBpmnDev.Bpmn.Instance

  policies do
    bypass do
      authorize_if always()
    end
  end
end

defmodule AshBpmnDev.AccessRequest do
  @moduledoc """
  The demo's subject resource — what the process is *about*. Nothing here knows
  about BPMN beyond being the record an instance points at.
  """

  use Ash.Resource,
    domain: AshBpmnDev.Bpmn,
    data_layer: AshPostgres.DataLayer

  @ash_bpmn_kind :not_bpmn

  def ash_bpmn_kind, do: @ash_bpmn_kind

  postgres do
    table "dev_access_requests"
    repo AshBpmnDev.Repo
  end

  attributes do
    uuid_primary_key :id

    attribute :role, :string do
      allow_nil? false
      public? true
    end

    attribute :justification, :string do
      public? true
    end

    attribute :amount, :integer do
      default 0
      public? true
    end

    attribute :is_privileged, :boolean do
      default false
      public? true
    end

    attribute :created_by_id, :uuid do
      public? true
    end

    timestamps()
  end

  actions do
    defaults [:read]

    create :create do
      accept [:role, :justification, :amount, :is_privileged, :created_by_id]
    end
  end

  code_interface do
    define :create
  end
end
