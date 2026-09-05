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
    * `:process` — the definition key to load or create. Optional: when it is omitted the
      key comes from the route (`:key` or `:process` in the path), which is what a
      multi-process application needs. Supplying neither is an error at mount, with a message
      saying so.
    * `:actor` — optional `{module, function, args}` tuple; called with
      `module.function(args ++ [socket])` to resolve the current actor.
    * `:decisions` — optional `{module, function, args}` tuple; called with
      `module.function(args ++ [socket])` on mount and on every `handle_params`,
      and expected to return the decision catalogue: a list of entries shaped
      `%{key: key, name: name, status: :draft | :published,
      latest_published_version: pos_integer | nil, has_draft: boolean,
      decisions: [%{name: name, inputs: [...], outputs: [...]}]}`. A failure is
      swallowed and the panel falls back to free text.
    * `:actions` — optional `{module, function, args}` tuple; same convention,
      returning the action catalogue: a list of
      `%{ref: ref, label: label, description: description | nil,
      args: [%{name: name, type: type, allow_nil?: boolean,
      description: description | nil}]}`. One row per declared argument is
      rendered for the selected action. `AshBpmn.Catalogue.AshActions` builds
      these straight from `{ref, resource, action}` triples.
    * `:decision_editor` — optional `{module, function, args}` tuple; called
      with `module.function(args ++ [decision_key, socket])` and expected to
      answer with an href (or nil) for editing that decision, which becomes the
      business rule panel's "Edit decision ↗" link.

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
    # Optional since the designer learned to take its key from the route. A multi-process
    # application -- and any application whose tenants author their own processes -- cannot
    # declare one LiveView module per process key, which is what a compile-time-only option
    # forces.
    process_key = Keyword.get(opts, :process)
    actor_mfa = Keyword.get(opts, :actor, nil)
    # The catalogues. Each is an optional {module, function, args} tuple called with
    # `module.function(args ++ [socket])`; the panel renders selects from what comes
    # back and falls back to free text when the option is absent or the call fails.
    decisions_mfa = Keyword.get(opts, :decisions, nil)
    actions_mfa = Keyword.get(opts, :actions, nil)
    decision_editor_mfa = Keyword.get(opts, :decision_editor, nil)

    quote do
      use Phoenix.LiveView

      import Phoenix.LiveView.Helpers
      import Phoenix.HTML

      require Ash.Query

      @ash_bpmn_designer_domain unquote(domain)
      @ash_bpmn_designer_process_key unquote(process_key)
      # See the note in task_list_live.ex: escaping an option that is already AST stores
      # the alias unexpanded, and it reaches `apply/3` as a tuple rather than a module.
      @ash_bpmn_designer_actor_mfa unquote(actor_mfa)
      @ash_bpmn_designer_decisions_mfa unquote(decisions_mfa)
      @ash_bpmn_designer_actions_mfa unquote(actions_mfa)
      @ash_bpmn_designer_decision_editor_mfa unquote(decision_editor_mfa)

      # ── Minimal template XML for new drafts ───────────────────────────────

      # A function rather than an attribute: the key is not known until the route is.
      defp ash_bpmn_template_xml(process_key) do
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <bpmn2:definitions xmlns:bpmn2="http://www.omg.org/spec/BPMN/20100524/MODEL"
                           xmlns:ash="https://github.com/lukegalea/ash_bpmn/ns"
                           id="Definitions_1"
                           targetNamespace="https://github.com/lukegalea/ash_bpmn/ns">
          <bpmn2:process id="Process_#{process_key}" name="#{process_key}" isExecutable="true">
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
      end

      # The route wins over the compile-time option, so one module can serve every process a
      # tenant authors. Neither being present is a configuration error rather than a blank
      # page: the designer has nothing to open.
      defp ash_bpmn_resolve_key(params) do
        params["key"] || params["process"] || @ash_bpmn_designer_process_key ||
          raise """
          ash_bpmn: the designer has no process key.

          Either pass one at compile time:

              use AshBpmn.Web.DesignerLive, domain: MyApp.Bpmn, process: "access_request"

          or put it in the route, which is what a multi-process application wants:

              live "/processes/:key/designer", MyAppWeb.Bpmn.DesignerLive
          """
      end

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
         )
         |> ash_bpmn_load_catalogues()}
      end

      @impl true
      def handle_params(params, _uri, socket) do
        socket = assign(socket, :definition_key, ash_bpmn_resolve_key(params))
        socket = load_or_create_definition(socket)
        # The catalogues can depend on the tenant, which the route may just have changed.
        socket = ash_bpmn_load_catalogues(socket)

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
        config = build_config_from_params(params, socket.assigns[:actions] || [])

        {:noreply, push_event(socket, "apply_config", %{id: id, name: name, config: config})}
      end

      # A select inside the properties panel changed before Apply — most usefully the
      # action select on a service task, whose declared argument rows only exist once
      # the action is chosen. Re-render the panel around the new selection.
      @impl true
      def handle_event("panel-changed", params, socket) do
        selected =
          case socket.assigns[:selected] do
            nil ->
              nil

            sel ->
              %{sel | config: panel_params_to_config(params, sel.config)}
          end

        {:noreply, assign(socket, :selected, selected)}
      end

      # Merges just the panel fields a `phx-change` select owns back into the
      # selection's config, leaving every other entry untouched.
      defp panel_params_to_config(params, config) do
        config = config || %{}

        config =
          if Map.has_key?(params, "action") do
            Map.put(config, "action", params["action"] || "")
          else
            config
          end

        decision_keys = [
          {"decision_ref", "ref"},
          {"binding", "binding"},
          {"version", "version"},
          {"decision_name", "name"}
        ]

        decision =
          Enum.reduce(decision_keys, Map.get(config, "decision") || %{}, fn
            {param, key}, acc ->
              if Map.has_key?(params, param) do
                Map.put(acc, key, params[param] || "")
              else
                acc
              end
          end)

        if decision == %{} do
          config
        else
          Map.put(
            config,
            "decision",
            Map.merge(AshBpmn.Web.DesignerLive.empty_decision(), decision)
          )
        end
      end

      # ── Render delegates to the component module ─────────────────────────

      @impl true
      def render(assigns) do
        AshBpmn.Web.DesignerLive.__render__(assigns)
      end

      # ── Private helpers ─────────────────────────────────────────────────

      # Refresh the catalogue assigns. Called from mount and handle_params: the
      # catalogues may be tenant-scoped, and the tenant can change between params.
      # The nil-or-MFA dispatch lives in the library (`resolve_catalogue/2`,
      # `resolve_decision_editor_href/2`): branching here on the module attribute
      # would compile a case whose MFA clause is provably dead for any host that
      # passes no catalogue, which is dialyzer noise in every such host's build.
      defp ash_bpmn_load_catalogues(socket) do
        socket
        |> assign(
          :decisions,
          AshBpmn.Web.DesignerLive.resolve_catalogue(@ash_bpmn_designer_decisions_mfa, socket)
        )
        |> assign(
          :actions,
          AshBpmn.Web.DesignerLive.resolve_catalogue(@ash_bpmn_designer_actions_mfa, socket)
        )
        |> assign(
          :decision_editor_href,
          AshBpmn.Web.DesignerLive.resolve_decision_editor_href(
            @ash_bpmn_designer_decision_editor_mfa,
            socket
          )
        )
      end

      defp load_or_create_definition(socket) do
        {:ok, %{definition: definition_mod}} =
          AshBpmn.Resources.for_domain(@ash_bpmn_designer_domain)

        opts = AshBpmn.Scope.engine(AshBpmn.Scope.from_assigns(socket.assigns))

        # A draft is edited in place until published; find it by key+status.
        # `do_filter/2` (not the filter macro) because the resource module is
        # only known at runtime — the macro resolves bare fields statically.
        definition =
          definition_mod
          |> Ash.Query.for_read(
            :read,
            %{},
            AshBpmn.Scope.engine(AshBpmn.Scope.from_assigns(socket.assigns))
          )
          |> Ash.Query.do_filter(key: socket.assigns.definition_key, status: :draft)
          |> Ash.read_one!(AshBpmn.Scope.engine(AshBpmn.Scope.from_assigns(socket.assigns)))
          |> case do
            nil ->
              definition_mod.create!(
                %{
                  key: socket.assigns.definition_key,
                  name: String.capitalize(socket.assigns.definition_key) <> " process",
                  xml: ash_bpmn_template_xml(socket.assigns.definition_key)
                },
                Keyword.put(opts, :authorize?, false)
              )

            defn ->
              defn
          end

        latest_published =
          case definition_mod.latest_published(
                 socket.assigns.definition_key,
                 AshBpmn.Scope.engine(AshBpmn.Scope.from_assigns(socket.assigns))
               ) do
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

        opts = AshBpmn.Scope.engine(AshBpmn.Scope.from_assigns(socket.assigns))

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
        opts = AshBpmn.Scope.engine(AshBpmn.Scope.from_assigns(socket.assigns))

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

      defp build_config_from_params(params, actions \\ []) do
        type = params["type"] || ""

        case type do
          "bpmn:ServiceTask" ->
            service_task_config(params, actions)

          "bpmn:SendTask" ->
            service_task_config(params, actions)

          "bpmn:BusinessRuleTask" ->
            version =
              if params["binding"] == "pinned", do: params["version"] || "", else: nil

            %{
              "decision" => %{
                "ref" => params["decision_ref"] || "",
                "binding" => params["binding"] || "latest",
                "version" => version,
                "name" =>
                  if(blank?(params["decision_name"]), do: nil, else: params["decision_name"])
              },
              "inputs" => parse_feel_inputs(params),
              "promote" => parse_promote(params)
            }

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

      defp service_task_config(params, actions) do
        %{
          "action" => params["action"] || "",
          # The rows the panel rendered for the selected action's declared arguments
          # are ordinary ash:inputs whose name is the argument's name; only the rows
          # the user filled are kept. No catalogue entry — no declared rows.
          "inputs" => parse_arg_inputs(params, actions),
          "promote" => parse_promote(params)
        }
      end

      # One positional `inputs_from[]` per declared argument row, in the order the
      # panel rendered them.
      defp parse_arg_inputs(params, actions) do
        case Enum.find(actions, fn entry -> to_string(entry.ref) == params["action"] end) do
          nil ->
            []

          entry ->
            froms = pad(List.wrap(params["inputs_from"] || []), length(entry.args))

            entry.args
            |> Enum.zip_with(froms, fn arg, from -> {arg, from} end)
            |> Enum.reject(fn {_arg, from} -> blank?(from) end)
            |> Enum.map(fn {arg, from} -> %{"name" => to_string(arg.name), "from" => from} end)
        end
      end

      defp parse_feel_inputs(params) do
        names = List.wrap(params["inputs_name"] || [])
        froms = pad(List.wrap(params["inputs_from"] || []), length(names))

        names
        |> Enum.zip_with(froms, &%{"name" => &1, "from" => &2})
        |> Enum.reject(&(blank?(&1["name"]) or blank?(&1["from"])))
      end

      defp parse_promote(params) do
        names = List.wrap(params["promote_name"] || [])
        froms = pad(List.wrap(params["promote_from"] || []), length(names))
        required = pad(List.wrap(params["promote_required"] || []), length(names))

        [names, froms, required]
        |> Enum.zip_with(fn [name, from, req] ->
          %{"name" => name, "from" => from, "required" => to_string(req) == "true"}
        end)
        |> Enum.reject(&blank?(&1["name"]))
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

                <.node_config
                  selected={assigns.selected}
                  decisions={assigns[:decisions] || []}
                  actions={assigns[:actions] || []}
                  decision_editor_href={assigns[:decision_editor_href]}
                />

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
  attr(:decisions, :list, default: [])
  attr(:actions, :list, default: [])
  attr(:decision_editor_href, :any, default: nil)

  # A service task and a send task are configured identically — an action, typed
  # FEEL inputs, promoted signals — so they share one panel branch.
  def node_config(%{selected: %{type: type}} = assigns)
      when type in ["bpmn:ServiceTask", "bpmn:SendTask"] do
    action = assigns.selected.config["action"] || ""
    entry = Enum.find(assigns.actions, fn a -> to_string(a.ref) == action end)

    arg_rows =
      if entry do
        Enum.map(entry.args, fn arg ->
          %{"arg" => arg, "value" => arg_input_value(assigns.selected.config["inputs"], arg.name)}
        end)
      else
        []
      end

    assigns =
      assigns
      |> assign(:svc_action, action)
      |> assign(:svc_entry, entry)
      |> assign(:svc_arg_rows, arg_rows)
      |> assign(
        :svc_promote,
        rows(promote_signal_rows(assigns.selected.config["promote"]), %{
          "name" => "",
          "from" => "",
          "required" => "false"
        })
      )

    ~H"""
    <div class="mb-3">
      <label class={label_class()} for="config-action">Action</label>
      <%= if @actions == [] do %>
        <input
          id="config-action"
          type="text"
          name="action"
          value={@svc_action}
          class={field_class()}
          placeholder="my_app.do_something"
        />
      <% else %>
        <select
          id="config-action"
          name="action"
          phx-change="panel-changed"
          class={select_class(@svc_entry != nil or @svc_action == "")}
        >
          <option value="" selected={@svc_action == ""}>— choose an action —</option>
          <option :for={a <- @actions} value={a.ref} selected={to_string(a.ref) == @svc_action}>
            {a.label}
          </option>
        </select>
        <%= if @svc_action != "" and @svc_entry == nil do %>
          <p class="mt-1 text-xs text-red-600 dark:text-red-400">
            '{@svc_action}' is not in the action catalogue.
          </p>
        <% end %>
      <% end %>
    </div>

    <%= if @svc_entry != nil do %>
      <div class="mb-3">
        <label class={label_class()}>Arguments (FEEL)</label>
        <div :for={row <- @svc_arg_rows} class="mb-2">
          <div class="flex items-center gap-1 mb-1">
            <span class="text-xs font-medium text-zinc-700 dark:text-zinc-300">
              {row["arg"].name}
            </span>
            <span class="text-xs text-zinc-400 dark:text-zinc-500">{row["arg"].type}</span>
            <%= if row["arg"].allow_nil? == false do %>
              <span class="px-1 rounded bg-zinc-100 dark:bg-zinc-700 text-zinc-600 dark:text-zinc-300 text-xs">
                required
              </span>
            <% end %>
            <%= if row["arg"][:description] do %>
              <span class="text-xs text-zinc-400 dark:text-zinc-500" title={row["arg"][:description]}>
                ⓘ
              </span>
            <% end %>
          </div>
          <input
            type="text"
            name="inputs_from[]"
            value={row["value"]}
            class={field_class()}
            placeholder="FEEL, e.g. routing.risk_tier"
          />
        </div>
      </div>
    <% end %>

    <.promote_rows promote={@svc_promote} />
    """
  end

  def node_config(%{selected: %{type: "bpmn:BusinessRuleTask"}} = assigns) do
    decision = assigns.selected.config["decision"] || AshBpmn.Web.DesignerLive.empty_decision()
    ref = decision["ref"] || ""
    entry = Enum.find(assigns.decisions, fn d -> to_string(d.key) == ref end)

    assigns =
      assigns
      |> assign(:brt_decision, decision)
      |> assign(:brt_entry, entry)
      |> assign(
        :brt_inputs,
        rows(assigns.selected.config["inputs"], %{"name" => "", "from" => ""})
      )
      |> assign(
        :brt_promote,
        rows(promote_signal_rows(assigns.selected.config["promote"]), %{
          "name" => "",
          "from" => "",
          "required" => "false"
        })
      )
      |> assign(:brt_editor_href, decision_editor_href(assigns.decision_editor_href, ref))

    ~H"""
    <div class="mb-3">
      <label class={label_class()} for="config-decision-ref">Decision</label>
      <%= if @decisions == [] do %>
        <input
          id="config-decision-ref"
          type="text"
          name="decision_ref"
          value={@brt_decision["ref"]}
          class={field_class()}
          placeholder="my_app.decision_key"
        />
      <% else %>
        <select
          id="config-decision-ref"
          name="decision_ref"
          phx-change="panel-changed"
          class={select_class(@brt_entry != nil or @brt_decision["ref"] == "")}
        >
          <option value="" selected={@brt_decision["ref"] == ""}>— choose a decision —</option>
          <option :for={d <- @decisions} value={d.key} selected={to_string(d.key) == @brt_decision["ref"]}>
            {d.name || d.key}
          </option>
        </select>
        <%= if @brt_decision["ref"] != "" and @brt_entry == nil do %>
          <p class="mt-1 text-xs text-red-600 dark:text-red-400">
            '{@brt_decision["ref"]}' is not in the decision catalogue.
          </p>
        <% end %>
      <% end %>

      <%= if @brt_entry != nil do %>
        <div class="mt-1">
          <span class={["px-1.5 py-0.5 rounded-full text-xs font-medium", decision_badge_class(@brt_entry)]}>
            {decision_badge_text(@brt_entry)}
          </span>
        </div>
        <%= if drift?(@brt_decision, @brt_entry) do %>
          <p class="mt-1 text-xs text-amber-600 dark:text-amber-400">
            Pinned to v{@brt_decision["version"]}; latest published is v{@brt_entry.latest_published_version}.
          </p>
        <% end %>
      <% end %>

      <%= if @brt_editor_href do %>
        <div class="mt-1">
          <a
            href={@brt_editor_href}
            target="_blank"
            rel="noopener"
            class="text-xs text-indigo-600 dark:text-indigo-400 hover:underline"
          >
            Edit decision ↗
          </a>
        </div>
      <% end %>
    </div>

    <div class="mb-3">
      <label class={label_class()}>Binding</label>
      <select name="binding" phx-change="panel-changed" class={field_class()}>
        <option value="latest" selected={@brt_decision["binding"] != "pinned"}>latest</option>
        <option value="pinned" selected={@brt_decision["binding"] == "pinned"}>pinned</option>
      </select>
    </div>

    <%= if @brt_decision["binding"] == "pinned" do %>
      <div class="mb-3">
        <label class={label_class()} for="config-decision-version">Version</label>
        <input
          id="config-decision-version"
          type="text"
          name="version"
          value={@brt_decision["version"]}
          class={field_class()}
          placeholder="3"
        />
      </div>
    <% end %>

    <%= if @brt_entry != nil and length(@brt_entry.decisions) > 1 do %>
      <div class="mb-3">
        <label class={label_class()} for="config-decision-name">Decision name</label>
        <select id="config-decision-name" name="decision_name" class={field_class()}>
          <option
            :for={dec <- @brt_entry.decisions}
            value={dec.name}
            selected={dec.name == @brt_decision["name"]}
          >
            {dec.name}
          </option>
        </select>
      </div>
    <% end %>

    <div class="mb-3">
      <label class={label_class()}>Inputs</label>
      <div :for={input <- @brt_inputs} class="space-y-1 mb-2">
        <input
          type="text"
          name="inputs_name[]"
          value={input["name"]}
          class={field_class()}
          placeholder="name"
        />
        <input
          type="text"
          name="inputs_from[]"
          value={feel_text(input["from"])}
          class={field_class()}
          placeholder="FEEL from, e.g. subject.amount"
        />
      </div>
    </div>

    <.promote_rows promote={@brt_promote} />
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

  # Promote rows arrive as %{name, from, required-boolean}; the panel renders
  # required as a select, so normalize to the "true"/"false" strings once.
  defp promote_signal_rows(nil), do: []

  defp promote_signal_rows(entries) when is_list(entries) do
    Enum.map(entries, fn signal ->
      %{
        "name" => signal["name"] || "",
        "from" => signal["from"] || "",
        "required" => promote_required_string(signal)
      }
    end)
  end

  defp promote_required_string(signal) do
    if signal["required"] in [true, "true", "1"], do: "true", else: "false"
  end

  # An input's from arrives as the raw attribute text from the modeller; older
  # snapshots may carry the compiled stored map, so accept both.
  defp feel_text(%{"text" => text}) when is_binary(text), do: text
  defp feel_text(text) when is_binary(text), do: text
  defp feel_text(_), do: ""

  defp arg_input_value(inputs, arg_name) when is_list(inputs) do
    Enum.find_value(inputs, "", fn input ->
      if input["name"] == to_string(arg_name), do: feel_text(input["from"])
    end)
  end

  defp arg_input_value(_, _), do: ""

  defp decision_editor_href(fun, ref) when is_function(fun, 1) and ref != "", do: fun.(ref)
  defp decision_editor_href(_, _), do: nil

  # A pinned binding is drifting when the pinned version is not the latest published one.
  defp drift?(%{"binding" => "pinned"} = decision, entry) do
    latest = entry.latest_published_version
    decision["version"] != "" and latest != nil and decision["version"] != to_string(latest)
  end

  defp drift?(_, _), do: false

  defp decision_badge_class(%{status: :published}) do
    "bg-green-100 text-green-800 dark:bg-green-900 dark:text-green-200"
  end

  defp decision_badge_class(_),
    do: "bg-yellow-100 text-yellow-800 dark:bg-yellow-900 dark:text-yellow-200"

  defp decision_badge_text(%{status: :published, latest_published_version: version})
       when version != nil,
       do: "published v#{version}"

  defp decision_badge_text(%{status: :published}), do: "published"
  defp decision_badge_text(_), do: "draft"

  # Red border when a catalogue is present but the reference is not in it.
  defp select_class(true), do: field_class()
  defp select_class(false), do: field_class() <> " border-red-500 dark:border-red-500"

  attr(:promote, :list, required: true)

  defp promote_rows(assigns) do
    ~H"""
    <div class="mb-3">
      <label class={label_class()}>Promote</label>
      <div :for={signal <- @promote} class="space-y-1 mb-2">
        <input
          type="text"
          name="promote_name[]"
          value={signal["name"]}
          class={field_class()}
          placeholder="signal name"
        />
        <input
          type="text"
          name="promote_from[]"
          value={signal["from"]}
          class={field_class()}
          placeholder="from (defaults to name)"
        />
        <select name="promote_required[]" class={field_class()}>
          <option value="false" selected={signal["required"] != "true"}>false</option>
          <option value="true" selected={signal["required"] == "true"}>true</option>
        </select>
      </div>
    </div>
    """
  end

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
    config
    |> then(&Map.merge(empty_config(), &1))
    |> Map.put("decision", normalize_decision(Map.get(config, "decision")))
  end

  @doc false
  # The decision binding of a businessRuleTask, with every key the panel reads.
  def empty_decision do
    %{"ref" => "", "binding" => "latest", "version" => "", "name" => ""}
  end

  @doc """
  Resolves the `:decisions` or `:actions` catalogue option against the socket.

  Public rather than private, and taking the option value at runtime rather
  than branching in the using module: a host that passes no catalogue has a
  literal `nil` for the module attribute, and a per-host case on it would make
  the MFA clause provably dead — a dialyzer warning in every such host's build.
  Exported here once, the argument domain is open and every clause is live.

  Returns the catalogue entries, `[]` when the option is absent, and `[]` when
  the call fails: a catalogue outage must degrade the *panel* to free-text
  inputs, never break the page (usage-rules.md rule 13).
  """
  @spec resolve_catalogue(nil | {module(), atom(), list()}, Phoenix.LiveView.Socket.t()) :: list()
  def resolve_catalogue(nil, _socket), do: []

  def resolve_catalogue({module, function, args}, socket) do
    apply(module, function, args ++ [socket])
  rescue
    _ -> []
  end

  @doc """
  Resolves the `:decision_editor` option into the function the panel calls with
  a decision key to get its edit href, or `nil` when the option is absent (and
  so no "Edit decision" link is rendered). Runtime-dispatched in the library for
  the same reason as `resolve_catalogue/2`; a failing call resolves to `nil`.
  """
  @spec resolve_decision_editor_href(
          nil | {module(), atom(), list()},
          Phoenix.LiveView.Socket.t()
        ) :: (String.t() -> String.t() | nil) | nil
  def resolve_decision_editor_href(nil, _socket), do: nil

  def resolve_decision_editor_href({module, function, args}, socket) do
    fn key ->
      try do
        apply(module, function, args ++ [key, socket])
      rescue
        _ -> nil
      end
    end
  end

  defp normalize_decision(nil), do: empty_decision()

  defp normalize_decision(decision) when is_map(decision),
    do: Map.merge(empty_decision(), decision)

  defp empty_config do
    %{
      "action" => "",
      "outcome" => "",
      "decision" => empty_decision(),
      "candidates" => [],
      "exclusions" => [],
      "outcomes" => [],
      "timers" => [],
      "inputs" => [],
      "promote" => []
    }
  end
end
