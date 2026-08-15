# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.DataCase do
  @moduledoc """
  Case template for tests that talk to a real PostgreSQL server.

  Each test runs inside the Ecto SQL sandbox with automatic checkout/return.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import AshBpmn.DataCase
      alias AshBpmn.TestRepo
    end
  end

  setup tags do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(AshBpmn.TestRepo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end
end
