# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.Web.ViewerLive do
  @moduledoc """
  BPMN process instance viewer LiveView.

  Provides a `use` macro that injects a complete LiveView for viewing a running
  process instance with its diagram, tokens, tasks, and events.

  ## Usage

      defmodule MyAppWeb.Bpmn.ViewerLive do
        use AshBpmn.Web.ViewerLive,
          domain: MyApp.Bpmn
      end

  ## Options

    * `:domain` — **required**. The host Ash domain with BPMN resources.

  The instance id is read from `handle_params %{"id" => id}`.
  """

  import Phoenix.Component

  defmacro __using__(opts) do
    domain = Keyword.fetch!(opts, :domain)

    quote do
      use Phoenix.LiveView

      import Phoenix.LiveView.Helpers

      @ash_bpmn_viewer_domain unquote(domain)

      @impl true
      def mount(_params, _session, socket) do
        {:ok,
         socket
         |> assign(
           instance_id: nil,
           instance: nil,
           xml: "",
           tokens: [],
           tasks: [],
           events: [],
           definition: nil
         )}
      end

      @impl true
      def handle_params(params, _uri, socket) do
        id = params["id"] || params["instance_id"]

        socket =
          socket
          |> assign(:instance_id, id)
          |> load_instance()

        socket =
          if connected?(socket) do
            schedule_refresh(socket)
          else
            socket
          end

        {:noreply, socket}
      end

      @impl true
      def handle_info(:refresh, socket) do
        socket = load_instance(socket)

        socket =
          if should_poll?(socket) do
            schedule_refresh(socket)
          else
            socket
          end

        {:noreply, socket}
      end

      @impl true
      def render(assigns) do
        AshBpmn.Web.ViewerLive.__render__(assigns)
      end

      # ── Private helpers ─────────────────────────────────────────────────

      defp load_instance(socket) do
        {:ok,
         %{
           instance: instance_mod,
           token: token_mod,
           human_task: human_task_mod,
           process_event: process_event_mod,
           definition: definition_mod
         }} =
          AshBpmn.Resources.for_domain(@ash_bpmn_viewer_domain)

        instance_id = socket.assigns[:instance_id]

        if is_nil(instance_id) do
          socket
        else
          opts = AshBpmn.Scope.engine(AshBpmn.Scope.from_assigns(socket.assigns))

          instance =
            instance_mod
            |> Ash.Query.for_read(:read)
            |> Ash.Query.do_filter(id: instance_id)
            |> Ash.read_one!(opts)

          if is_nil(instance) do
            socket
            |> assign(:instance, nil)
            |> assign(:xml, "")
            |> assign(:tokens, [])
            |> assign(:tasks, [])
            |> assign(:events, [])
          else
            # Through the configured loader, not a tenant-scoped read of our own.
            #
            # An instance may be pinned to a definition that does not live in its tenant --
            # a baseline the host publishes centrally -- which is the entire reason
            # `AshBpmn.DefinitionLoader` exists. Reading it directly here found nothing and
            # fell through to `xml = ""`, so the viewer rendered its token list, its task
            # list and its event log correctly beside a completely blank canvas. bpmn-js had
            # booted and imported nothing, so there was no error anywhere to follow.
            #
            # `load/4` rather than `load!/4`: a viewer that cannot find a definition should
            # still show the tokens and events it *did* find, which are the useful half.
            definition =
              case AshBpmn.Config.definition_loader().load(
                     definition_mod,
                     instance.definition_id,
                     instance,
                     AshBpmn.Scope.from_assigns(socket.assigns)
                   ) do
                {:ok, definition} -> definition
                {:error, _reason} -> nil
              end

            tokens =
              token_mod
              |> Ash.Query.for_read(:read)
              |> Ash.Query.do_filter(instance_id: instance.id)
              |> Ash.read!(opts)

            tasks =
              human_task_mod
              |> Ash.Query.for_read(:read)
              |> Ash.Query.do_filter(instance_id: instance.id)
              |> Ash.read!(opts)

            events =
              process_event_mod
              |> Ash.Query.for_read(:read)
              |> Ash.Query.do_filter(instance_id: instance.id)
              |> Ash.Query.sort(recorded_at: :desc)
              |> Ash.read!(opts)

            xml = if(definition, do: definition.xml, else: "")

            active_node_ids =
              tokens
              |> Enum.filter(&(&1.status in [:active, :executing]))
              |> Enum.map(& &1.node_id)

            socket =
              if connected?(socket) && active_node_ids != [] do
                push_event(socket, "highlight", %{node_ids: active_node_ids})
              else
                socket
              end

            socket
            |> assign(:instance, instance)
            |> assign(:definition, definition)
            |> assign(:xml, xml)
            |> assign(:tokens, tokens)
            |> assign(:tasks, tasks)
            |> assign(:events, events)
          end
        end
      end

      defp should_poll?(socket) do
        case socket.assigns[:instance] do
          nil -> false
          instance -> normalize_status(instance.status) == "running"
        end
      end

      defp normalize_status(status) when is_atom(status), do: to_string(status)
      defp normalize_status(status) when is_binary(status), do: status

      defp schedule_refresh(socket) do
        Process.send_after(self(), :refresh, 5000)
        socket
      end
    end
  end

  @doc false
  def __render__(assigns) do
    ~H"""
    <div id="ash-bpmn-viewer-root" class="flex flex-col h-full">
      <%!-- Header --%>
      <div class="flex items-center justify-between px-4 py-2 border-b border-zinc-200 dark:border-zinc-700 bg-white dark:bg-zinc-900">
        <div class="flex items-center gap-3">
          <h1 class="text-sm font-semibold text-zinc-900 dark:text-zinc-100">
            <%= if assigns.instance do %>
              Instance {assigns.instance.status}
            <% else %>
              Loading...
            <% end %>
          </h1>
          <%= if assigns.instance do %>
            <span class={[
              "px-2 py-0.5 rounded-full text-xs font-medium",
              instance_status_class(assigns.instance.status)
            ]}>
              {to_string(assigns.instance.status)}
            </span>
          <% end %>
        </div>
      </div>

      <div class="flex flex-1 overflow-hidden">
        <%!-- Canvas area --%>
        <div class="flex-1 flex flex-col overflow-hidden">
          <%!-- phx-update="ignore" for the same reason as the designer: the
               viewer refreshes its token and event tables on every poll, and
               each patch would otherwise destroy the rendered diagram. --%>
          <div
            id="ash-bpmn-viewer"
            class="flex-1 px-4 py-4"
            phx-hook="AshBpmnViewer"
            phx-update="ignore"
            data-xml={assigns.xml}
          >
            <div class="ash-bpmn-canvas h-[32rem] w-full border border-zinc-300 dark:border-zinc-700 rounded-lg overflow-hidden">
            </div>
          </div>
        </div>

        <%!-- Side panels --%>
        <div class="w-72 border-l border-zinc-200 dark:border-zinc-700 bg-white dark:bg-zinc-900 overflow-y-auto">
          <%!-- Tokens --%>
          <div class="border-b border-zinc-200 dark:border-zinc-700">
            <h3 class="px-4 py-2 text-xs font-semibold text-zinc-500 dark:text-zinc-400 uppercase tracking-wide">
              Tokens
            </h3>
            <div id="ash-bpmn-tokens" class="px-4 pb-2">
              <%= for token <- assigns.tokens do %>
                <div class="flex items-center justify-between py-1 text-xs">
                  <span class="text-zinc-700 dark:text-zinc-300">{token.node_id}</span>
                  <span class={[
                    "px-1.5 py-0.5 rounded text-xs",
                    token_status_class(token.status)
                  ]}>
                    {to_string(token.status)}
                  </span>
                </div>
              <% end %>
              <%= if assigns.tokens == [] do %>
                <p class="text-xs text-zinc-400 dark:text-zinc-500">No tokens</p>
              <% end %>
            </div>
          </div>

          <%!-- Tasks --%>
          <div class="border-b border-zinc-200 dark:border-zinc-700">
            <h3 class="px-4 py-2 text-xs font-semibold text-zinc-500 dark:text-zinc-400 uppercase tracking-wide">
              Tasks
            </h3>
            <div id="ash-bpmn-tasks" class="px-4 pb-2">
              <%= for task <- assigns.tasks do %>
                <div class="py-1 text-xs">
                  <span class="text-zinc-700 dark:text-zinc-300">{task.name}</span>
                  <span class="ml-2 text-zinc-400 dark:text-zinc-500">{to_string(task.status)}</span>
                </div>
              <% end %>
              <%= if assigns.tasks == [] do %>
                <p class="text-xs text-zinc-400 dark:text-zinc-500">No tasks</p>
              <% end %>
            </div>
          </div>

          <%!-- Events --%>
          <div>
            <h3 class="px-4 py-2 text-xs font-semibold text-zinc-500 dark:text-zinc-400 uppercase tracking-wide">
              Events
            </h3>
            <div id="ash-bpmn-events" class="px-4 pb-2">
              <%= for event <- Enum.take(assigns.events, 20) do %>
                <div class="py-1 text-xs">
                  <span class="text-zinc-700 dark:text-zinc-300">{to_string(event.kind)}</span>
                  <span class="ml-2 text-zinc-400 dark:text-zinc-500">{event.node_id}</span>
                </div>
              <% end %>
              <%= if assigns.events == [] do %>
                <p class="text-xs text-zinc-400 dark:text-zinc-500">No events</p>
              <% end %>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp instance_status_class(:running),
    do: "bg-blue-100 text-blue-800 dark:bg-blue-900 dark:text-blue-200"

  defp instance_status_class(:completed),
    do: "bg-green-100 text-green-800 dark:bg-green-900 dark:text-green-200"

  defp instance_status_class(:failed),
    do: "bg-red-100 text-red-800 dark:bg-red-900 dark:text-red-200"

  defp instance_status_class(:cancelled),
    do: "bg-zinc-100 text-zinc-800 dark:bg-zinc-800 dark:text-zinc-200"

  defp token_status_class(:active),
    do: "bg-green-100 text-green-700 dark:bg-green-900 dark:text-green-300"

  defp token_status_class(:executing),
    do: "bg-blue-100 text-blue-700 dark:bg-blue-900 dark:text-blue-300"

  defp token_status_class(:consumed),
    do: "bg-zinc-100 text-zinc-600 dark:bg-zinc-800 dark:text-zinc-400"

  defp token_status_class(:dead), do: "bg-red-100 text-red-600 dark:bg-red-900 dark:text-red-400"
end
