# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.Web.DesignerLive do
  @moduledoc """
  BPMN process designer LiveView.

  Provides a `use` macro that injects a complete LiveView for editing a process
  definition. The host supplies a domain, process key, and optional actor resolver.

  ## Usage

      defmodule MyAppWeb.Bpmn.DesignerLive do
        use AshBpmn.Web.DesignerLive,
          domain: MyApp.Bpmn,
          process: "access_request",
          actor: {MyAppWeb.Bpmn.Helpers, :current_actor, []}
      end

  ## Options

    * `:domain` — **required**. The host Ash domain with BPMN resources.
    * `:process` — **required**. The definition key to load or create.
    * `:actor` — optional `{module, function, args}` tuple; called with
      `module.function(args ++ [socket])` to resolve the current actor.

  ## Testability

  Save and Publish are backed by hidden `<form>` elements so tests can use
  `element |> render_submit(%{...})` without needing the JS hook. The same
  handlers also handle hook-pushed events for the real browser flow.

  ## Events

  Client → Server (from JS hook via `pushEvent`):
    * `save_xml` — xml saved from the modeler
    * `selection_changed` — node selected/deselected in the canvas
    * `dirty_changed` — canvas modified flag

  Server → Client (via `push_event` to JS hook):
    * `load_xml` — replace canvas XML
    * `collect_xml` — request XML from the modeler
    * `apply_config` — update node extension elements
    * `fit` — zoom to fit

  Form-driven (testable without JS):
    * `save_xml_form` — hidden form submit carrying XML
    * `publish_form` — hidden form submit that saves then publishes
  """

  # `use`, not `import`: the properties panel declares attrs on its function
  # components, which the declarative API only allows in a using module.
  use Phoenix.Component

  defmacro __using__(opts) do
    domain = Keyword.fetch!(opts, :domain)
    process_key = Keyword.fetch!(opts, :process)
    actor_mfa = Keyword.get(opts, :actor, nil)

    quote do
      use Phoenix.LiveView

      import Phoenix.LiveView.Helpers
      import Phoenix.HTML

      require Ash.Query

      @ash_bpmn_designer_domain unquote(domain)
      @ash_bpmn_designer_process_key unquote(process_key)
      @ash_bpmn_designer_actor_mfa unquote(Macro.escape(actor_mfa))

      # ── Minimal template XML for new drafts ───────────────────────────────

      @ash_bpmn_template_xml """
      <?xml version="1.0" encoding="UTF-8"?>
      <bpmn2:definitions xmlns:bpmn2="http://www.omg.org/spec/BPMN/20100524/MODEL"
                         xmlns:ash="https://github.com/lukegalea/ash_bpmn/ns"
                         id="Definitions_1"
                         targetNamespace="https://github.com/lukegalea/ash_bpmn/ns">
        <bpmn2:process id="Process_#{unquote(process_key)}" name="#{unquote(process_key)}" isExecutable="true">
          <bpmn2:startEvent id="Start_1" name="Start">
            <bpmn2:outgoing>Flow_1</bpmn2:outgoing>
          </bpmn2:startEvent>
          <bpmn2:userTask id="Task_1" name="Task">
            <bpmn2:extensionElements>
              <ash:taskConfig>
                <ash:candidates>
                  <ash:candidate kind="user" of="actor"/>
                </ash:candidates>
                <ash:outcomes>
                  <ash:outcome name="approve"/>
                  <ash:outcome name="reject"/>
                </ash:outcomes>
              </ash:taskConfig>
            </bpmn2:extensionElements>
            <bpmn2:incoming>Flow_1</bpmn2:incoming>
            <bpmn2:outgoing>Flow_2</bpmn2:outgoing>
          </bpmn2:userTask>
          <bpmn2:endEvent id="End_1" name="End">
            <bpmn2:incoming>Flow_2</bpmn2:incoming>
          </bpmn2:endEvent>
          <bpmn2:sequenceFlow id="Flow_1" sourceRef="Start_1" targetRef="Task_1"/>
          <bpmn2:sequenceFlow id="Flow_2" sourceRef="Task_1" targetRef="End_1"/>
        </bpmn2:process>
      </bpmn2:definitions>
      """

      # ── Mount & handle_params ────────────────────────────────────────────

      @impl true
      def mount(_params, _session, socket) do
        {:ok,
         socket
         |> assign(
           definition_key: @ash_bpmn_designer_process_key,
           definition: nil,
           xml: "",
           latest_published: nil,
           selected: nil,
           dirty: false,
           errors: [],
           graph: nil,
           pending_publish: false
         )}
      end

      @impl true
      def handle_params(_params, _uri, socket) do
        socket = load_or_create_definition(socket)

        if connected?(socket) do
          {:noreply, push_event(socket, "load_xml", %{xml: socket.assigns.xml})}
        else
          {:noreply, socket}
        end
      end

      # ── Hook events ────────────────────────────────────────────────────

      @impl true
      def handle_event("save_xml", %{"xml" => xml}, socket) do
        socket = do_save_xml(socket, xml)

        socket =
          if socket.assigns[:pending_publish] do
            do_publish(socket)
          else
            socket
          end

        {:noreply, socket}
      end

      @impl true
      def handle_event("selection_changed", params, socket) do
        selected =
          case params do
            %{"id" => id, "type" => type, "name" => name} ->
              # `config` is the element's *current* ash: binding, read from the
              # modeller rather than from the last-saved XML — the panel has to
              # render what is on the canvas now, or Apply would overwrite it
              # with the blanks the user was shown.
              %{
                id: id,
                type: type,
                name: name,
                config: AshBpmn.Web.DesignerLive.normalize_config(params["config"])
              }

            _ ->
              nil
          end

        {:noreply, assign(socket, :selected, selected)}
      end

      @impl true
      def handle_event("dirty_changed", %{"dirty" => dirty}, socket) do
        {:noreply, assign(socket, :dirty, dirty)}
      end

      @impl true
      def handle_event("import_error", %{"message" => message}, socket) do
        errors = [%{"path" => "xml", "message" => message} | socket.assigns.errors]
        {:noreply, assign(socket, :errors, errors)}
      end

      # ── Button events ───────────────────────────────────────────────────

      @impl true
      def handle_event("collect-xml", _params, socket) do
        {:noreply, push_event(socket, "collect_xml", %{})}
      end

      @impl true
      def handle_event("publish", _params, socket) do
        {:noreply,
         socket
         |> assign(:pending_publish, true)
         |> push_event("collect_xml", %{})}
      end

      @impl true
      def handle_event("revert", _params, socket) do
        socket = load_or_create_definition(socket)

        {:noreply,
         socket
         |> assign(:dirty, false)
         |> push_event("load_xml", %{xml: socket.assigns.xml})}
      end

      @impl true
      def handle_event("fit", _params, socket) do
        {:noreply, push_event(socket, "fit", %{})}
      end

      # ── Hidden form handlers (testable without JS) ────────────────────

      @impl true
      def handle_event("save_xml_form", %{"xml" => xml}, socket) do
        {:noreply, do_save_xml(socket, xml)}
      end

      @impl true
      def handle_event("publish_form", %{"xml" => xml}, socket) do
        socket = do_save_xml(socket, xml)

        {:noreply, do_publish(socket)}
      end

      # ── Config update ───────────────────────────────────────────────────

      @impl true
      def handle_event("update-config", params, socket) do
        id = params["element_id"] || params["id"] || ""
        name = params["name"] || ""
        config = build_config_from_params(params)

        {:noreply, push_event(socket, "apply_config", %{id: id, name: name, config: config})}
      end

      # ── Render delegates to the component module ─────────────────────────

      @impl true
      def render(assigns) do
        AshBpmn.Web.DesignerLive.__render__(assigns)
      end

      # ── Private helpers ─────────────────────────────────────────────────

      defp load_or_create_definition(socket) do
        {:ok, %{definition: definition_mod}} =
          AshBpmn.Resources.for_domain(@ash_bpmn_designer_domain)

        opts = [authorize?: false]

        # A draft is edited in place until published; find it by key+status.
        # `do_filter/2` (not the filter macro) because the resource module is
        # only known at runtime — the macro resolves bare fields statically.
        definition =
          definition_mod
          |> Ash.Query.for_read(:read, %{}, authorize?: false)
          |> Ash.Query.do_filter(key: @ash_bpmn_designer_process_key, status: :draft)
          |> Ash.read_one!(authorize?: false)
          |> case do
            nil ->
              definition_mod.create!(
                %{
                  key: @ash_bpmn_designer_process_key,
                  name: String.capitalize(@ash_bpmn_designer_process_key) <> " process",
                  xml: @ash_bpmn_template_xml
                },
                Keyword.put(opts, :authorize?, false)
              )

            defn ->
              defn
          end

        latest_published =
          case definition_mod.latest_published(@ash_bpmn_designer_process_key, authorize?: false) do
            {:ok, []} -> nil
            {:ok, [pub | _]} -> pub
            [] -> nil
            [pub | _] -> pub
          end

        socket
        |> assign(:definition, definition)
        |> assign(:xml, definition.xml)
        |> assign(:errors, definition.errors || [])
        |> assign(:graph, definition.graph)
        |> assign(:latest_published, latest_published)
      end

      defp do_save_xml(socket, xml) do
        {:ok, %{definition: definition_mod}} =
          AshBpmn.Resources.for_domain(@ash_bpmn_designer_domain)

        definition = socket.assigns.definition

        opts = [authorize?: false]

        case definition_mod.save_xml(definition, xml, opts) do
          {:ok, updated} ->
            socket
            |> assign(:definition, updated)
            |> assign(:xml, updated.xml)
            |> assign(:errors, updated.errors || [])
            |> assign(:graph, updated.graph)
            |> assign(:dirty, false)
            |> put_flash(:info, "Saved")

          {:error, error} ->
            socket
            |> assign(:dirty, true)
            |> put_flash(:error, Exception.message(error))
        end
      end

      defp do_publish(socket) do
        {:ok, %{definition: definition_mod}} =
          AshBpmn.Resources.for_domain(@ash_bpmn_designer_domain)

        definition = socket.assigns.definition
        opts = [authorize?: false]

        case definition_mod.publish(definition, opts) do
          {:ok, published} ->
            socket
            |> assign(:definition, published)
            |> assign(:errors, [])
            |> assign(:pending_publish, false)
            |> put_flash(:info, "Published v#{published.version}")

          {:error, error} ->
            socket
            |> assign(:pending_publish, false)
            |> put_flash(:error, Exception.message(error))
        end
      end

      defp build_config_from_params(params) do
        type = params["type"] || ""

        case type do
          "bpmn:ServiceTask" ->
            %{action: params["action"] || ""}

          "bpmn:UserTask" ->
            %{
              "candidates" => parse_candidates(params),
              "exclusions" => parse_exclusions(params),
              "outcomes" => parse_outcomes(params),
              "timers" => parse_timers(params)
            }

          "bpmn:EndEvent" ->
            %{"outcome" => params["outcome"] || ""}

          _ ->
            %{}
        end
      end

      # The panel renders a blank row at the end of every list so entries can be
      # added, which means blank rows are the normal case and must be dropped
      # rather than written back as empty bindings.
      defp parse_candidates(params) do
        kinds = List.wrap(params["candidates_kind"] || [])
        ofs = List.wrap(params["candidates_of"] || [])

        kinds
        |> Enum.zip_with(pad(ofs, length(kinds)), &%{"kind" => &1, "of" => &2})
        |> Enum.reject(&(blank?(&1["kind"]) and blank?(&1["of"])))
      end

      defp parse_exclusions(params) do
        params["exclusions_who"]
        |> List.wrap()
        |> Enum.reject(&blank?/1)
        |> Enum.map(&%{"who" => &1})
      end

      defp parse_outcomes(params) do
        (params["outcomes_name"] || params["outcome"])
        |> List.wrap()
        |> Enum.map(&to_string/1)
        |> Enum.reject(&blank?/1)
      end

      defp parse_timers(params) do
        kinds = List.wrap(params["timers_kind"] || [])
        values = pad(List.wrap(params["timers_value"] || []), length(kinds))
        units = pad(List.wrap(params["timers_unit"] || []), length(kinds))

        [kinds, values, units]
        |> Enum.zip_with(fn [kind, value, unit] ->
          %{"kind" => kind, (unit || "hours") => parse_integer(value)}
        end)
        |> Enum.reject(&blank?(&1["kind"]))
      end

      defp parse_integer(nil), do: nil

      defp parse_integer(value) when is_binary(value) do
        case Integer.parse(String.trim(value)) do
          {int, _} -> int
          :error -> nil
        end
      end

      defp parse_integer(value) when is_integer(value), do: value
      defp parse_integer(_), do: nil

      defp pad(list, size) do
        list ++ List.duplicate(nil, max(size - length(list), 0))
      end

      defp blank?(nil), do: true
      defp blank?(value) when is_binary(value), do: String.trim(value) == ""
      defp blank?(_), do: false

      defp definition_status_class(:draft),
        do: "bg-yellow-100 text-yellow-800 dark:bg-yellow-900 dark:text-yellow-200"

      defp definition_status_class(:published),
        do: "bg-green-100 text-green-800 dark:bg-green-900 dark:text-green-200"

      defp definition_status_class(:retired),
        do: "bg-zinc-100 text-zinc-800 dark:bg-zinc-800 dark:text-zinc-200"
    end
  end

  @doc false
  def __render__(assigns) do
    ~H"""
    <div id="ash-bpmn-designer-root" class="flex flex-col h-full">
      <%!-- Header bar --%>
      <div class="flex items-center justify-between px-4 py-2 border-b border-zinc-200 dark:border-zinc-700 bg-white dark:bg-zinc-900">
        <div class="flex items-center gap-3">
          <h1 class="text-sm font-semibold text-zinc-900 dark:text-zinc-100 truncate max-w-48">
            {assigns.definition && assigns.definition.name || assigns.definition_key}
          </h1>
          <span class="text-xs text-zinc-500 dark:text-zinc-400">
            {assigns.definition_key}
          </span>
          <%= if assigns.definition do %>
            <span class="text-xs text-zinc-400 dark:text-zinc-500">
              v{assigns.definition.version}
            </span>
            <span class={[
              "px-2 py-0.5 rounded-full text-xs font-medium",
              definition_status_class(assigns.definition.status)
            ]}>
              {to_string(assigns.definition.status)}
            </span>
          <% end %>
        </div>

        <div class="flex items-center gap-2">
          <button
            type="button"
            id="bpmn-fit-btn"
            phx-click="fit"
            class="px-3 py-1.5 text-xs font-medium text-zinc-700 dark:text-zinc-300 bg-white dark:bg-zinc-800 border border-zinc-300 dark:border-zinc-600 rounded-md hover:bg-zinc-50 dark:hover:bg-zinc-700 transition-colors"
          >
            Fit
          </button>
          <button
            type="button"
            id="bpmn-revert-btn"
            phx-click="revert"
            class="px-3 py-1.5 text-xs font-medium text-zinc-700 dark:text-zinc-300 bg-white dark:bg-zinc-800 border border-zinc-300 dark:border-zinc-600 rounded-md hover:bg-zinc-50 dark:hover:bg-zinc-700 transition-colors"
          >
            Revert
          </button>
          <button
            type="button"
            id="bpmn-publish-btn"
            phx-click="publish"
            class="px-3 py-1.5 text-xs font-medium text-white bg-indigo-600 rounded-md hover:bg-indigo-700 transition-colors"
          >
            Publish
          </button>
          <button
            type="button"
            id="bpmn-save-btn"
            phx-click="collect-xml"
            class="px-3 py-1.5 text-xs font-medium text-white bg-emerald-600 rounded-md hover:bg-emerald-700 transition-colors"
          >
            Save
          </button>
        </div>
      </div>

      <div class="flex flex-1 overflow-hidden">
        <%!-- Main canvas area --%>
        <div class="flex-1 flex flex-col overflow-hidden">
          <%!-- Errors panel --%>
          <div id="ash-bpmn-errors" class="px-4 py-2">
            <%= for error <- assigns.errors do %>
              <div class="mb-2 p-3 bg-red-50 dark:bg-red-950 border border-red-200 dark:border-red-800 rounded-lg text-sm">
                <span class="font-medium text-red-800 dark:text-red-200">
                  {error["path"] || "error"}
                </span>
                <span class="text-red-700 dark:text-red-300 ml-2">
                  {error["message"]}
                </span>
              </div>
            <% end %>
          </div>

          <%!-- BPMN designer canvas.
               phx-update="ignore" is load-bearing: bpmn-js owns everything
               inside this element, and any LiveView patch — selecting a node
               re-renders the properties panel — would otherwise wipe the SVG
               the modeller drew. New XML reaches the canvas through the
               `load_xml` push_event, never through the DOM. --%>
          <div
            id="ash-bpmn-designer"
            class="flex-1 px-4 pb-4"
            phx-hook="AshBpmnDesigner"
            phx-update="ignore"
            data-xml={assigns.xml}
          >
            <div class="ash-bpmn-canvas h-[32rem] w-full border border-zinc-300 dark:border-zinc-700 rounded-lg overflow-hidden">
            </div>
          </div>

          <%!-- Hidden forms for testability --%>
          <form id="ash-bpmn-save-form" phx-submit="save_xml_form" class="hidden">
            <input type="hidden" name="xml" />
          </form>
          <form id="ash-bpmn-publish-form" phx-submit="publish_form" class="hidden">
            <input type="hidden" name="xml" />
          </form>
        </div>

        <%!-- Properties panel --%>
        <div id="ash-bpmn-panel" class="w-72 border-l border-zinc-200 dark:border-zinc-700 bg-white dark:bg-zinc-900 overflow-y-auto">
          <%= if assigns.selected do %>
            <div class="p-4">
              <h3 class="text-sm font-semibold text-zinc-900 dark:text-zinc-100 mb-3">
                {assigns.selected.name || assigns.selected.id}
              </h3>
              <p class="text-xs text-zinc-500 dark:text-zinc-400 mb-4">
                {assigns.selected.type} — {assigns.selected.id}
              </p>
              <form phx-submit="update-config">
                <input type="hidden" name="element_id" value={assigns.selected.id} />
                <input type="hidden" name="type" value={assigns.selected.type} />

                <div class="mb-3">
                  <label class="block text-xs font-medium text-zinc-700 dark:text-zinc-300 mb-1" for="config-name">
                    Name
                  </label>
                  <input
                    id="config-name"
                    type="text"
                    name="name"
                    value={assigns.selected.name}
                    class="w-full px-2 py-1 text-sm border border-zinc-300 dark:border-zinc-600 rounded-md bg-white dark:bg-zinc-800 text-zinc-900 dark:text-zinc-100 focus:outline-none focus:ring-1 focus:ring-indigo-500"
                  />
                </div>

                <.node_config selected={assigns.selected} />

                <button
                  type="submit"
                  class="w-full px-3 py-1.5 text-xs font-medium text-white bg-indigo-600 rounded-md hover:bg-indigo-700 transition-colors mt-2"
                >
                  Apply
                </button>
              </form>
            </div>
          <% else %>
            <div class="p-4 text-sm text-zinc-400 dark:text-zinc-500">
              Select a node to edit its properties.
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  defp definition_status_class(:draft),
    do: "bg-yellow-100 text-yellow-800 dark:bg-yellow-900 dark:text-yellow-200"

  defp definition_status_class(:published),
    do: "bg-green-100 text-green-800 dark:bg-green-900 dark:text-green-200"

  defp definition_status_class(:retired),
    do: "bg-zinc-100 text-zinc-800 dark:bg-zinc-800 dark:text-zinc-200"

  defp field_class do
    "w-full px-2 py-1 text-xs border border-zinc-300 dark:border-zinc-600 rounded-md " <>
      "bg-white dark:bg-zinc-800 text-zinc-900 dark:text-zinc-100"
  end

  defp label_class, do: "block text-xs font-medium text-zinc-700 dark:text-zinc-300 mb-1"

  @doc false
  # The panel is prefilled from the selection's live `config`, and every list
  # renders one row per existing entry plus one blank row, so a submit can only
  # add — never silently drop what was already bound to the element.
  attr(:selected, :map, required: true)

  def node_config(%{selected: %{type: "bpmn:ServiceTask"}} = assigns) do
    ~H"""
    <div class="mb-3">
      <label class={label_class()} for="config-action">Action</label>
      <input
        id="config-action"
        type="text"
        name="action"
        value={@selected.config["action"]}
        class={field_class()}
        placeholder="my_app.do_something"
      />
    </div>
    """
  end

  def node_config(%{selected: %{type: "bpmn:UserTask"}} = assigns) do
    assigns =
      assigns
      |> assign(
        :candidates,
        rows(assigns.selected.config["candidates"], %{"kind" => "", "of" => ""})
      )
      |> assign(:exclusions, rows(assigns.selected.config["exclusions"], %{"who" => ""}))
      |> assign(:outcomes, rows(assigns.selected.config["outcomes"], ""))
      |> assign(:timers, rows(assigns.selected.config["timers"], %{"kind" => "", "hours" => nil}))

    ~H"""
    <div class="mb-3">
      <label class={label_class()}>Candidates</label>
      <div :for={candidate <- @candidates} class="space-y-1 mb-2">
        <input
          type="text"
          name="candidates_kind[]"
          value={candidate["kind"]}
          class={field_class()}
          placeholder="kind"
        />
        <input
          type="text"
          name="candidates_of[]"
          value={candidate["of"]}
          class={field_class()}
          placeholder="of (subject path)"
        />
      </div>
    </div>

    <div class="mb-3">
      <label class={label_class()}>Outcomes</label>
      <input
        :for={outcome <- @outcomes}
        type="text"
        name="outcomes_name[]"
        value={outcome}
        class={[field_class(), "mb-1"]}
        placeholder="approved"
      />
    </div>

    <div class="mb-3">
      <label class={label_class()}>Exclusions</label>
      <input
        :for={exclusion <- @exclusions}
        type="text"
        name="exclusions_who[]"
        value={exclusion["who"]}
        class={[field_class(), "mb-1"]}
        placeholder="subject.created_by_id"
      />
    </div>

    <div class="mb-3">
      <label class={label_class()}>Timers</label>
      <%!-- Unit is part of the row, not assumed: a timer written as days="7"
            would otherwise render blank in an hours-only field and be saved
            back without its duration. --%>
      <div :for={timer <- @timers} class="flex gap-1 mb-1">
        <input
          type="text"
          name="timers_kind[]"
          value={timer["kind"]}
          class={field_class()}
          placeholder="remind | escalate | expire"
        />
        <input
          type="text"
          name="timers_value[]"
          value={timer_value(timer)}
          class={[field_class(), "w-16"]}
          placeholder="24"
        />
        <select name="timers_unit[]" class={[field_class(), "w-24"]}>
          <option
            :for={unit <- ~w(minutes hours days)}
            value={unit}
            selected={unit == timer_unit(timer)}
          >
            {unit}
          </option>
        </select>
      </div>
    </div>
    """
  end

  def node_config(%{selected: %{type: "bpmn:EndEvent"}} = assigns) do
    ~H"""
    <div class="mb-3">
      <label class={label_class()} for="config-outcome">Outcome</label>
      <input
        id="config-outcome"
        type="text"
        name="outcome"
        value={@selected.config["outcome"]}
        class={field_class()}
        placeholder="approved"
      />
    </div>
    """
  end

  def node_config(assigns) do
    ~H"""
    <p class="text-xs text-zinc-400 dark:text-zinc-500">
      No configurable properties for this element type.
    </p>
    """
  end

  # One row per existing entry, plus a blank one to grow the list.
  defp rows(nil, blank), do: [blank]
  defp rows([], blank), do: [blank]
  defp rows(entries, blank), do: entries ++ [blank]

  # A timer carries exactly one of minutes/hours/days; these pick whichever it is.
  @timer_units ~w(minutes hours days)

  defp timer_value(timer) do
    Enum.find_value(@timer_units, fn unit -> timer[unit] end)
  end

  defp timer_unit(timer) do
    Enum.find(@timer_units, "hours", fn unit -> timer[unit] end)
  end

  @doc """
  Normalizes the `config` payload the designer hook sends with a selection into
  a string-keyed map with every list present.
  """
  @spec normalize_config(map() | nil) :: map()
  def normalize_config(nil), do: empty_config()

  def normalize_config(config) when is_map(config) do
    Map.merge(empty_config(), config)
  end

  defp empty_config do
    %{
      "action" => "",
      "outcome" => "",
      "candidates" => [],
      "exclusions" => [],
      "outcomes" => [],
      "timers" => []
    }
  end
end
