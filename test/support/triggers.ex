# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

# Test doubles and fixtures for the triggers extension resources
# (`Subscription`, `Cursor`, `Dispatch`).
#
# The `TriggerTest.Payout` and `TriggerTest.Unaudited` fixtures are
# deliberately **not** under the `AshBpmn.*` namespace: the subscription's
# publish-time cycle invariant refuses any `match_resource` under `AshBpmn.`
# or `AshDecisions.`, so a fixture used to prove the audited-resource check
# *passes* must live outside the refused prefixes. (`AshBpmn.TenantTest.Dispatch`
# is audited-by-fiat in the double below for the mirror reason: the
# signal-exception test needs a resource that is both audited and cyclic, so
# the cycle check — not the audit check — is what the assertion exercises.)

defmodule TriggerTest.Payout do
  @moduledoc "An audited stand-in for a host resource a subscription could watch."

  use Ash.Resource, domain: nil, data_layer: Ash.DataLayer.Ets

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id

    attribute :amount, :integer do
      default 0
      public? true
    end
  end

  actions do
    defaults [:create, :read, :update, :destroy]
  end
end

defmodule TriggerTest.Unaudited do
  @moduledoc "Exists and is loadable, and writes no events -- the silent-never-fires case."

  use Ash.Resource, domain: nil, data_layer: Ash.DataLayer.Ets

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id
  end

  actions do
    defaults [:create, :read]
  end
end

defmodule TriggerTest.EventSource do
  @moduledoc """
  A minimal `AshBpmn.EventSource` double for publish-time checks.

  Only `audited?/1` carries state that matters here; the sweep-side callbacks
  exist to satisfy the behaviour and answer nothing.
  """

  @behaviour AshBpmn.EventSource

  # `Dispatch` is audited by fiat, so the signal-exception test can prove the
  # *cycle* check is what passes for it, not the audit check. See the file
  # comment above.
  @audited [TriggerTest.Payout, AshBpmn.TenantTest.Dispatch]

  @impl true
  def stream(_tenant, _after_sequence, _limit), do: {:ok, {[], nil}}

  @impl true
  def context(_event), do: %{}

  @impl true
  def sequence(_event), do: 0

  @impl true
  def occurred_at(_event), do: DateTime.utc_now()

  @impl true
  def order_guarantee(_tenant), do: :commit_order

  @impl true
  def audited?(resource), do: resource in @audited
end

defmodule TriggerTest.DecisionResolver do
  @moduledoc """
  A decision resolver double whose `exists?/1` answer the test flips.

  Publish-time decision verification only ever calls `exists?/1`, so the
  answer lives in a persistent term the test sets per case.
  """

  @behaviour AshBpmn.DecisionResolver

  @impl true
  def decide(_ref, _inputs, _context), do: {:ok, %{outputs: %{}}}

  @impl true
  def exists?(_ref), do: :persistent_term.get({__MODULE__, :exists?}, true)

  def set_exists?(value), do: :persistent_term.put({__MODULE__, :exists?}, value)
end
