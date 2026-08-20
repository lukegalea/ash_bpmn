# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

# Test instantiations of all six BPMN resource macros with permissive policies
# for testing. Each module is owned by Lane A (test/support/**).
# Policies are added after `use` because Elixir `use` does not support `do` blocks.

defmodule AshBpmn.Test.Definition do
  @moduledoc false
  use AshBpmn.Resources.Definition,
    domain: AshBpmn.Test.Domain,
    repo: AshBpmn.TestRepo

  policies do
    bypass do
      authorize_if always()
    end
  end
end

defmodule AshBpmn.Test.Instance do
  @moduledoc false
  use AshBpmn.Resources.Instance,
    domain: AshBpmn.Test.Domain,
    repo: AshBpmn.TestRepo,
    definition: AshBpmn.Test.Definition

  policies do
    bypass do
      authorize_if always()
    end
  end
end

defmodule AshBpmn.Test.Token do
  @moduledoc false
  use AshBpmn.Resources.Token,
    domain: AshBpmn.Test.Domain,
    repo: AshBpmn.TestRepo,
    instance: AshBpmn.Test.Instance

  policies do
    bypass do
      authorize_if always()
    end
  end
end

defmodule AshBpmn.Test.HumanTask do
  @moduledoc false
  use AshBpmn.Resources.HumanTask,
    domain: AshBpmn.Test.Domain,
    repo: AshBpmn.TestRepo,
    instance: AshBpmn.Test.Instance,
    token: AshBpmn.Test.Token

  policies do
    bypass do
      authorize_if always()
    end
  end
end

defmodule AshBpmn.Test.TaskCandidate do
  @moduledoc false
  use AshBpmn.Resources.TaskCandidate,
    domain: AshBpmn.Test.Domain,
    repo: AshBpmn.TestRepo,
    task: AshBpmn.Test.HumanTask

  policies do
    bypass do
      authorize_if always()
    end
  end
end

defmodule AshBpmn.Test.ProcessEvent do
  @moduledoc false
  use AshBpmn.Resources.ProcessEvent,
    domain: AshBpmn.Test.Domain,
    repo: AshBpmn.TestRepo,
    instance: AshBpmn.Test.Instance

  policies do
    bypass do
      authorize_if always()
    end
  end
end

# A simple subject resource for engine / approval tests.
# No authorizer — open access in test contexts.
defmodule AshBpmn.Test.Subject do
  @moduledoc false
  use Ash.Resource,
    domain: AshBpmn.Test.Domain,
    data_layer: AshPostgres.DataLayer

  @ash_bpmn_kind :not_bpmn

  def ash_bpmn_kind, do: @ash_bpmn_kind

  postgres do
    table "bpmn_test_subjects"
    repo AshBpmn.TestRepo
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
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
    read :read do
      primary? true
    end

    create :create do
      accept [:name, :amount, :is_privileged, :created_by_id]
    end

    update :update do
      accept [:name, :amount, :is_privileged, :created_by_id]
    end
  end

  code_interface do
    define :create!, action: :create
    define :update!, action: :update
  end
end

defmodule AshBpmn.Test.FixedDefinitionLoader do
  @moduledoc """
  A loader that always returns one particular definition.

  Exists so a test can tell the difference between a viewer that goes through
  `AshBpmn.DefinitionLoader` and one that reads the definition itself. Pointing it
  at a definition the instance is *not* pinned to makes that difference visible
  without needing a second tenant.
  """

  @behaviour AshBpmn.DefinitionLoader

  require Ash.Query

  @impl true
  def load(resource, _definition_id, _instance, _scope) do
    id = Application.get_env(:ash_bpmn, :test_fixed_definition_id)

    resource
    |> Ash.Query.for_read(:read)
    |> Ash.Query.do_filter(id: id)
    |> Ash.read_one!(authorize?: false)
    |> case do
      nil -> {:error, :not_found}
      definition -> {:ok, definition}
    end
  end
end

defmodule AshBpmn.Test.FailingDefinitionLoader do
  @moduledoc "A loader that never finds anything, for the missing-diagram path."

  @behaviour AshBpmn.DefinitionLoader

  @impl true
  def load(_resource, _definition_id, _instance, _scope), do: {:error, :nope}
end
