# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.WebConnCase do
  @moduledoc """
  Case template for ash_bpmn web (LiveView) tests.

  Starts the test PubSub + endpoint under the test supervisor and sets up the
  SQL sandbox, then imports the Phoenix.ConnTest / Phoenix.LiveViewTest
  helpers. The TestRepo itself is started once in test_helper.exs.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest

      alias AshBpmn.Web.TestEndpoint
      @endpoint AshBpmn.Web.TestEndpoint
    end
  end

  setup tags do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(AshBpmn.TestRepo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)

    start_supervised!({Phoenix.PubSub, name: AshBpmn.Web.TestPubSub, adapter: Phoenix.PubSub.PG2})
    start_supervised!(AshBpmn.Web.TestEndpoint)

    :ok
  end
end
