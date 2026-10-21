# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

# A third instantiation of the six core resource macros, over the same tables as
# `AshBpmn.Test.*`, carrying a host's read policy: an actor reads the instances
# whose `correlation_id` is their own, and the tokens of those instances.
#
# The macro's engine bypass comes first and the host policy after it, which is
# the arrangement that lets the engine through and still filters everyone else
# (see `AshBpmn.BaseTest.Resource` for the other order). It exists to prove that
# a read made on an actor's behalf, such as `AshBpmn.FlightView.token_positions/2`
# with `:actor`, runs under these policies rather than the engine's bypass.

defmodule AshBpmn.ScopedTest.Definition do
  @moduledoc false
  use AshBpmn.Resources.Definition,
    domain: AshBpmn.ScopedTest.Domain,
    repo: AshBpmn.TestRepo

  policies do
    policy always() do
      authorize_if always()
    end
  end
end

defmodule AshBpmn.ScopedTest.Instance do
  @moduledoc false
  use AshBpmn.Resources.Instance,
    domain: AshBpmn.ScopedTest.Domain,
    repo: AshBpmn.TestRepo,
    definition: AshBpmn.ScopedTest.Definition

  policies do
    policy action_type(:read) do
      authorize_if expr(correlation_id == ^actor(:correlation_id))
    end

    policy action_type([:create, :update, :destroy, :action]) do
      authorize_if always()
    end
  end
end

defmodule AshBpmn.ScopedTest.Token do
  @moduledoc false
  use AshBpmn.Resources.Token,
    domain: AshBpmn.ScopedTest.Domain,
    repo: AshBpmn.TestRepo,
    instance: AshBpmn.ScopedTest.Instance

  policies do
    policy action_type(:read) do
      authorize_if expr(instance.correlation_id == ^actor(:correlation_id))
    end

    policy action_type([:create, :update, :destroy, :action]) do
      authorize_if always()
    end
  end
end

defmodule AshBpmn.ScopedTest.HumanTask do
  @moduledoc false
  use AshBpmn.Resources.HumanTask,
    domain: AshBpmn.ScopedTest.Domain,
    repo: AshBpmn.TestRepo,
    instance: AshBpmn.ScopedTest.Instance,
    token: AshBpmn.ScopedTest.Token,
    task_candidate: AshBpmn.ScopedTest.TaskCandidate

  policies do
    policy always() do
      authorize_if always()
    end
  end
end

defmodule AshBpmn.ScopedTest.TaskCandidate do
  @moduledoc false
  use AshBpmn.Resources.TaskCandidate,
    domain: AshBpmn.ScopedTest.Domain,
    repo: AshBpmn.TestRepo,
    task: AshBpmn.ScopedTest.HumanTask

  policies do
    policy always() do
      authorize_if always()
    end
  end
end

defmodule AshBpmn.ScopedTest.ProcessEvent do
  @moduledoc false
  use AshBpmn.Resources.ProcessEvent,
    domain: AshBpmn.ScopedTest.Domain,
    repo: AshBpmn.TestRepo,
    instance: AshBpmn.ScopedTest.Instance

  policies do
    policy always() do
      authorize_if always()
    end
  end
end

defmodule AshBpmn.ScopedTest.Domain do
  @moduledoc false
  use Ash.Domain

  resources do
    resource AshBpmn.ScopedTest.Definition
    resource AshBpmn.ScopedTest.Instance
    resource AshBpmn.ScopedTest.Token
    resource AshBpmn.ScopedTest.HumanTask
    resource AshBpmn.ScopedTest.TaskCandidate
    resource AshBpmn.ScopedTest.ProcessEvent
  end
end
