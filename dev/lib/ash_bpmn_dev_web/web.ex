# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

# Module order matters: the layout and the LiveViews must exist before the
# router that references them, and the router before the endpoint.

defmodule AshBpmnDevWeb.Layout do
  @moduledoc false

  use Phoenix.Component

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en" class="h-full">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={Phoenix.Controller.get_csrf_token()} />
        <title>AshBpmn demo</title>
        <link phx-track-static rel="stylesheet" href="/assets/tailwind.css" />
        <link phx-track-static rel="stylesheet" href="/assets/app.css" />
        <script defer phx-track-static type="text/javascript" src="/assets/app.js">
        </script>
      </head>
      <body class="h-full bg-zinc-50 text-zinc-900">
        <header class="border-b border-zinc-200 bg-white">
          <nav class="mx-auto flex max-w-7xl items-center gap-6 px-6 py-3">
            <span class="text-sm font-semibold tracking-tight">AshBpmn</span>
            <.nav_link href="/designer" label="Designer" />
            <.nav_link href="/tasks" label="My tasks" />
            <.nav_link href="/instances" label="Instances" />
          </nav>
        </header>
        <main class="mx-auto max-w-7xl px-6 py-6">
          <.flash_group flash={@flash} />
          {@inner_content}
        </main>
      </body>
    </html>
    """
  end

  attr :href, :string, required: true
  attr :label, :string, required: true

  defp nav_link(assigns) do
    ~H"""
    <a href={@href} class="text-sm text-zinc-600 hover:text-zinc-900">{@label}</a>
    """
  end

  def flash_group(assigns) do
    ~H"""
    <div id="flash-group" class="mb-4">
      <div
        :for={{key, message} <- @flash}
        class={["mb-2 rounded-lg px-4 py-2 text-sm", flash_class(key)]}
      >
        {message}
      </div>
    </div>
    """
  end

  defp flash_class("info"), do: "bg-emerald-100 text-emerald-900"
  defp flash_class("error"), do: "bg-rose-100 text-rose-900"
  defp flash_class(_), do: "bg-zinc-100 text-zinc-900"
end

defmodule AshBpmnDevWeb.DesignerLive do
  @moduledoc false

  use AshBpmn.Web.DesignerLive,
    domain: AshBpmnDev.Bpmn,
    process: "access_request"
end

defmodule AshBpmnDevWeb.ViewerLive do
  @moduledoc false

  use AshBpmn.Web.ViewerLive, domain: AshBpmnDev.Bpmn
end

defmodule AshBpmnDevWeb.TaskListLive do
  @moduledoc false

  # The manager is the signed-in user for the demo, so the task list has
  # something in it — a host would resolve this from the session.
  use AshBpmn.Web.TaskListLive,
    domain: AshBpmnDev.Bpmn,
    principal_ids: ["22222222-2222-2222-2222-222222222222"]
end

defmodule AshBpmnDevWeb.InstanceListLive do
  @moduledoc """
  A tiny index so the viewer has an entry point. Not part of the library — a
  host writes whatever listing suits it.
  """

  use Phoenix.LiveView

  require Ash.Query

  @impl true
  def mount(_params, _session, socket) do
    instances =
      AshBpmnDev.Bpmn.Instance
      |> Ash.Query.for_read(:read)
      |> Ash.Query.sort(inserted_at: :desc)
      |> Ash.read!(authorize?: false)

    {:ok, assign(socket, instances: instances)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="rounded-xl border border-zinc-200 bg-white p-5">
      <h1 class="mb-4 text-base font-semibold">Process instances</h1>
      <table class="w-full text-sm">
        <thead class="text-left text-xs uppercase tracking-wide text-zinc-500">
          <tr>
            <th class="pb-2">Instance</th>
            <th class="pb-2">Status</th>
            <th class="pb-2">Outcome</th>
            <th class="pb-2">Started</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={instance <- @instances} class="border-t border-zinc-100">
            <td class="py-2">
              <a class="text-indigo-600 hover:underline" href={"/instances/#{instance.id}"}>
                {String.slice(instance.id, 0, 8)}
              </a>
            </td>
            <td class="py-2">{instance.status}</td>
            <td class="py-2">{instance.outcome || "—"}</td>
            <td class="py-2 text-zinc-500">{instance.inserted_at}</td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end
end

defmodule AshBpmnDevWeb.Router do
  @moduledoc false

  use Phoenix.Router

  import Phoenix.LiveView.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {AshBpmnDevWeb.Layout, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  scope "/", AshBpmnDevWeb do
    pipe_through :browser

    live "/", TaskListLive, :index
    live "/designer", DesignerLive, :index
    live "/tasks", TaskListLive, :index
    live "/instances", InstanceListLive, :index
    live "/instances/:id", ViewerLive, :show
  end
end

defmodule AshBpmnDevWeb.ErrorView do
  @moduledoc false
  def render(template, _assigns), do: "error: #{template}"
end

defmodule AshBpmnDevWeb.Endpoint do
  @moduledoc false

  use Phoenix.Endpoint, otp_app: :ash_bpmn

  socket "/live", Phoenix.LiveView.Socket

  plug Plug.Static,
    at: "/",
    from: "dev/priv/static",
    gzip: false,
    only: ~w(assets favicon.ico)

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:ash_bpmn_dev, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head

  plug Plug.Session,
    store: :cookie,
    key: "_ash_bpmn_dev_session",
    signing_salt: "devsaltdevsalt"

  plug AshBpmnDevWeb.Router
end
