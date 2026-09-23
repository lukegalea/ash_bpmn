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
           definition: nil,
           import_error: nil
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

      # bpmn-js could not display the pinned definition. The honest case is
      # an instance running a version authored without diagram information;
      # the event trail and token tables still tell its story, while the
      # crash the default handler produced told none.
      @impl true
      def handle_event("import_error", %{"message" => message}, socket) do
        {:noreply, assign(socket, :import_error, message)}
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

            live_tokens =
              tokens
              # `:waiting` belongs here and is the case that matters most on screen: a
              # process parked on an approval is exactly what someone opens this view to
              # look at, and omitting it would blank the diagram for the commonest state.
              |> Enum.filter(&(&1.status in [:active, :executing, :waiting]))
              |> Enum.map(&%{node_id: &1.node_id, status: to_string(&1.status)})

            # Pushed on every load while connected — including when the list is
            # empty. The hook clears before it applies, so an empty payload is
            # what wipes the markers the moment the last token is consumed;
            # gating the push on a non-empty list used to leave the final
            # marker stuck on the canvas forever. `node_ids` stays for any
            # consumer that reads only it; `nodes` adds each token's status so
            # the diagram can style a parked token differently from a
            # mid-flight one.
            socket =
              if connected?(socket) do
                push_event(socket, "highlight", %{
                  node_ids: Enum.map(live_tokens, & &1.node_id),
                  nodes: live_tokens
                })
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
    <div id="ash-bpmn-viewer-root" class="ash-bpmn-root">
      <%!-- Header --%>
      <div class="ash-bpmn-toolbar">
        <div class="ash-bpmn-row">
          <h1 class="ash-bpmn-heading">
            <%= if assigns.instance do %>
              Instance {assigns.instance.status}
            <% else %>
              Loading...
            <% end %>
          </h1>
          <%= if assigns.instance do %>
            <span class={["ash-bpmn-badge", instance_status_class(assigns.instance.status)]}>
              {to_string(assigns.instance.status)}
            </span>
          <% end %>
        </div>
      </div>

      <div class="ash-bpmn-body">
        <%!-- Canvas area --%>
        <div class="ash-bpmn-col">
          <%= if assigns[:import_error] do %>
            <div class="ash-bpmn-callout ash-bpmn-callout--warn">
              This version has no diagram to display — the event trail and
              token table still tell the instance's story.
              <span class="ash-bpmn-callout__detail">{assigns.import_error}</span>
            </div>
          <% end %>
          <%!-- phx-update="ignore" for the same reason as the designer: the
               viewer refreshes its token and event tables on every poll, and
               each patch would otherwise destroy the rendered diagram. --%>
          <div
            id="ash-bpmn-viewer"
            class="ash-bpmn-canvas-pane"
            phx-hook="AshBpmnViewer"
            phx-update="ignore"
            data-xml={assigns.xml}
          >
            <div class="ash-bpmn-canvas ash-bpmn-canvas-frame">
            </div>
          </div>
        </div>

        <%!-- Side panels --%>
        <div class="ash-bpmn-panel">
          <%!-- Tokens --%>
          <div class="ash-bpmn-side-section">
            <h3 class="ash-bpmn-side-title">
              Tokens
            </h3>
            <div id="ash-bpmn-tokens" class="ash-bpmn-side-list">
              <%= for token <- assigns.tokens do %>
                <div class="ash-bpmn-side-row ash-bpmn-side-row--split">
                  <span class="ash-bpmn-inline-label">{token.node_id}</span>
                  <span class={["ash-bpmn-badge", token_status_class(token.status)]}>
                    {to_string(token.status)}
                  </span>
                </div>
              <% end %>
              <%= if assigns.tokens == [] do %>
                <p class="ash-bpmn-subtle">No tokens</p>
              <% end %>
            </div>
          </div>

          <%!-- Tasks --%>
          <div class="ash-bpmn-side-section">
            <h3 class="ash-bpmn-side-title">
              Tasks
            </h3>
            <div id="ash-bpmn-tasks" class="ash-bpmn-side-list">
              <%= for task <- assigns.tasks do %>
                <div class="ash-bpmn-side-row">
                  <span class="ash-bpmn-inline-label">{task.name}</span>
                  <span class="ash-bpmn-subtle">{to_string(task.status)}</span>
                </div>
              <% end %>
              <%= if assigns.tasks == [] do %>
                <p class="ash-bpmn-subtle">No tasks</p>
              <% end %>
            </div>
          </div>

          <%!-- Events --%>
          <div>
            <h3 class="ash-bpmn-side-title">
              Events
            </h3>
            <div id="ash-bpmn-events" class="ash-bpmn-side-list">
              <%= for event <- Enum.take(assigns.events, 20) do %>
                <div class="ash-bpmn-side-row">
                  <span class="ash-bpmn-inline-label">{to_string(event.kind)}</span>
                  <span class="ash-bpmn-subtle">{event.node_id}</span>
                </div>
              <% end %>
              <%= if assigns.events == [] do %>
                <p class="ash-bpmn-subtle">No events</p>
              <% end %>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp instance_status_class(:running), do: "ash-bpmn-badge--info"

  defp instance_status_class(:completed), do: "ash-bpmn-badge--ok"

  defp instance_status_class(:failed), do: "ash-bpmn-badge--danger"

  # Without this clause an errored instance raises FunctionClauseError the moment an operator
  # opens it -- and the compiler cannot warn, because the clauses match on atoms.
  defp instance_status_class(:errored), do: "ash-bpmn-badge--warn"

  defp instance_status_class(:cancelled), do: "ash-bpmn-badge--muted"

  defp token_status_class(:active), do: "ash-bpmn-badge--ok"

  defp token_status_class(:executing), do: "ash-bpmn-badge--info"

  defp token_status_class(:waiting), do: "ash-bpmn-badge--warn"

  defp token_status_class(:consumed), do: "ash-bpmn-badge--muted"

  defp token_status_class(:dead), do: "ash-bpmn-badge--danger"
end
