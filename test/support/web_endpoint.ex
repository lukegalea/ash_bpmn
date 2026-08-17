# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

# IMPORTANT: Module order matters for compilation.
# The Router and Layout must be defined before the Endpoint (which references them).
# The Wrapper LVs must be defined before the Router (which references them).

# ── Minimal layout ───────────────────────────────────────────────────────

defmodule AshBpmn.Web.TestLayout do
  @moduledoc false

  use Phoenix.Component

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>AshBpmn Test</title>
      </head>
      <body class="bg-white dark:bg-zinc-900">
        <main class="container mx-auto p-4">
          <.flash_group flash={@flash} />
          <%= @inner_content %>
        </main>
      </body>
    </html>
    """
  end

  def flash_group(assigns) do
    ~H"""
    <div id="flash-group" class="mb-4">
      <div :for={{key, message} <- @flash} class={[
        "px-4 py-2 rounded-lg text-sm mb-2",
        flash_class(key)
      ]}>
        {message}
      </div>
    </div>
    """
  end

  defp flash_class("info"),
    do: "bg-green-100 text-green-800 dark:bg-green-900 dark:text-green-200"

  defp flash_class("error"), do: "bg-red-100 text-red-800 dark:bg-red-900 dark:text-red-200"
  defp flash_class(_), do: "bg-zinc-100 text-zinc-800 dark:bg-zinc-800 dark:text-zinc-200"
end

# ── Wrapper LiveViews ────────────────────────────────────────────────────

defmodule AshBpmn.Web.DesignerWrapper do
  @moduledoc false

  use AshBpmn.Web.DesignerLive,
    domain: AshBpmn.Test.Domain,
    process: "web_test"
end

defmodule AshBpmn.Web.ViewerWrapper do
  @moduledoc false

  use AshBpmn.Web.ViewerLive,
    domain: AshBpmn.Test.Domain
end

defmodule AshBpmn.Web.TaskListWrapper do
  @moduledoc false

  use AshBpmn.Web.TaskListLive,
    domain: AshBpmn.Test.Domain,
    principal_ids: []
end

# ── Router (before Endpoint) ─────────────────────────────────────────────

defmodule AshBpmn.Web.TestRouter do
  @moduledoc false

  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {AshBpmn.Web.TestLayout, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  scope "/", AshBpmn.Web do
    pipe_through :browser

    live("/designer", DesignerWrapper, :index, as: :designer)
    live("/viewer/:id", ViewerWrapper, :show, as: :viewer)
    live("/tasks", TaskListWrapper, :index, as: :tasks)
  end
end

# ── PubSub placeholder ──────────────────────────────────────────────────

defmodule AshBpmn.Web.TestPubSub do
  @moduledoc false
end

# ── Endpoint (last — references Router) ──────────────────────────────────

defmodule AshBpmn.Web.TestEndpoint do
  @moduledoc false

  # Phoenix endpoints read their config at compile time via module attributes.
  # We must put_env BEFORE `use Phoenix.Endpoint` so the config is available
  # when the endpoint module is compiled.

  Application.put_env(:ash_bpmn, AshBpmn.Web.TestEndpoint,
    server: false,
    pubsub_server: AshBpmn.Web.TestPubSub,
    secret_key_base: String.duplicate("a", 64),
    live_view: [
      signing_salt: String.duplicate("b", 32)
    ],
    render_errors: [
      formats: [html: {AshBpmn.ErrorView, :render, []}],
      layout: false
    ]
  )

  use Phoenix.Endpoint, otp_app: :ash_bpmn

  socket("/live", Phoenix.LiveView.Socket)

  plug(Plug.RequestId)

  plug(Plug.Session,
    store: :cookie,
    key: "_ash_bpmn_test_session",
    signing_salt: String.duplicate("c", 16),
    encrypt: false
  )

  plug(AshBpmn.Web.TestRouter)
end

# ── Minimal error view (Phoenix's default inference name for this app) ────

defmodule AshBpmn.ErrorView do
  @moduledoc false
  def render(template, _assigns), do: "error: #{template}"
end
