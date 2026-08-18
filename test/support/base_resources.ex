# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.BaseTest.Resource do
  @moduledoc """
  A stand-in for a host application's base resource — the awkward variety.

  Real ones do a great deal more (ownership, provenance, an audit hook, soft
  delete, tenancy), but the property that decides whether `:base` works is this
  one: **a base resource ships its own policy set, and `use` expands it first.**

  So this module's `policies do … end` lands ahead of the bypass the ash_bpmn
  macro emits afterwards — and because a bypass in Ash only short-circuits the
  policies declared *after* it, the engine's own calls are forbidden on a
  resource built this way. That is a real constraint rather than a bug, and
  `base_resource_test.exs` pins it in both directions: forbidden here, allowed on
  `AshBpmn.BaseTest.PolicylessBase` where the bypass comes first.

  `AshBpmn.Config.engine_actor/0` documents what a host in this position does
  about it.
  """

  defmacro __using__(opts) do
    quote do
      use Ash.Resource,
          unquote(
            Keyword.merge(
              [data_layer: AshPostgres.DataLayer, authorizers: [Ash.Policy.Authorizer]],
              opts
            )
          )

      # The host's rule: no actor, no access. Declared before the engine's bypass.
      policies do
        policy always() do
          authorize_if actor_present()
        end
      end

      def base_resource?, do: true
    end
  end
end

defmodule AshBpmn.BaseTest.HumanTask do
  @moduledoc false
  use AshBpmn.Resources.HumanTask,
    domain: AshBpmn.BaseTest.Domain,
    repo: AshBpmn.TestRepo,
    instance: AshBpmn.Test.Instance,
    token: AshBpmn.Test.Token,
    base: AshBpmn.BaseTest.Resource
end

defmodule AshBpmn.BaseTest.PolicylessBase do
  @moduledoc """
  The other kind of base: one that leaves authorization to the resource.

  A resource built on this gets the engine bypass first, because there is nothing
  ahead of it — which is the arrangement a host wants, and the one that works.
  """

  defmacro __using__(opts) do
    quote do
      use Ash.Resource,
          unquote(
            Keyword.merge(
              [data_layer: AshPostgres.DataLayer, authorizers: [Ash.Policy.Authorizer]],
              opts
            )
          )

      def base_resource?, do: true
    end
  end
end

defmodule AshBpmn.BaseTest.TaskCandidate do
  @moduledoc false
  use AshBpmn.Resources.TaskCandidate,
    domain: AshBpmn.BaseTest.Domain,
    repo: AshBpmn.TestRepo,
    task: AshBpmn.BaseTest.HumanTask,
    base: AshBpmn.BaseTest.PolicylessBase

  # The host's own rule, declared *after* the macro's bypass -- which is the
  # order that lets the engine through and still holds everyone else out.
  policies do
    policy always() do
      authorize_if actor_present()
    end
  end
end

defmodule AshBpmn.BaseTest.NoPolicies do
  @moduledoc """
  `policies?: false` — the opt-out.

  The host takes the whole policy set, including whatever the engine needs. With
  an authorizer and nothing to satisfy it, this resource refuses everyone, which
  is the correct and deliberate consequence rather than an oversight.
  """
  use AshBpmn.Resources.ProcessEvent,
    domain: AshBpmn.BaseTest.Domain,
    repo: AshBpmn.TestRepo,
    instance: AshBpmn.Test.Instance,
    policies?: false
end

defmodule AshBpmn.BaseTest.Domain do
  @moduledoc false
  use Ash.Domain

  resources do
    resource AshBpmn.BaseTest.HumanTask
    resource AshBpmn.BaseTest.TaskCandidate
    resource AshBpmn.BaseTest.NoPolicies
  end
end
