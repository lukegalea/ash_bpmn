# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

# A dedicated domain for the `AshBpmn.Domain` callables extension tests. Generic
# actions only — no data layer, no tables. Deliberately separate from
# `AshBpmn.Test.Domain` so the shared engine domain's DSL stays untouched.
#
# The `ash:call` engine-test callables live on a second domain further down
# (`AshBpmn.Test.RuntimeCallablesDomain`): the one above pins its callable list
# exactly in `callables_test.exs`.
#
# The resource is declared before the domain on purpose: Spark verifiers run in
# `@after_verify`, which fires the moment a module finishes compiling — the domain
# must not compile before the resource it introspects.

defmodule AshBpmn.Test.CallablesResource do
  @moduledoc false

  use Ash.Resource, domain: AshBpmn.Test.CallablesDomain

  actions do
    action :approve, :string do
      description "Approves the thing"
      run fn _input, _context -> {:ok, "approved"} end
    end

    action :reject, :string do
      run fn _input, _context -> {:ok, "rejected"} end
    end
  end
end

defmodule AshBpmn.Test.CallablesDomain do
  @moduledoc false

  use Ash.Domain, extensions: [AshBpmn.Domain]

  resources do
    resource AshBpmn.Test.CallablesResource
  end

  callables do
    callable :approve_payout, AshBpmn.Test.CallablesResource, :approve do
      description "Approves a payout after maker-checker"
    end

    callable(:reject_payout, AshBpmn.Test.CallablesResource, :reject)
  end
end

# ── The `ash:call` engine-test callables ────────────────────────────────────
#
# A second domain, deliberately: `AshBpmn.Test.CallablesDomain` above pins its
# callable list exactly in `callables_test.exs`, and the `ash:call` tests need
# their own actions anyway. `RuntimeCallablesDomain` is listed in the test
# `:ash_domains` config, which is what makes its refs resolvable to the compiler
# and the engine.

defmodule AshBpmn.Test.CallablesRuntimeResource do
  @moduledoc """
  Generic callables for the ash:call engine tests. No data layer, no tables.

  * `assess_tier` — returns `{"tier" => "high" | "low"}` from an `amount` argument,
    so a diagram can promote the output onto the token and route on it.
  * `record_inputs` — records the arguments it received, and the context it was
    called under, into `AshBpmn.Test.CallablesRecorder`.
  * `always_fails` — returns an error tuple, for the failure path.
  """

  use Ash.Resource, domain: AshBpmn.Test.RuntimeCallablesDomain

  actions do
    action :assess_tier, :map do
      argument :amount, :decimal, allow_nil?: false

      run fn input, _context ->
        amount = Ash.ActionInput.get_argument(input, :amount)

        tier =
          if Decimal.compare(amount, Decimal.new(1000)) == :gt, do: "high", else: "low"

        {:ok, %{"tier" => tier}}
      end
    end

    action :record_inputs, :string do
      argument :amount, :decimal, allow_nil?: false
      argument :tier, :string, allow_nil?: false

      run fn input, _context ->
        AshBpmn.Test.CallablesRecorder.record(:record_inputs, input)
        {:ok, "recorded"}
      end
    end

    action :always_fails, :string do
      run fn _input, _context -> {:error, "the payout was refused"} end
    end
  end
end

defmodule AshBpmn.Test.CallablesEnrollee do
  @moduledoc """
  An ETS-backed resource so the create-callable test can go through a real
  `Ash.create/2` without a migration. Private table, single node — test only.
  """

  use Ash.Resource,
    domain: AshBpmn.Test.RuntimeCallablesDomain,
    data_layer: Ash.DataLayer.Ets

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, public?: true
  end

  actions do
    defaults [:read]

    create :enroll do
      # Verification requires declared inputs to name *arguments*, so the create
      # takes the name as an argument and copies it onto the attribute here.
      argument :name, :string, allow_nil?: false
      accept []

      change fn changeset, _ ->
        name = Ash.Changeset.get_argument(changeset, :name)
        Ash.Changeset.force_change_attribute(changeset, :name, name)
      end
    end
  end
end

defmodule AshBpmn.Test.CallablesGuardedResource do
  @moduledoc """
  A callable whose policy admits nobody but the engine. The bypass recognises the
  private context flag `AshBpmn.Scope.engine/1` sets — so if the call reaches the
  action at all, it went through the engine scope, and the recorder holds the proof.
  """

  use Ash.Resource,
    domain: AshBpmn.Test.RuntimeCallablesDomain,
    authorizers: [Ash.Policy.Authorizer]

  actions do
    action :engine_only, :string do
      run fn input, _context ->
        AshBpmn.Test.CallablesRecorder.record(:engine_only, input)
        {:ok, "ran"}
      end
    end
  end

  policies do
    bypass AshBpmn.Checks.AshBpmnInteraction do
      authorize_if always()
    end

    policy always() do
      forbid_if always()
    end
  end
end

defmodule AshBpmn.Test.RuntimeCallablesDomain do
  @moduledoc false

  use Ash.Domain, extensions: [AshBpmn.Domain]

  resources do
    resource AshBpmn.Test.CallablesRuntimeResource
    resource AshBpmn.Test.CallablesEnrollee
    resource AshBpmn.Test.CallablesGuardedResource
  end

  callables do
    callable :assess_tier, AshBpmn.Test.CallablesRuntimeResource, :assess_tier do
      description "Assesses the risk tier from the amount"
    end

    callable(:record_inputs, AshBpmn.Test.CallablesRuntimeResource, :record_inputs)
    callable(:always_fails, AshBpmn.Test.CallablesRuntimeResource, :always_fails)
    callable(:enroll, AshBpmn.Test.CallablesEnrollee, :enroll)
    callable(:engine_check, AshBpmn.Test.CallablesGuardedResource, :engine_only)
  end
end

defmodule AshBpmn.Test.CallablesRecorder do
  @moduledoc """
  Records what the ash:call test callables actually received: their arguments,
  string-keyed, and whether the engine's private context flag was set.

  The engine runs inline in tests, but the advance job may execute in the caller's
  process or not, so this is ETS — the same arrangement `AshBpmn.Test.Invoker` uses —
  not a process dictionary.
  """

  @table :ash_bpmn_test_callable_calls

  def record(action, %Ash.ActionInput{} = input) do
    do_record(action, input.arguments, engine_context?(input.context))
  end

  def record(action, %Ash.Changeset{} = changeset) do
    do_record(action, changeset.arguments, engine_context?(changeset.context))
  end

  defp do_record(action, arguments, engine?) do
    ensure_table()

    :ets.insert(@table, {
      System.unique_integer([:positive]),
      to_string(action),
      Map.new(arguments || %{}, fn {k, v} -> {to_string(k), v} end),
      engine?
    })

    :ok
  end

  @doc "Every recorded call as `%{action, arguments, engine_context?}`, oldest first."
  def recorded do
    if :ets.whereis(@table) != :undefined do
      @table
      |> :ets.tab2list()
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {_id, action, arguments, engine?} ->
        %{action: action, arguments: arguments, engine_context?: engine?}
      end)
    else
      []
    end
  end

  def clear do
    ensure_table()
    :ets.delete_all_objects(@table)
    :ok
  end

  defp engine_context?(context), do: get_in(context, [:private, :ash_bpmn?]) == true

  defp ensure_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set])
    end

    :ok
  end
end
