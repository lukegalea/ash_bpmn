# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

# A dedicated domain for the `AshBpmn.Domain` callables extension tests. Generic
# actions only — no data layer, no tables. Deliberately separate from
# `AshBpmn.Test.Domain` so the shared engine domain's DSL stays untouched.
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
