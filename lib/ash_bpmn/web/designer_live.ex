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

  The service/send panel additionally offers the `ash:call` binding beside the
  legacy action: a dropdown of the callables the *configured* domains expose
  (`callables do ... end`, see `AshBpmn.Domain`), with one FEEL row per the
  callable's declared action argument. No option configures it — the list is
  read from `AshBpmn.Runtime.DomainResolver.domains/0` at mount and on every
  `handle_params`, the same cadence the catalogues use. Exactly one binding per
  task is the compiler's rule; picking one in the panel clears the other.

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
    * `apply_config` — update node extension elements, a sequence flow's
      condition expression, or an exclusive gateway's default flow
    * `highlight` — mark the elements named by compile errors on the canvas
    * `select_element` — select an element and bring it into view
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
           pending_publish: false,
           # Inline FEEL verdicts for the panel: %{field => :ok | {:error, msg}}.
           feel: %{}
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
          socket =
            push_event(socket, "load_xml", %{xml: socket.assigns.xml})

          # A definition that arrives with errors highlights its broken elements
          # right away; the hook replays the payload once the import resolves.
          socket =
            if socket.assigns.errors != [] do
              push_event(socket, "highlight", %{
                node_ids: AshBpmn.Web.DesignerLive.error_element_ids(socket.assigns.errors)
              })
            else
              socket
            end

          {:noreply, socket}
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

        {:noreply,
         socket
         |> assign(:selected, selected)
         # A new selection means new expressions; last selection's verdicts
         # would point at fields this panel may not even render.
         |> assign(:feel, %{})}
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

        config =
          build_config_from_params(
            params,
            socket.assigns[:actions] || [],
            socket.assigns[:callables] || []
          )

        payload = %{id: id, name: name, config: config}

        # A gateway condition and a gateway's default flow are not ash: config:
        # they live on the flow's conditionExpression child and the gateway's
        # default attribute. They travel beside the config so the hook can put
        # each part of the payload where the compiler reads it from.
        payload =
          case params["type"] do
            "bpmn:SequenceFlow" ->
              Map.put(payload, :condition, params["condition"] || "")

            "bpmn:ExclusiveGateway" ->
              Map.put(payload, :default_flow, params["default_flow"] || "")

            _ ->
              payload
          end

        {:noreply, push_event(socket, "apply_config", payload)}
      end

      # A select inside the properties panel changed before Apply — most usefully the
      # action select on a service task, whose declared argument rows only exist once
      # the action is chosen. Re-render the panel around the new selection.
      @impl true
      def handle_event("panel-changed", params, socket) do
        handle_panel_change(params, socket)
      end

      # Any FEEL-bearing field changed: validate it through the one FEEL seam
      # the package has and show the verdict next to the field, before Apply
      # is pressed and long before publish.
      @impl true
      def handle_event("validate-feel", params, socket) do
        handle_panel_change(params, socket)
      end

      # An error row was clicked: bring the offending element into view and
      # open its panel, through the same selection channel a canvas click uses.
      @impl true
      def handle_event("focus-error", %{"path" => path}, socket) do
        {:noreply, push_event(socket, "select_element", %{id: path})}
      end

      defp handle_panel_change(params, socket) do
        case socket.assigns[:selected] do
          nil ->
            {:noreply, socket}

          selected ->
            config =
              AshBpmn.Web.DesignerLive.merge_panel_config(
                params,
                selected.config,
                socket.assigns[:actions] || [],
                socket.assigns[:callables] || []
              )

            selected = %{
              selected
              | name: if(Map.has_key?(params, "name"), do: params["name"], else: selected.name),
                config: config
            }

            {:noreply,
             socket
             |> assign(:selected, selected)
             |> assign(:feel, AshBpmn.Web.DesignerLive.validate_feel(selected))}
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
      # The callable list rides along on the same cadence — its domains are app
      # config, but the refresh cost is one introspection pass and keeping the
      # two in step means the panel never shows a callable a fresh catalogue
      # disagrees with.
      defp ash_bpmn_load_catalogues(socket) do
        socket
        |> assign(:decisions, ash_bpmn_catalogue(@ash_bpmn_designer_decisions_mfa, socket))
        |> assign(:actions, ash_bpmn_catalogue(@ash_bpmn_designer_actions_mfa, socket))
        |> assign(:callables, AshBpmn.Web.DesignerLive.callable_entries())
        |> assign(:decision_editor_href, ash_bpmn_editor_href_fn(socket))
      end

      # A catalogue outage must degrade to free-text inputs, not to a broken page.
      defp ash_bpmn_catalogue(mfa, socket) do
        case mfa do
          nil -> []
          {m, f, a} -> apply(m, f, a ++ [socket])
        end
      rescue
        _ -> []
      end

      # The editor link is resolved per decision key at render time, against the socket
      # this navigation came in on.
      defp ash_bpmn_editor_href_fn(socket) do
        case @ash_bpmn_designer_decision_editor_mfa do
          nil ->
            nil

          {m, f, a} ->
            fn key ->
              try do
                apply(m, f, a ++ [key, socket])
              rescue
                _ -> nil
              end
            end
        end
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
        |> assign(:errors, AshBpmn.Web.DesignerLive.normalize_errors(definition.errors))
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
            |> assign(:errors, AshBpmn.Web.DesignerLive.normalize_errors(updated.errors))
            |> assign(:graph, updated.graph)
            |> assign(:dirty, false)
            |> put_flash(:info, "Saved")
            # An empty list clears whatever was highlighted: the errors surface
            # and the canvas markers must agree about what is broken.
            |> push_event("highlight", %{
              node_ids: AshBpmn.Web.DesignerLive.error_element_ids(updated.errors)
            })

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
            |> push_event("highlight", %{node_ids: []})

          {:error, error} ->
            socket
            |> assign(:pending_publish, false)
            |> put_flash(:error, Exception.message(error))
            |> push_event("highlight", %{
              node_ids: AshBpmn.Web.DesignerLive.error_element_ids(socket.assigns.errors)
            })
        end
      end

      defp build_config_from_params(params, actions, callables) do
        type = params["type"] || ""

        case type do
          "bpmn:ServiceTask" ->
            service_task_config(params, actions, callables)

          "bpmn:SendTask" ->
            service_task_config(params, actions, callables)

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

          # A flow's condition and a gateway's default are not ash: config —
          # handle_event/3 "update-config" carries them beside the config map.
          "bpmn:SequenceFlow" ->
            %{}

          "bpmn:ExclusiveGateway" ->
            %{}

          _ ->
            %{}
        end
      end

      # A service or send task carries exactly one binding — the compiler's
      # rule, mirrored here so what Apply writes can only ever be one: the
      # binding picker's mode decides which field is read, and the other binding
      # is authored empty. `binding_mode` rides in the config for the hook's
      # benefit and for the panel's own re-renders; moddle never sees it.
      defp service_task_config(params, actions, callables) do
        if params["binding_mode"] == "call" do
          %{
            "action" => "",
            "binding_mode" => "call",
            "call" => %{"ref" => params["call_ref"] || ""},
            "inputs" => parse_arg_inputs(params, "call_ref", callables),
            "promote" => parse_promote(params)
          }
        else
          %{
            "action" => params["action"] || "",
            "binding_mode" => "action",
            "call" => %{"ref" => ""},
            "inputs" => parse_arg_inputs(params, "action", actions),
            "promote" => parse_promote(params)
          }
        end
      end

      # One positional `inputs_from[]` per declared argument row, in the order the
      # panel rendered them — shared by both bindings, whose catalogue entries
      # carry the same `args` shape.
      defp parse_arg_inputs(params, ref_param, entries) do
        ref = params[ref_param] || ""

        case Enum.find(entries, fn entry -> to_string(entry.ref) == ref end) do
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
          <%!-- Errors surface: appears when the last save or publish produced
                compile errors, clears the moment one succeeds. Paths that name
                an element jump to it on the canvas. --%>
          <div id="ash-bpmn-errors" class={["px-4", assigns.errors != [] && "pt-3"]}>
            <%= if assigns.errors != [] do %>
              <div class="mb-2 rounded-lg border border-red-200 dark:border-red-800 bg-red-50 dark:bg-red-950 overflow-hidden">
                <div class="flex items-baseline gap-2 px-3 py-2 border-b border-red-200 dark:border-red-800">
                  <h2 id="bpmn-errors-count" class="text-sm font-semibold text-red-800 dark:text-red-200">
                    {length(assigns.errors)} {plural_word(length(assigns.errors))}
                  </h2>
                  <span class="text-xs text-red-600 dark:text-red-300">
                    Fix these, then save or publish again.
                  </span>
                </div>
                <ul class="divide-y divide-red-100 dark:divide-red-900" role="list">
                  <li
                    :for={{error, idx} <- Enum.with_index(assigns.errors)}
                    id={"bpmn-error-#{idx}"}
                    class="px-3 py-2 flex items-start gap-2"
                  >
                    <%= if jumpable_path?(error["path"]) do %>
                      <button
                        type="button"
                        id={"bpmn-error-jump-#{idx}"}
                        phx-click="focus-error"
                        phx-value-path={error["path"]}
                        title="Show this element in the diagram"
                        class="shrink-0 font-mono text-xs px-1.5 py-0.5 rounded bg-red-100 dark:bg-red-900 text-red-800 dark:text-red-200 hover:bg-red-200 dark:hover:bg-red-800 focus:outline-none focus-visible:ring-1 focus-visible:ring-red-500 transition-colors"
                      >
                        {error["path"]}
                      </button>
                    <% else %>
                      <span class="shrink-0 font-mono text-xs px-1.5 py-0.5 rounded bg-red-100 dark:bg-red-900 text-red-800 dark:text-red-200">
                        {error["path"] != "" && error["path"] || "process"}
                      </span>
                    <% end %>
                    <span class="text-xs leading-5 text-red-700 dark:text-red-300">
                      {error["message"]}
                    </span>
                  </li>
                </ul>
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
              <%!-- phx-change keeps FEEL fields validated as they are typed;
                    Apply (phx-submit) still carries every field itself. --%>
              <form id={"config-form-#{assigns.selected.id}"} phx-submit="update-config" phx-change="validate-feel">
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
                  callables={assigns[:callables] || []}
                  decision_editor_href={assigns[:decision_editor_href]}
                  feel={assigns[:feel]}
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
  # The `ash:call` dropdown's data: callables the configured domains expose,
  # each with its action's declared arguments.
  attr(:callables, :list, default: [])
  attr(:decision_editor_href, :any, default: nil)
  # Inline FEEL verdicts from the last phx-change, keyed "condition" and
  # "inputs:<row index>"; absent means "not validated yet".
  attr(:feel, :map, default: %{})

  # A sequence flow carries the gateway condition in its conditionExpression
  # child — the one FEEL expression the flow owns. The default flow of its
  # source gateway must not carry one, so that case reads instead of edits.
  def node_config(%{selected: %{type: "bpmn:SequenceFlow"}} = assigns) do
    assigns =
      assigns
      |> assign(:flow_condition, assigns.selected.config["condition"] || "")
      |> assign(:flow_default_of, assigns.selected.config["default_of"])

    ~H"""
    <%= if @flow_default_of do %>
      <div class="mb-3 rounded-md border border-zinc-200 dark:border-zinc-700 bg-zinc-50 dark:bg-zinc-800 p-2.5">
        <p class="text-xs leading-5 text-zinc-600 dark:text-zinc-300">
          Default flow of <span class="font-mono">{@flow_default_of}</span>.
          The source gateway takes it when no condition matches, so it must not carry one.
        </p>
      </div>
      <%!-- Still submits an (empty) condition so Apply clears any condition
            the flow should not have kept. --%>
      <input type="hidden" name="condition" value="" />
    <% else %>
      <div class="mb-3">
        <div class="flex items-baseline justify-between gap-2 mb-1">
          <label class={label_class()} for="config-condition">
            Condition (FEEL)
          </label>
          <span class="text-xs text-zinc-400 dark:text-zinc-500 whitespace-nowrap">
            equality is =, not ==
          </span>
        </div>
        <textarea
          id="config-condition"
          name="condition"
          rows="3"
          placeholder='routing.tier = "high"'
          phx-debounce="300"
          class={[
            field_class(),
            "font-mono leading-5 resize-y",
            feel_invalid?(@feel, "condition") && "border-red-400 dark:border-red-500"
          ]}
          aria-invalid={if feel_invalid?(@feel, "condition"), do: "true"}
        >{@flow_condition}</textarea>
        <.feel_feedback id="condition-feel-feedback" state={@feel["condition"]} />
      </div>
    <% end %>
    """
  end

  # An exclusive gateway routes on its outgoing flows' conditions; the default
  # flow is the one taken when nothing matches. The compiler demands every
  # outgoing flow is conditioned or exactly one is the default — the panel
  # shows each flow's state so that rule reads at a glance.
  def node_config(%{selected: %{type: "bpmn:ExclusiveGateway"}} = assigns) do
    assigns =
      assigns
      |> assign(:gw_outgoing, List.wrap(assigns.selected.config["outgoing"] || []))
      |> assign(:gw_default, assigns.selected.config["default"] || "")

    ~H"""
    <div class="mb-3">
      <label class={label_class()} for="config-default-flow">
        Default flow
      </label>
      <select
        id="config-default-flow"
        name="default_flow"
        phx-change="panel-changed"
        class={field_class()}
      >
        <option value="" selected={@gw_default == ""}>— none —</option>
        <option :for={flow <- @gw_outgoing} value={flow["id"]} selected={flow["id"] == @gw_default}>
          {flow_option_label(flow)}
        </option>
      </select>
      <p class="mt-1.5 text-xs leading-5 text-zinc-500 dark:text-zinc-400">
        Taken when no condition matches. Every outgoing flow needs a condition, or exactly one
        must be the default — and the default must not also carry a condition.
      </p>

      <%= if @gw_outgoing != [] do %>
        <ul class="mt-2 space-y-1" role="list">
          <li :for={flow <- @gw_outgoing} class="flex items-center gap-2 text-xs">
            <span class="truncate text-zinc-600 dark:text-zinc-300">
              {flow_label(flow)}
            </span>
            <% {badge_text, badge_class} = flow_badge(flow, @gw_default) %>
            <span class={["shrink-0 px-1.5 rounded-full", badge_class]}>
              {badge_text}
            </span>
          </li>
        </ul>
      <% end %>
    </div>
    """
  end

  # A service task and a send task are configured identically — exactly one
  # binding (the legacy action through the host's ActionInvoker, or a callable
  # declared on a configured domain), typed FEEL inputs, promoted signals — so
  # they share one panel branch. The binding picker offers both bindings the
  # compiler accepts; whichever is chosen, the rows below it are the selected
  # binding's declared arguments.
  def node_config(%{selected: %{type: type}} = assigns)
      when type in ["bpmn:ServiceTask", "bpmn:SendTask"] do
    action = assigns.selected.config["action"] || ""
    call_ref = call_ref(assigns.selected.config)

    mode =
      case assigns.selected.config["binding_mode"] do
        "call" -> "call"
        "action" -> "action"
        _ -> if blank?(call_ref), do: "action", else: "call"
      end

    callables = List.wrap(assigns.callables)

    entry =
      if mode == "call" do
        Enum.find(callables, fn c -> to_string(c.ref) == call_ref end)
      else
        Enum.find(assigns.actions, fn a -> to_string(a.ref) == action end)
      end

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
      |> assign(:svc_mode, mode)
      |> assign(:svc_action, action)
      |> assign(:svc_call_ref, call_ref)
      |> assign(:svc_callables, callables)
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
      <label class={label_class()} for="config-binding-mode">Binding</label>
      <select
        id="config-binding-mode"
        name="binding_mode"
        phx-change="panel-changed"
        class={field_class()}
      >
        <option value="action" selected={@svc_mode != "call"}>Action (host invoker)</option>
        <option value="call" selected={@svc_mode == "call"}>Callable (ash:call)</option>
      </select>
      <p class="mt-1.5 text-xs leading-5 text-zinc-500 dark:text-zinc-400">
        Exactly one binding per task — picking one clears the other.
      </p>
    </div>

    <%= if @svc_mode == "call" do %>
      <div class="mb-3">
        <label class={label_class()} for="config-call-ref">Callable</label>
        <%= if @svc_callables == [] do %>
          <p id="config-call-empty" class="text-xs leading-5 text-zinc-500 dark:text-zinc-400">
            No actions are exposed to diagrams — declare <code>callables</code> on a domain.
          </p>
          <%= if @svc_call_ref != "" do %>
            <%!-- The stray ref stays visible and submittable: Apply must not
                  silently erase a binding the panel was shown, and the publish
                  error is the honest way out. --%>
            <input type="hidden" name="call_ref" value={@svc_call_ref} />
            <p class="mt-1 text-xs text-red-600 dark:text-red-400">
              '{@svc_call_ref}' is not declared by any configured domain.
            </p>
          <% end %>
        <% else %>
          <select
            id="config-call-ref"
            name="call_ref"
            phx-change="panel-changed"
            class={select_class(@svc_entry != nil or @svc_call_ref == "")}
          >
            <option value="" selected={@svc_call_ref == ""}>— choose a callable —</option>
            <option :for={c <- @svc_callables} value={c.ref} selected={to_string(c.ref) == @svc_call_ref}>
              {c.label}
            </option>
          </select>
          <%= if @svc_call_ref != "" and @svc_entry == nil do %>
            <p class="mt-1 text-xs text-red-600 dark:text-red-400">
              '{@svc_call_ref}' is not declared by any configured domain.
            </p>
          <% end %>
        <% end %>
      </div>
    <% else %>
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
    <% end %>

    <%= if @svc_entry != nil do %>
      <div class="mb-3">
        <label class={label_class()}>Arguments (FEEL)</label>
        <div :for={{row, idx} <- Enum.with_index(@svc_arg_rows)} class="mb-2">
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
            phx-debounce="300"
            class={[
              field_class(),
              feel_invalid?(@feel, "inputs:#{idx}") && "border-red-400 dark:border-red-500"
            ]}
            placeholder="FEEL, e.g. routing.risk_tier"
          />
          <.feel_feedback id={"feel-feedback-inputs-#{idx}"} state={@feel["inputs:#{idx}"]} />
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
      <div :for={{input, idx} <- Enum.with_index(@brt_inputs)} class="space-y-1 mb-2">
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
          phx-debounce="300"
          class={[
            field_class(),
            "font-mono",
            feel_invalid?(@feel, "inputs:#{idx}") && "border-red-400 dark:border-red-500"
          ]}
          placeholder="FEEL from, e.g. subject.amount"
        />
        <.feel_feedback id={"feel-feedback-inputs-#{idx}"} state={@feel["inputs:#{idx}"]} />
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

  # The ash:call ref of a service/send config, blank when the task carries the
  # legacy action binding (or nothing) instead.
  defp call_ref(config) do
    case Map.get(config || %{}, "call") do
      %{"ref" => ref} when is_binary(ref) -> ref
      _ -> ""
    end
  end

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

  # The inline verdict under a FEEL field: the engine's message when the
  # expression will not parse, a quiet confirmation when it will, nothing at
  # all until the field has actually been validated.
  attr(:id, :string, required: true)
  attr(:state, :any, default: nil)

  defp feel_feedback(assigns) do
    ~H"""
    <%= case @state do %>
      <% {:error, message} -> %>
        <p id={@id} role="alert" class="mt-1 text-xs leading-5 text-red-600 dark:text-red-400">
          {message}
        </p>
      <% :ok -> %>
        <p id={@id} class="mt-1 text-xs leading-5 text-emerald-600 dark:text-emerald-400">
          Valid FEEL
        </p>
      <% _ -> %>
    <% end %>
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
  Normalizes compile errors to string-keyed maps.

  The compiler produces atom-keyed maps; the jsonb round-trip through the
  definition record hands them back with string keys. The errors surface and
  the highlight channel read one shape.
  """
  @spec normalize_errors(term()) :: [%{required(String.t()) => String.t()}]
  def normalize_errors(nil), do: []

  def normalize_errors(errors) when is_list(errors) do
    Enum.map(errors, fn
      %{} = error ->
        %{
          "path" => to_string(error[:path] || error["path"] || ""),
          "message" => to_string(error[:message] || error["message"] || "")
        }

      other ->
        %{"path" => "", "message" => to_string(other)}
    end)
  end

  # The compiler's synthetic paths — they name a problem, not an element on
  # the canvas.
  @non_element_paths ~w(process unknown xml)

  @doc false
  # The error paths that can name a canvas element. Ids that do not resolve
  # are skipped silently by the hook, so this can stay a plain allowlist.
  @spec error_element_ids(term()) :: [String.t()]
  def error_element_ids(errors) do
    errors
    |> normalize_errors()
    |> Enum.map(& &1["path"])
    |> Enum.reject(&(&1 in ["" | @non_element_paths]))
    |> Enum.uniq()
  end

  @doc false
  # The change-time mirror of the panel's submit-time parsing: it merges what
  # the form currently shows back into the selection WITHOUT dropping blank
  # rows. The submit parsers drop blank rows on purpose; dropping them at
  # change time would delete the row the user is typing into the moment a
  # validation re-render lands.
  @spec merge_panel_config(map(), map() | nil, list(), list()) :: map()
  def merge_panel_config(params, config, actions \\ [], callables \\ []) do
    config = config || %{}

    config =
      config
      |> merge_scalar(params, "action")
      |> merge_scalar(params, "outcome")
      |> merge_scalar(params, "condition")
      |> merge_scalar(params, "binding_mode")
      |> merge_default_flow(params)
      |> merge_call_ref(params)
      |> enforce_single_binding(params)

    config
    |> merge_decision(params)
    |> Map.put("inputs", merge_inputs(params, config, actions, callables))
    |> Map.put("promote", merge_promote(params, config))
    |> Map.put("candidates", merge_candidates(params, config))
    |> Map.put("exclusions", merge_exclusions(params, config))
    |> Map.put("outcomes", merge_outcomes(params, config))
    |> Map.put("timers", merge_timers(params, config))
  end

  defp merge_scalar(config, params, key) do
    if Map.has_key?(params, key), do: Map.put(config, key, params[key] || ""), else: config
  end

  # The form field is `default_flow`; the config the hook reads calls it
  # `default` — one rename, in one place.
  defp merge_default_flow(config, params) do
    if Map.has_key?(params, "default_flow") do
      Map.put(config, "default", params["default_flow"] || "")
    else
      config
    end
  end

  # The callable ref of the ash:call binding, the same merge-the-shown-field
  # contract every other scalar follows.
  defp merge_call_ref(config, params) do
    if Map.has_key?(params, "call_ref") do
      call = Map.get(config, "call") || empty_call()
      Map.put(config, "call", Map.put(call, "ref", params["call_ref"] || ""))
    else
      config
    end
  end

  # The binding picker's exactly-one rule, mirrored at change time: whichever
  # mode the panel is authoring, the other binding is cleared, so what Apply
  # eventually writes can only ever be one. The compiler polices what escapes;
  # the panel never authors both.
  defp enforce_single_binding(config, params) do
    case params["type"] do
      type when type in ["bpmn:ServiceTask", "bpmn:SendTask"] ->
        if service_binding_mode(params, config) == "call" do
          Map.put(config, "action", "")
        else
          Map.put(config, "call", empty_call())
        end

      _ ->
        config
    end
  end

  # Which binding a service/send panel is authoring: the picker's own value
  # when the change carried it, then the persisted pick, then whatever the
  # live config implies. A missing key must not guess "action" for a task the
  # XML bound with ash:call.
  defp service_binding_mode(params, config) do
    params["binding_mode"] || config["binding_mode"] ||
      if(blank?(call_ref(config)), do: "action", else: "call")
  end

  defp merge_decision(config, params) do
    keys = [
      {"decision_ref", "ref"},
      {"binding", "binding"},
      {"version", "version"},
      {"decision_name", "name"}
    ]

    if Enum.any?(keys, fn {param, _key} -> Map.has_key?(params, param) end) do
      decision =
        Enum.reduce(keys, Map.get(config, "decision") || empty_decision(), fn {param, key}, acc ->
          if Map.has_key?(params, param), do: Map.put(acc, key, params[param] || ""), else: acc
        end)

      Map.put(config, "decision", decision)
    else
      config
    end
  end

  defp merge_inputs(params, config, actions, callables) do
    cond do
      params["type"] in ["bpmn:ServiceTask", "bpmn:SendTask"] ->
        if service_binding_mode(params, config) == "call" do
          merge_arg_inputs(params, "call_ref", callables, config)
        else
          merge_arg_inputs(params, "action", actions, config)
        end

      Map.has_key?(params, "inputs_name") ->
        names = List.wrap(params["inputs_name"] || [])
        froms = pad(List.wrap(params["inputs_from"] || []), length(names))

        names
        |> Enum.zip_with(froms, fn name, from -> %{"name" => name || "", "from" => from || ""} end)

      true ->
        Map.get(config, "inputs") || []
    end
  end

  # The change-time mirror of the arg rows: blank froms are KEPT, or the row
  # the user is typing into disappears under the validation re-render.
  defp merge_arg_inputs(params, ref_param, entries, config) do
    ref = params[ref_param] || ""
    entry = Enum.find(entries, fn e -> to_string(e.ref) == ref end)

    if entry != nil and Map.has_key?(params, "inputs_from") do
      froms = pad(List.wrap(params["inputs_from"] || []), length(entry.args))

      entry.args
      |> Enum.zip_with(froms, fn arg, from ->
        %{"name" => to_string(arg.name), "from" => from || ""}
      end)
    else
      Map.get(config, "inputs") || []
    end
  end

  defp merge_promote(params, config) do
    if Map.has_key?(params, "promote_name") do
      names = List.wrap(params["promote_name"] || [])
      froms = pad(List.wrap(params["promote_from"] || []), length(names))
      required = pad(List.wrap(params["promote_required"] || []), length(names))

      [names, froms, required]
      |> Enum.zip_with(fn [name, from, req] ->
        %{"name" => name || "", "from" => from || "", "required" => to_string(req) == "true"}
      end)
    else
      Map.get(config, "promote") || []
    end
  end

  defp merge_candidates(params, config) do
    if Map.has_key?(params, "candidates_kind") do
      kinds = List.wrap(params["candidates_kind"] || [])
      ofs = pad(List.wrap(params["candidates_of"] || []), length(kinds))

      kinds
      |> Enum.zip_with(ofs, fn kind, of -> %{"kind" => kind || "", "of" => of || ""} end)
    else
      Map.get(config, "candidates") || []
    end
  end

  defp merge_exclusions(params, config) do
    if Map.has_key?(params, "exclusions_who") do
      params["exclusions_who"]
      |> List.wrap()
      |> Enum.map(&%{"who" => &1 || ""})
    else
      Map.get(config, "exclusions") || []
    end
  end

  defp merge_outcomes(params, config) do
    if Map.has_key?(params, "outcomes_name") do
      params["outcomes_name"]
      |> List.wrap()
      |> Enum.map(&(&1 || ""))
    else
      Map.get(config, "outcomes") || []
    end
  end

  defp merge_timers(params, config) do
    if Map.has_key?(params, "timers_kind") do
      kinds = List.wrap(params["timers_kind"] || [])
      values = pad(List.wrap(params["timers_value"] || []), length(kinds))
      units = pad(List.wrap(params["timers_unit"] || []), length(kinds))

      [kinds, values, units]
      |> Enum.zip_with(fn [kind, value, unit] ->
        %{"kind" => kind || "", (unit || "hours") => parse_integer(value)}
      end)
    else
      Map.get(config, "timers") || []
    end
  end

  @doc false
  # Validates every FEEL expression the panel is editing — a gateway condition,
  # or the `from` of each declared input row — through the one FEEL seam the
  # package has. Blank fields are absent from the map: blank means "no
  # expression", not "invalid".
  @spec validate_feel(%{optional(any()) => any()}) :: %{
          optional(String.t()) => :ok | {:error, String.t()}
        }
  def validate_feel(%{type: "bpmn:SequenceFlow", config: config}) do
    case validate_feel_field(config["condition"]) do
      nil -> %{}
      result -> %{"condition" => result}
    end
  end

  def validate_feel(%{type: type, config: config})
      when type in ["bpmn:BusinessRuleTask", "bpmn:ServiceTask", "bpmn:SendTask"] do
    config
    |> Map.get("inputs")
    |> List.wrap()
    |> Enum.with_index()
    |> Enum.flat_map(fn {input, idx} ->
      case validate_feel_field(feel_text(input["from"])) do
        nil -> []
        result -> [{"inputs:#{idx}", result}]
      end
    end)
    |> Map.new()
  end

  def validate_feel(_other), do: %{}

  defp validate_feel_field(source) when is_binary(source) do
    if blank?(source) do
      nil
    else
      case AshBpmn.Feel.compile(source) do
        {:ok, _stored} -> :ok
        {:error, message} -> {:error, equality_note(source, message)}
      end
    end
  end

  defp validate_feel_field(_other), do: nil

  # The engine's parse errors are terse ("expected expression"); a `==` in the
  # source is the one mistake whose cause the panel can name with confidence.
  defp equality_note(source, message) do
    if String.contains?(source, "==") do
      message <> " — FEEL equality is =, not =="
    else
      message
    end
  end

  # ── Panel display helpers ─────────────────────────────────────────────

  defp feel_invalid?(feel, key), do: match?({:error, _message}, feel[key])

  defp plural_word(1), do: "problem"
  defp plural_word(_count), do: "problems"

  defp jumpable_path?(path), do: path != "" and path not in @non_element_paths

  defp flow_label(flow) do
    if blank?(flow["name"]), do: flow["id"], else: flow["name"]
  end

  defp flow_option_label(flow) do
    flow_label(flow) <>
      if flow["condition"], do: " — has condition", else: " — no condition"
  end

  # The state each outgoing flow is in, against the chosen default: green is a
  # conditioned flow, indigo the default, amber an unconditioned flow the
  # compiler will refuse at publish, red the impossible combination.
  defp flow_badge(flow, default_id) do
    cond do
      flow["id"] == default_id and flow["condition"] ->
        {"default + condition", "bg-red-100 dark:bg-red-900 text-red-700 dark:text-red-200"}

      flow["id"] == default_id ->
        {"default", "bg-indigo-100 dark:bg-indigo-900 text-indigo-700 dark:text-indigo-200"}

      flow["condition"] ->
        {"condition", "bg-emerald-100 dark:bg-emerald-900 text-emerald-700 dark:text-emerald-200"}

      true ->
        {"no condition", "bg-amber-100 dark:bg-amber-900 text-amber-700 dark:text-amber-200"}
    end
  end

  defp pad(list, size) do
    list ++ List.duplicate(nil, max(size - length(list), 0))
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

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_), do: false

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
    |> Map.put("call", normalize_call(Map.get(config, "call")))
  end

  @doc false
  # The decision binding of a businessRuleTask, with every key the panel reads.
  def empty_decision do
    %{"ref" => "", "binding" => "latest", "version" => "", "name" => ""}
  end

  defp normalize_decision(nil), do: empty_decision()

  defp normalize_decision(decision) when is_map(decision),
    do: Map.merge(empty_decision(), decision)

  @doc false
  # The ash:call binding of a service/send task, with every key the panel reads.
  def empty_call do
    %{"ref" => ""}
  end

  defp normalize_call(nil), do: empty_call()

  defp normalize_call(call) when is_map(call), do: Map.merge(empty_call(), call)

  defp empty_config do
    %{
      "action" => "",
      "outcome" => "",
      "decision" => empty_decision(),
      "call" => empty_call(),
      "candidates" => [],
      "exclusions" => [],
      "outcomes" => [],
      "timers" => [],
      "inputs" => [],
      "promote" => [],
      # Gateway condition / default-flow vocabulary: the flow's FEEL condition,
      # the gateway it is the default of, and the gateway's outgoing flows.
      "condition" => "",
      "default_of" => nil,
      "default" => "",
      "outgoing" => []
    }
  end

  @doc """
  Builds the callable catalogue the service/send panel's `ash:call` mode offers.

  Walks the configured ash domains (`AshBpmn.Runtime.DomainResolver.domains/0`
  — the same allowlist publish verification and the runtime resolve refs
  against), reads each domain's declared `callables`, and renders each as the
  diagram spelling `"Domain.name"` with the callable's action arguments
  introspected alongside: `%{ref, label, description, args}`, the same entry
  shape the action catalogue uses, so the panel's argument rows render
  identically for both bindings.

  Total: a domain that cannot be introspected is skipped, not fatal — a broken
  callable degrades the dropdown by one entry, and an unreachable domain list
  degrades it to the panel's quiet empty state. Never a raise, never the engine.
  """
  @spec callable_entries() :: [map()]
  def callable_entries do
    AshBpmn.Runtime.DomainResolver.domains()
    |> Enum.flat_map(fn domain ->
      domain
      |> AshBpmn.Domain.callables()
      |> Enum.map(&callable_entry(domain, &1))
      |> Enum.reject(&is_nil/1)
    end)
  rescue
    _ -> []
  end

  # One dropdown row per declared callable. The arguments come through the same
  # `AshBpmn.Catalogue.AshActions` builder the action catalogue uses, so the
  # type labels and required badges cannot drift between the two bindings.
  defp callable_entry(domain, callable) do
    args =
      AshBpmn.Catalogue.AshActions.entries([
        {callable.name, callable.resource, callable.action}
      ])
      |> hd()
      |> Map.get(:args)

    name = Atom.to_string(callable.name)
    description = callable.description

    %{
      # `inspect`, not interpolation: a module's string form carries the
      # `Elixir.` prefix, and the diagram spelling — what callable?/2 resolves
      # and the compiler verifies — has none.
      ref: "#{inspect(domain)}.#{callable.name}",
      label: callable_label(name, description),
      description: description,
      args: args
    }
  rescue
    # A callable whose action no longer introspects (stale compile, renamed
    # action) is absent from the dropdown — which is also what publish will
    # say about any diagram still spelling it.
    _ -> nil
  end

  defp callable_label(name, nil), do: name
  defp callable_label(name, description), do: name <> " — " <> description
end
