# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmnDev.Application do
  @moduledoc """
  Supervision tree for the demo app. Dev-env only — the library itself starts
  nothing.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      AshBpmnDev.Repo,
      {Phoenix.PubSub, name: AshBpmnDev.PubSub},
      AshBpmnDevWeb.Endpoint
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: AshBpmnDev.Supervisor)
  end

  @impl true
  def config_change(changed, _new, removed) do
    AshBpmnDevWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
