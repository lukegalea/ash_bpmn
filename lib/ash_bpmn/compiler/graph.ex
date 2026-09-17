# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.Compiler.Graph do
  @moduledoc false

  alias AshBpmn.Compiler.Errors
  alias AshBpmn.Compiler.Xml

  @spec build(map()) :: {:ok, map()} | {:error, [map()]}
  def build(process, error_declarations \\ %{}) do
    errors = []
    process_id = process.id || ""

    # Check isExecutable
    errors =
      if process.is_executable == "true" do
        errors
      else
        [Errors.error(process_id || "process", "isExecutable must be true") | errors]
      end

    # Collect all nodes and flows
    nodes_xml = Xml.collect_all_nodes(process.xml)
    flows_xml = Xml.collect_all_flows(process.xml)

    # Check for unsupported elements
    {supported_nodes, unsupported_errors} = filter_supported_nodes(nodes_xml)
    errors = errors ++ unsupported_errors

    # Check for unsupported non-flow elements (catch anything not in our subset)
    # We look for children of the process that are not our supported types,
    # not sequenceFlow, and not DI
    errors = errors ++ check_unsupported_process_children(process.xml, supported_nodes, flows_xml)

    # Check the children of supported nodes: a construct nested *inside* a node
    # we support changes what that node means (a timerEventDefinition turns a
    # none-start into a timed start), so an unimplemented one must refuse the
    # publish rather than execute as if it were not there.
    errors = errors ++ check_node_children(supported_nodes)

    # Build nodes map
    {nodes, node_errors} = build_nodes(supported_nodes, error_declarations)
    errors = errors ++ node_errors

    # Build flows map
    {flows, flow_errors} = build_flows(flows_xml, nodes)
    errors = errors ++ flow_errors

    if errors != [] do
      {:error, Enum.reverse(errors)}
    else
      # Determine start and build joins for parallel gateways
      start_node = find_start(nodes)
      joins = build_joins(nodes, flows)
      boundaries = build_boundaries(nodes)

      graph = %{
        "process_id" => process_id,
        "start" => start_node,
        "nodes" => nodes,
        "flows" => flows,
        "joins" => joins,
        "boundaries" => boundaries,
        # Conditions are stored as source text so an in-flight instance keeps
        # evaluating across engine upgrades -- but *which* engine validated
        # them at publish time is a fact about the definition, stamped here so
        # the upgrade is visible in the snapshot rather than silent.
        "feel_engine" => %{
          "name" => "boxic_feel",
          "version" => engine_version(:boxic_feel)
        }
      }

      {:ok, graph}
    end
  end

  # Mirrors how ash_decisions stamps its engines: the OTP app version at the
  # time of the build, or "unknown" when the app cannot be introspected.
  defp engine_version(app) do
    case Application.spec(app, :vsn) do
      nil -> "unknown"
      vsn -> to_string(vsn)
    end
  end

  defp filter_supported_nodes(nodes_xml) do
    {supported, unsupported} =
      Enum.split_with(nodes_xml, fn node ->
        Xml.supported_node_type?(Xml.node_type(node))
      end)

    unsupported_errors =
      Enum.map(unsupported, fn node ->
        id = Xml.element_attr(node, "id") || "unknown"
        type = Xml.node_type(node)

        Errors.error(
          id,
          "Node '#{id}' of type '#{type}' is not supported; the executable subset is: #{Xml.supported_subset_message()}"
        )
      end)

    {supported, unsupported_errors}
  end

  # ── Unsupported-construct classification ─────────────────────────────────
  #
  # The compiler is honest about what it does not implement. Constructs nested
  # in a document fall into three classes:
  #
  #   * *Benign* -- consumed by the engine (`incoming`/`outgoing`,
  #     `extensionElements`, `conditionExpression`) or carrying no execution
  #     semantics to lose (`documentation`, `laneSet`, annotations, host
  #     extensions under foreign namespaces). Ignored, deliberately.
  #   * *Known-and-unimplemented* -- BPMN constructs with execution semantics
  #     (event definitions, loop characteristics, data IO, unimplemented
  #     activity and gateway kinds). These get an explicit "not supported"
  #     refusal, because executing the node as if the construct were absent
  #     would publish a process that means something else than it says.
  #   * *Unrecognized* -- anything else in the BPMN namespace. Also refused;
  #     the message says so rather than pretending the element was understood.

  @benign_process_children MapSet.new(
                             Xml.supported_node_types() ++
                               ~w(sequenceFlow extensionElements documentation laneSet textAnnotation group association auditing monitoring)
                           )

  # Children of a supported flow node. `incoming`/`outgoing` are the standard
  # serialization of the flow references -- flows are collected from
  # `sequenceFlow` elements, so these are redundant, but every bpmn-js document
  # carries them and they say nothing the flows do not.
  @benign_node_children MapSet.new(~w(incoming outgoing documentation extensionElements))

  # Event definitions the compiler implements, and the node types they may legally sit on.
  # Keyed both ways round on purpose: a `terminateEventDefinition` is meaningful on an end
  # event and meaningless on a start event, and accepting it anywhere would let a diagram
  # carry a marker the engine ignores -- which is the failure mode the unsupported-child
  # check exists to prevent, arriving through the door marked "supported".
  @implemented_event_definitions %{
    "terminateEventDefinition" => ["endEvent"],
    "timerEventDefinition" => ["intermediateCatchEvent", "boundaryEvent"],
    "errorEventDefinition" => ["endEvent"],
    "messageEventDefinition" => ["intermediateCatchEvent"]
  }

  # Children of a `timerEventDefinition`. Only `timeDuration` is implemented; the other two are
  # listed so they refuse with their own name rather than as an unrecognized element, because a
  # modeller who drew a timer with a cycle needs to be told that *cycles* are not supported, not
  # that BPMN contains no such element.
  @timer_definition_children MapSet.new(~w(timeDuration timeDate timeCycle))

  @known_unimplemented MapSet.new(~w(
    timerEventDefinition messageEventDefinition signalEventDefinition
    errorEventDefinition escalationEventDefinition conditionalEventDefinition
    compensationEventDefinition cancelEventDefinition
    linkEventDefinition multiInstanceLoopCharacteristics standardLoopCharacteristics
    dataInputAssociation dataOutputAssociation dataStore dataStoreReference
    ioSpecification dataInput dataOutput inputSet outputSet property
    dataObject dataObjectReference resourceRole performer humanPerformer
    potentialOwner correlationSubscription supports
    callActivity subProcess adHocSubProcess transaction
    receiveTask scriptTask manualTask task
    complexGateway eventBasedGateway
    intermediateThrowEvent
  ))

  defp check_unsupported_process_children(process_xml, _supported_nodes, _flows_xml) do
    # Get all direct children of the process
    process_xml
    |> Xml.get_element_children()
    |> Enum.flat_map(fn child ->
      # Normalize *before* classifying: `<bpmn:subProcess>` and
      # `<bpmn2:subProcess>` are the same element and must refuse the same way.
      normalized = Xml.normalize_name(Xml.local_name(child))
      id = Xml.element_attr(child, "id") || "unknown"

      cond do
        Xml.di_element?(normalized) ->
          []

        normalized in @benign_process_children ->
          []

        bpmn_prefixed_or_bare?(Xml.local_name(child)) ->
          [unsupported_process_child_error(id, normalized)]

        true ->
          # Foreign *namespace* only -- a prefixed name under something that is not BPMN.
          # Hosts carry their own vocabularies here (`ash:`, `camunda:`, `zeebe:`) and those
          # are not the compiler's to rule on.
          #
          # This used to read `Xml.bpmn_prefixed?` and treat a bare name as foreign, which was
          # exactly backwards. `Xml.parse/1` scans without `:namespace_conform`, so a document
          # binding BPMN as its *default* namespace writes `<subProcess>` with no prefix, and
          # every such element fell through here unrefused. That is not merely "ignored": the
          # node collector uses a `//` xpath, so any supported node inside a bare subprocess is
          # hoisted and compiled as a direct child of the process, with the subprocess boundary
          # silently erased. A prefixed `<bpmn:subProcess>` could never do that, because this
          # check refused it first.
          #
          # The one case this now gets wrong is a child that re-declares a default xmlns onto
          # itself (`<thing xmlns="urn:vendor">`), which reads as bare and is refused. No BPMN
          # tool writes that, and without `:namespace_conform` there is nothing to tell it
          # apart -- so it is accepted as the price of closing the hole.
          []
      end
    end)
  end

  defp unsupported_process_child_error(id, normalized) do
    subset = Xml.supported_subset_message()

    if MapSet.member?(@known_unimplemented, normalized) do
      Errors.error(
        id,
        "Node '#{id}' of type '#{normalized}' is not supported; the executable subset is: #{subset}"
      )
    else
      Errors.error(
        id,
        "Unknown BPMN element '#{normalized}' (id '#{id}'); the executable subset is: #{subset}"
      )
    end
  end

  # Every direct child of a supported node -- and every direct child of that
  # node's `extensionElements` -- must be something the compiler implements.
  # The ash: vocabulary inside extensionElements is parsed by the node config
  # builders (which do their own unknown-element refusals); anything else in
  # the BPMN namespace would silently change the node's meaning.
  defp check_node_children(nodes_xml) do
    Enum.flat_map(nodes_xml, fn node ->
      id = Xml.element_attr(node, "id") || "unknown"
      type = Xml.node_type(node)

      direct = Xml.get_element_children(node)

      inside_extensions =
        direct
        |> Enum.filter(&(Xml.normalize_name(Xml.local_name(&1)) == "extensionElements"))
        |> Enum.flat_map(&Xml.get_element_children/1)

      Enum.flat_map(direct, &node_child_error(id, type, &1, :direct)) ++
        Enum.flat_map(inside_extensions, &node_child_error(id, type, &1, :extensions))
    end)
  end

  # Classifies one child of a supported node. `:direct` children and children
  # of the node's `extensionElements` differ in where foreign content may sit:
  # extensionElements is *the* place hosts put their own extensions (foreign
  # and bare names there are left to the config parsers), while directly under
  # a node only the known-inert serialization elements are allowed -- a bare
  # or BPMN-prefixed child there is BPMN content and must be recognized.
  defp node_child_error(id, type, child, placement) do
    raw = Xml.local_name(child)
    normalized = Xml.normalize_name(raw)

    bpmn? =
      case placement do
        :direct -> bpmn_prefixed_or_bare?(raw)
        :extensions -> Xml.bpmn_prefixed?(raw)
      end

    cond do
      placement == :direct and normalized in @benign_node_children ->
        []

      not bpmn? ->
        []

      Map.has_key?(@implemented_event_definitions, normalized) ->
        if type in @implemented_event_definitions[normalized] do
          []
        else
          # Deliberately not "meaningless". A timer *start* event is perfectly good BPMN that
          # this engine does not implement, while a terminate marker on a start event is not
          # BPMN at all -- and the compiler has no business ruling on which is which. What it
          # can say truthfully in both cases is where the marker is supported, which is also
          # the thing the modeller needs in order to redraw it.
          [
            Errors.error(
              id,
              "#{type} '#{id}' has a '#{normalized}', which is not supported there; " <>
                "#{normalized} is supported on: " <>
                Enum.join(@implemented_event_definitions[normalized], ", ")
            )
          ]
        end

      MapSet.member?(@known_unimplemented, normalized) ->
        [
          Errors.error(
            id,
            "#{type} '#{id}' has a '#{normalized}' child, which is not supported; " <>
              "the node would execute as if it were not there"
          )
        ]

      true ->
        [
          Errors.error(
            id,
            "#{type} '#{id}' has an unrecognized BPMN child '#{normalized}'"
          )
        ]
    end
  end

  # A BPMN-namespace name: explicitly prefixed with bpmn2:/bpmn:, or bare (a
  # document using BPMN as its default namespace).
  defp bpmn_prefixed_or_bare?("bpmn2:" <> _), do: true
  defp bpmn_prefixed_or_bare?("bpmn:" <> _), do: true
  defp bpmn_prefixed_or_bare?(name), do: not String.contains?(name, ":")

  @doc false
  def definitions_warnings(doc, process, graph) do
    siblings = Xml.definitions_siblings(doc)

    if siblings == [] do
      []
    else
      referenced_ids =
        graph["nodes"]
        |> Map.keys()
        |> Enum.concat([process.id])
        |> MapSet.new()

      message_flow_warnings(siblings, referenced_ids) ++
        participant_warnings(siblings, referenced_ids)
    end
  end

  defp message_flow_warnings(siblings, referenced_ids) do
    siblings
    |> Xml.descendants("messageFlow")
    |> Enum.filter(fn flow ->
      Enum.any?(["sourceRef", "targetRef"], fn attr ->
        ref = Xml.element_attr(flow, attr)
        ref != nil and MapSet.member?(referenced_ids, ref)
      end)
    end)
    |> Enum.map(fn flow ->
      id = Xml.element_attr(flow, "id") || "unknown"

      Errors.error(
        id,
        "messageFlow '#{id}' connects to this process; message flows are not executed " <>
          "and have been ignored"
      )
    end)
  end

  defp participant_warnings(siblings, referenced_ids) do
    siblings
    |> Xml.descendants("participant")
    |> Enum.filter(fn participant ->
      ref = Xml.element_attr(participant, "processRef")
      ref != nil and MapSet.member?(referenced_ids, ref)
    end)
    |> Enum.map(fn participant ->
      id = Xml.element_attr(participant, "id") || "unknown"

      Errors.error(
        id,
        "participant '#{id}' references this process; collaborations are not executed " <>
          "and have been ignored"
      )
    end)
  end

  defp build_nodes(nodes_xml, error_declarations) do
    nodes =
      nodes_xml
      |> Enum.map(fn node -> build_node(node, error_declarations) end)
      |> Enum.filter(fn
        {:ok, _} -> true
        _ -> false
      end)
      |> Enum.map(fn {:ok, {id, data}} -> {id, data} end)
      |> Map.new()

    node_errors =
      nodes_xml
      |> Enum.map(fn node -> build_node(node, error_declarations) end)
      |> Enum.filter(fn
        {:error, _} -> true
        _ -> false
      end)
      |> Enum.map(fn {:error, e} -> e end)

    {nodes, node_errors}
  end

  defp build_node(node, error_declarations) do
    id = Xml.element_attr(node, "id")
    type = Xml.node_type(node)
    name = Xml.element_attr(node, "name")

    if id == nil do
      {:error, Errors.error("unknown", "Node has no id attribute")}
    else
      base = %{"type" => type, "name" => name}

      case build_node_config(node, type, error_declarations) do
        {:ok, config} ->
          {:ok, {id, Map.merge(base, config)}}

        {:error, error} ->
          {:error, error}
      end
    end
  end

  # A business rule task references a decision by name and declares, explicitly, what goes in
  # and what comes back out into routing. Both halves are deliberate.
  #
  # Inputs are declared rather than "the whole subject" so a decision cannot quietly start
  # depending on a field nobody meant to expose to it, and so the engine -- not the host --
  # evaluates the expressions.
  #
  # Outputs are *promoted* one named scalar at a time rather than merged wholesale, because a
  # token carries routing and not business data. The decision's full result goes to the host's
  # own record and to a process event; only the declared signals reach the token.
  defp build_node_config(node, "businessRuleTask", _error_declarations) do
    id = Xml.element_attr(node, "id")
    ext = Xml.find_extension_elements(node)

    case Xml.find_ash_elements(ext, "decision") do
      [] ->
        {:error,
         Errors.error(
           id,
           "businessRuleTask '#{id}' must have an ash:decision element with a non-empty ref attribute"
         )}

      [decision | _] ->
        build_business_rule_config(id, ext, decision)
    end
  end

  # A service or send task carries exactly one binding, and the compiler refuses both
  # or neither: the legacy `ash:taskConfig action=`, dispatched through the host's
  # ActionInvoker, or `ash:call`, a host Ash action invoked through the engine scope.
  # The action is the only required part of the legacy binding; the typed FEEL inputs
  # and promoted signals are optional on both and, when absent, are left off the node
  # entirely so documents written before they existed compile exactly as they always
  # did.
  defp build_node_config(node, type, _error_declarations)
       when type in ["serviceTask", "sendTask"] do
    id = Xml.element_attr(node, "id")
    ext = Xml.find_extension_elements(node)

    ash_task_configs = Xml.find_ash_elements(ext, "taskConfig")
    ash_calls = Xml.find_ash_elements(ext, "call")

    case {ash_calls, ash_task_configs} do
      {[], []} ->
        {:error,
         Errors.error(
           id,
           "#{type} '#{id}' must have an ash:taskConfig with a non-empty action attribute " <>
             "or an ash:call with a non-empty ref"
         )}

      {[_ | _], [_ | _]} ->
        {:error,
         Errors.error(
           id,
           "#{type} '#{id}' must not have both an ash:taskConfig and an ash:call; " <>
             "exactly one binding per service task"
         )}

      {[], [config | _]} ->
        action = Xml.element_attr(config, "action")

        cond do
          action == nil or String.trim(action) == "" ->
            {:error,
             Errors.error(
               id,
               "#{type} '#{id}' ash:taskConfig must have a non-empty action attribute"
             )}

          unknown_task_config_attr?(config, ["action"]) ->
            {k, _} = unknown_task_config_attr(config, ["action"])

            {:error,
             Errors.error(
               id,
               "Unknown ash: attribute '#{k}' on ash:taskConfig for #{type} '#{id}'"
             )}

          true ->
            with {:ok, inputs} <- build_inputs(type, id, ext),
                 {:ok, promote} <- build_promotions(type, id, ext) do
              # Absent means absent: a service task written before typed inputs existed
              # must produce the same node it always produced.
              config_map =
                %{"action" => action}
                |> maybe_put("inputs", inputs)
                |> maybe_put("promote", promote)

              # Check for unknown ash child elements
              check_unknown_ash_children(
                config,
                node,
                ["candidates", "exclusions", "outcomes", "timers"],
                config_map
              )
            end
        end

      {[call | _], []} ->
        build_call_config(type, id, ext, call)
    end
  end

  defp build_node_config(node, "userTask", _error_declarations) do
    ext = Xml.find_extension_elements(node)
    ash_task_configs = Xml.find_ash_elements(ext, "taskConfig")

    case ash_task_configs do
      [] ->
        {:error,
         Errors.error(
           Xml.element_attr(node, "id"),
           "userTask '#{Xml.element_attr(node, "id")}' must have an ash:taskConfig"
         )}

      [config | _] ->
        # Check for unknown ash attributes
        known_attrs = MapSet.new([])
        ash_attrs = Xml.find_ash_attributes(config)
        unknown_ash = ash_attrs |> Enum.filter(fn {k, _} -> k not in known_attrs end)

        if unknown_ash != [] do
          {k, _} = hd(unknown_ash)

          {:error,
           Errors.error(
             Xml.element_attr(node, "id"),
             "Unknown ash: attribute '#{k}' on ash:taskConfig for userTask '#{Xml.element_attr(node, "id")}'"
           )}
        else
          build_user_task_config(config, node)
        end
    end
  end

  defp build_node_config(node, "endEvent", error_declarations) do
    id = Xml.element_attr(node, "id")
    ext = Xml.find_extension_elements(node)
    ash_task_configs = Xml.find_ash_elements(ext, "taskConfig")

    # Read straight off the XML rather than inferred later: the marker is what makes this end
    # event end the whole process instead of just this branch, and that difference has to be
    # visible in the compiled snapshot or the interpreter cannot act on it.
    terminate? =
      node
      |> Xml.get_element_children()
      |> Enum.any?(&(Xml.normalize_name(Xml.local_name(&1)) == "terminateEventDefinition"))

    error_definitions =
      node
      |> Xml.get_element_children()
      |> Enum.filter(&(Xml.normalize_name(Xml.local_name(&1)) == "errorEventDefinition"))

    with {:ok, error} <- build_error_end(id, error_definitions, error_declarations),
         :ok <- check_end_markers(id, terminate?, error) do
      base =
        %{}
        |> then(&if(terminate?, do: Map.put(&1, "terminate", true), else: &1))
        |> then(&if(error, do: Map.put(&1, "error", error), else: &1))

      end_event_task_config(node, ash_task_configs, base)
    end
  end

  defp build_node_config(node, "boundaryEvent", _error_declarations) do
    id = Xml.element_attr(node, "id")
    ref = Xml.element_attr(node, "attachedToRef")

    definitions =
      node
      |> Xml.get_element_children()
      |> Enum.filter(&(Xml.normalize_name(Xml.local_name(&1)) == "timerEventDefinition"))

    with :ok <- check_attached_ref(id, ref),
         :ok <- check_cancel_activity(id, Xml.element_attr(node, "cancelActivity")),
         {:ok, definition} <- single_boundary_definition(id, definitions),
         {:ok, %{"catch" => spec}} <- build_timer_catch(id, definition) do
      {:ok, %{"attached_to" => String.trim(ref), "catch" => spec}}
    end
  end

  defp build_node_config(node, "intermediateCatchEvent", _error_declarations) do
    id = Xml.element_attr(node, "id")

    definitions =
      node
      |> Xml.get_element_children()
      |> Enum.filter(
        &(Xml.normalize_name(Xml.local_name(&1)) in [
            "timerEventDefinition",
            "messageEventDefinition"
          ])
      )

    case definitions do
      [] ->
        # A catch event with no definition is a catch with nothing to catch: the token would
        # park and never be woken by anything. Refused rather than compiled into a deadlock.
        {:error,
         Errors.error(
           id,
           "intermediateCatchEvent '#{id}' has no event definition; the token would wait " <>
             "for something that can never arrive. Supported: timerEventDefinition, " <>
             "messageEventDefinition"
         )}

      [_, _ | _] ->
        {:error,
         Errors.error(id, "intermediateCatchEvent '#{id}' has more than one event definition")}

      [definition] ->
        case Xml.normalize_name(Xml.local_name(definition)) do
          "timerEventDefinition" -> build_timer_catch(id, definition)
          "messageEventDefinition" -> build_message_catch(id, node)
        end
    end
  end

  defp build_node_config(node, "exclusiveGateway", _error_declarations) do
    default_flow = Xml.element_attr(node, "default")
    {:ok, Map.filter(%{"default_flow" => default_flow}, fn {_, v} -> v != nil end)}
  end

  defp build_node_config(_node, type, _error_declarations)
       when type in ["startEvent", "parallelGateway"] do
    {:ok, %{}}
  end

  # A message catch waits for something that happens elsewhere in the application. The
  # `messageEventDefinition` says *that* it waits; the `ash:subscribe` element says what for,
  # because BPMN's own message plumbing (a `bpmn:message` declaration and a collaboration's
  # message flows) describes messages between pools and has nothing to say about an Ash
  # resource and action.
  #
  #   <bpmn2:intermediateCatchEvent id="AwaitPayment">
  #     <bpmn2:messageEventDefinition id="Msg_1"/>
  #     <bpmn2:extensionElements>
  #       <ash:subscribe resource="Payment" action="create"
  #                      correlate="subject.id" match="data.invoice_id"/>
  #     </bpmn2:extensionElements>
  #   </bpmn2:intermediateCatchEvent>
  #
  # Two expressions, evaluated at different times against different things, and the split is
  # the whole correlation model. `correlate` runs once at park against the subject, and the
  # answer is frozen onto the token -- so a subject edited during the wait cannot silently
  # change what the token is listening for. `match` runs at delivery against the arriving
  # event. A token is woken when the two answers are equal.
  defp build_message_catch(id, node) do
    ext = Xml.find_extension_elements(node)

    case Xml.find_ash_elements(ext, "subscribe") do
      [] ->
        {:error,
         Errors.error(
           id,
           "intermediateCatchEvent '#{id}' catches a message but declares no ash:subscribe, " <>
             "so nothing says which event it is waiting for"
         )}

      [_, _ | _] ->
        {:error,
         Errors.error(id, "intermediateCatchEvent '#{id}' has more than one ash:subscribe")}

      [subscribe] ->
        build_message_subscription(id, subscribe)
    end
  end

  defp build_message_subscription(id, subscribe) do
    resource = Xml.element_attr(subscribe, "resource")
    action = Xml.element_attr(subscribe, "action")
    correlate = Xml.element_attr(subscribe, "correlate")
    match = Xml.element_attr(subscribe, "match")

    cond do
      blank?(resource) ->
        {:error, Errors.error(id, "ash:subscribe on '#{id}' has no resource")}

      blank?(correlate) or blank?(match) ->
        {:error,
         Errors.error(
           id,
           "ash:subscribe on '#{id}' needs both correlate and match. Without them every " <>
             "event of that kind would wake every token waiting for one, which is not " <>
             "correlation, it is a broadcast"
         )}

      true ->
        # Both parse at publish time, for the same reason flow conditions do: an expression
        # that cannot parse should be a compile error naming the node, not a token that parks
        # and is never woken because its key could not be computed at three in the morning.
        with {:ok, correlate_stored} <- AshBpmn.Feel.compile(correlate),
             {:ok, match_stored} <- AshBpmn.Feel.compile(match) do
          {:ok,
           %{
             "catch" => %{
               "kind" => "message",
               "resource" => resource,
               "action" => action,
               "correlate" => correlate_stored,
               "match" => match_stored
             }
           }}
        else
          {:error, reason} ->
            {:error,
             Errors.error(id, "ash:subscribe on '#{id}' has an invalid expression: #{reason}")}
        end
    end
  end

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_), do: false

  # An error end event says the process ended badly *on purpose*, which is a thing no diagram
  # could say before: `mark_failed` is reachable only from retry exhaustion and means "the
  # engine gave up". That distinction is the entire payoff, and it is why the runtime gives it
  # its own instance status rather than reusing `:failed`.
  #
  # Error *boundary* events are a separate matter and stay refused. `ActionInvoker.invoke/2`
  # returns `{:error, term()}` with no error code, so nothing distinguishes a modelled business
  # error from Postgres being unreachable -- and catching would route a transient outage down
  # the "credit declined" branch.
  defp build_error_end(_id, [], _declarations), do: {:ok, nil}

  defp build_error_end(id, [_, _ | _], _declarations),
    do: {:error, Errors.error(id, "endEvent '#{id}' has more than one errorEventDefinition")}

  defp build_error_end(id, [definition], declarations) do
    case Xml.element_attr(definition, "errorRef") do
      nil ->
        {:error,
         Errors.error(
           id,
           "endEvent '#{id}' throws an error with no errorRef. An anonymous error can be " <>
             "caught by anything, so nothing downstream could tell which error was thrown"
         )}

      ref ->
        case Map.fetch(declarations, ref) do
          {:ok, declaration} ->
            {:ok, Map.put(declaration, "ref", ref)}

          :error ->
            {:error,
             Errors.error(
               id,
               "endEvent '#{id}' references error '#{ref}', which is not declared. A " <>
                 "bpmn:error element with that id must sit beside the process, not inside it"
             )}
        end
    end
  end

  # Both markers on one end event is well-formed XML and two different endings. The runtime
  # would take whichever it checked first and drop the other -- a marker drawn on the diagram
  # and silently ignored, which is the failure the whole refusal walk exists to prevent.
  defp check_end_markers(id, true, error) when not is_nil(error) do
    {:error,
     Errors.error(
       id,
       "endEvent '#{id}' carries both a terminateEventDefinition and an " <>
         "errorEventDefinition. They are two different endings and one would be ignored"
     )}
  end

  defp check_end_markers(_id, _terminate?, _error), do: :ok

  defp end_event_task_config(node, ash_task_configs, base) do
    case ash_task_configs do
      [] ->
        {:ok, base}

      [config | _] ->
        outcome = Xml.element_attr(config, "outcome")

        # Check for unknown ash attributes
        known_attrs = MapSet.new(["outcome"])
        ash_attrs = Xml.find_ash_attributes(config)

        unknown_ash =
          ash_attrs |> Enum.filter(fn {k, _} -> k not in known_attrs end)

        if unknown_ash != [] do
          {k, _} = hd(unknown_ash)

          {:error,
           Errors.error(
             Xml.element_attr(node, "id"),
             "Unknown ash: attribute '#{k}' on ash:taskConfig for endEvent '#{Xml.element_attr(node, "id")}'"
           )}
        else
          # Check for unknown child elements
          check_unknown_ash_children(
            config,
            node,
            ["candidates", "exclusions", "outcomes", "timers"]
          )
          |> case do
            {:ok, _} ->
              if outcome do
                {:ok, Map.put(base, "outcome", outcome)}
              else
                {:ok, base}
              end

            {:error, _} = err ->
              err
          end
        end
    end
  end

  # An intermediate catch event: the token stops here until something happens. Today the only
  # something is a timer.
  #
  # The delay is an ISO 8601 duration, read straight from `bpmn:timeDuration`, because that is
  # what BPMN specifies and what every modelling tool writes. Inventing `hours="4"` here would
  # mean a diagram drawn in Camunda or bpmn.io carries a delay this compiler cannot see -- the
  # single-artifact rule turned inside out.
  # A boundary event attaches to an activity rather than sitting on a sequence flow: when it
  # fires, the activity is interrupted and the branch leaves through the boundary's own flow.
  #
  # It is compiled as an ordinary entry in `nodes`, carrying `attached_to`, with a derived
  # `boundaries` index built beside `joins`. Keeping it out of `nodes` is the tempting shape
  # and breaks immediately: `build_flow/2` resolves every sequence flow's `sourceRef` against
  # `nodes`, so the boundary's own outgoing flow would fail with an error about the *flow*
  # referencing a non-existent source -- pointing the modeller away from the boundary.

  defp check_attached_ref(id, ref) when is_binary(ref) do
    if String.trim(ref) == "" do
      {:error, Errors.error(id, "boundaryEvent '#{id}' has an empty attachedToRef")}
    else
      :ok
    end
  end

  defp check_attached_ref(id, _ref) do
    {:error,
     Errors.error(
       id,
       "boundaryEvent '#{id}' has no attachedToRef; a boundary event with nothing to " <>
         "attach to is a decoration the diagram presents as control flow"
     )}
  end

  # `cancelActivity` defaults to true, which is the interrupting case and the only one
  # supported. Non-interrupting is refused by name rather than ignored: it spawns a second
  # branch while the activity keeps running, and the engine has no token topology for that --
  # no fork relating the two and no join that could reunite them.
  defp check_cancel_activity(_id, value) when value in [nil, "true", "1"], do: :ok

  defp check_cancel_activity(id, value) when value in ["false", "0"] do
    {:error,
     Errors.error(
       id,
       "boundaryEvent '#{id}' is non-interrupting (cancelActivity=\"false\"), which is not " <>
         "supported: it would run a second branch alongside the activity, and there is no " <>
         "join that could ever reunite them"
     )}
  end

  defp check_cancel_activity(id, value) do
    {:error,
     Errors.error(id, "boundaryEvent '#{id}' has a non-boolean cancelActivity '#{value}'")}
  end

  defp single_boundary_definition(_id, [definition]), do: {:ok, definition}

  defp single_boundary_definition(id, []) do
    {:error,
     Errors.error(
       id,
       "boundaryEvent '#{id}' has no event definition; it would attach to the activity and " <>
         "never fire. Supported: timerEventDefinition"
     )}
  end

  defp single_boundary_definition(id, _many) do
    {:error, Errors.error(id, "boundaryEvent '#{id}' has more than one event definition")}
  end

  defp build_timer_catch(id, definition) do
    children =
      definition
      |> Xml.get_element_children()
      |> Enum.map(&{Xml.normalize_name(Xml.local_name(&1)), &1})

    unsupported =
      Enum.filter(children, fn {name, _} ->
        name in @timer_definition_children and name != "timeDuration"
      end)

    case {unsupported, List.keyfind(children, "timeDuration", 0)} do
      {[{name, _} | _], _} ->
        {:error,
         Errors.error(
           id,
           "timer '#{id}' uses '#{name}', which is not supported; use timeDuration " <>
             "(an ISO 8601 duration such as PT4H or P2D)"
         )}

      {[], nil} ->
        {:error,
         Errors.error(id, "timer '#{id}' has no timeDuration; an ISO 8601 duration is required")}

      {[], {_, element}} ->
        source = element |> Xml.element_text() |> to_string() |> String.trim()

        # Parsed at publish time, not at three in the morning when the token arrives. A
        # duration that cannot be read is a compile error naming the node; a duration read
        # lazily is a process that parks and then fails to ever wake.
        case parse_duration(source) do
          {:ok, seconds} ->
            {:ok, %{"catch" => %{"kind" => "timer", "duration" => source, "seconds" => seconds}}}

          {:error, reason} ->
            {:error,
             Errors.error(id, "timer '#{id}' has an invalid duration '#{source}': #{reason}")}
        end
    end
  end

  # Months and years are refused rather than approximated. ISO 8601 allows them, but their
  # length depends on when you start counting, and a process that fires "in one month" at a
  # different instant depending on the day it parked is not a thing to hand an auditor. A
  # modeller who wants a month writes P30D and means it.
  defp parse_duration(source) do
    case Duration.from_iso8601(source) do
      {:ok, %Duration{month: m, year: y}} when m != 0 or y != 0 ->
        {:error, "months and years are not supported because their length is not fixed; use days"}

      {:ok, duration} ->
        seconds =
          duration.week * 604_800 + duration.day * 86_400 + duration.hour * 3600 +
            duration.minute * 60 + duration.second

        if seconds > 0 do
          {:ok, seconds}
        else
          {:error, "a timer must wait for a positive amount of time"}
        end

      {:error, reason} ->
        {:error, to_string(reason)}
    end
  end

  # An `ash:call` names a callable the host declared in a domain's `callables` block —
  # the same reference spelling as `ash:decision`, `"Domain.name"`. Whether the ref
  # actually resolves, and whether the declared inputs name real arguments of the
  # callable, is the publish-time check in verify.ex; here the vocabulary is parsed and
  # its shape enforced. Inputs and promotions are the shared vocabulary of every node
  # kind that declares them (usage rule 12), so they are extracted by the same code and
  # land at the node level, exactly as on a businessRuleTask.
  defp build_call_config(type, id, ext, call) do
    ref = Xml.element_attr(call, "ref")

    cond do
      ref == nil or String.trim(ref) == "" ->
        {:error, Errors.error(id, "#{type} '#{id}' ash:call must have a non-empty ref attribute")}

      unknown_call_attr?(call) ->
        {k, _} = unknown_call_attr(call)

        {:error,
         Errors.error(id, "Unknown ash: attribute '#{k}' on ash:call for #{type} '#{id}'")}

      has_children?(call) ->
        name = call |> Xml.get_element_children() |> hd() |> Xml.local_name()

        {:error, Errors.error(id, "Unknown ash: element '#{name}' in ash:call for '#{id}'")}

      true ->
        with {:ok, inputs} <- build_inputs(type, id, ext),
             {:ok, promote} <- build_promotions(type, id, ext) do
          {:ok,
           %{"call" => %{"ref" => String.trim(ref)}}
           |> maybe_put("inputs", inputs)
           |> maybe_put("promote", promote)}
        end
    end
  end

  # `ref` is a plain attribute; anything else on the element — plain or
  # ash:-prefixed — is a typo, and moddle would drop it on the next save anyway.
  @known_call_attrs MapSet.new(["ref"])

  defp unknown_call_attr(call) do
    call
    |> Xml.element_attrs()
    |> Enum.find(fn {k, _} -> k not in @known_call_attrs end)
  end

  defp unknown_call_attr?(call), do: unknown_call_attr(call) != nil

  defp has_children?(call),
    do: Xml.get_element_children(call) != []

  defp build_business_rule_config(id, ext, decision) do
    ref = Xml.element_attr(decision, "ref")
    binding = Xml.element_attr(decision, "binding") || "latest"
    version = Xml.element_attr(decision, "version")
    # The name of the decision inside a multi-decision key. Optional; an empty
    # name is a typo, not a choice, so it is refused rather than trimmed away.
    name = Xml.element_attr(decision, "name")

    cond do
      ref == nil or String.trim(ref) == "" ->
        {:error,
         Errors.error(
           id,
           "businessRuleTask '#{id}' ash:decision must have a non-empty ref attribute"
         )}

      binding not in ["latest", "pinned"] ->
        {:error,
         Errors.error(
           id,
           "businessRuleTask '#{id}' ash:decision binding must be \"latest\" or \"pinned\", got #{inspect(binding)}"
         )}

      # A pinned binding without a version is the dangerous default: it reads as "this will not
      # move under me" and behaves as "latest".
      binding == "pinned" and (version == nil or String.trim(version) == "") ->
        {:error,
         Errors.error(
           id,
           "businessRuleTask '#{id}' ash:decision binding=\"pinned\" requires a version"
         )}

      name != nil and String.trim(name) == "" ->
        {:error,
         Errors.error(
           id,
           "businessRuleTask '#{id}' ash:decision name must be non-empty when present"
         )}

      true ->
        with {:ok, inputs} <- build_inputs("businessRuleTask", id, ext),
             {:ok, promote} <- build_promotions("businessRuleTask", id, ext) do
          decision_config =
            %{
              "ref" => String.trim(ref),
              "binding" => binding,
              "version" => version
            }
            |> maybe_put("name", name && String.trim(name))

          {:ok,
           %{
             "decision" => decision_config,
             "inputs" => inputs,
             "promote" => promote
           }}
        end
    end
  end

  # ── Shared inputs & promotions ───────────────────────────────────────────
  #
  # Declared inputs and promoted signals mean the same thing on every node kind that
  # carries them -- a decision call and an action call take their arguments from the same
  # context and promote onto the same token -- so both are extracted and validated here,
  # once, and every node's snapshot entries come out identical by construction.

  defp build_inputs(kind, node_id, ext) do
    ext
    |> Xml.find_ash_elements("inputs")
    |> Enum.flat_map(&Xml.find_ash_elements([&1], "input"))
    |> Enum.reduce_while({:ok, []}, fn input, {:ok, acc} ->
      name = Xml.element_attr(input, "name")
      from = Xml.element_attr(input, "from")

      cond do
        name == nil or String.trim(name) == "" ->
          {:halt, {:error, Errors.error(node_id, "#{kind} '#{node_id}' ash:input needs a name")}}

        from == nil or String.trim(from) == "" ->
          {:halt,
           {:error,
            Errors.error(
              node_id,
              "#{kind} '#{node_id}' ash:input '#{name}' needs a from expression"
            )}}

        true ->
          # The `from` expression is validated here, at publish time, for the same reason a
          # gateway condition is: a node that cannot build its inputs should fail
          # when someone publishes it, not when an instance reaches it.
          case AshBpmn.Feel.compile(from) do
            {:ok, stored} ->
              {:cont, {:ok, [%{"name" => String.trim(name), "from" => stored} | acc]}}

            {:error, message} ->
              {:halt,
               {:error,
                Errors.error(
                  node_id,
                  "#{kind} '#{node_id}' ash:input '#{name}' from expression is not valid FEEL: #{message}"
                )}}
          end
      end
    end)
    |> case do
      {:ok, inputs} -> {:ok, Enum.reverse(inputs)}
      error -> error
    end
  end

  @max_promoted_signals 8

  defp build_promotions(kind, node_id, ext) do
    signals =
      ext
      |> Xml.find_ash_elements("promote")
      |> Enum.flat_map(&Xml.find_ash_elements([&1], "signal"))

    names = Enum.map(signals, &(Xml.element_attr(&1, "name") || ""))

    cond do
      Enum.any?(names, &(String.trim(&1) == "")) ->
        {:error, Errors.error(node_id, "#{kind} '#{node_id}' ash:signal needs a name")}

      length(Enum.uniq(names)) != length(names) ->
        {:error,
         Errors.error(
           node_id,
           "#{kind} '#{node_id}' promotes the same signal name twice"
         )}

      length(signals) > @max_promoted_signals ->
        {:error,
         Errors.error(
           node_id,
           "#{kind} '#{node_id}' promotes #{length(signals)} signals; at most " <>
             "#{@max_promoted_signals} are allowed -- a token carries routing, not business data"
         )}

      true ->
        {:ok,
         Enum.map(signals, fn signal ->
           name = signal |> Xml.element_attr("name") |> String.trim()

           %{
             "name" => name,
             # Which of the callee's outputs this signal takes. Defaults to the signal's own
             # name, which is the common case; `from` exists because the name a decision gives
             # an output and the name a process wants to route on are different vocabularies
             # owned by different people, and forcing them to coincide makes one of them
             # rename to suit the other.
             "from" => (Xml.element_attr(signal, "from") || name) |> String.trim(),
             "required" => Xml.element_attr(signal, "required") in ["true", "1"]
           }
         end)}
    end
  end

  defp unknown_task_config_attr(config, known_attrs) do
    config
    |> Xml.find_ash_attributes()
    |> Enum.find(fn {k, _} -> k not in known_attrs end)
  end

  defp unknown_task_config_attr?(config, known_attrs) do
    unknown_task_config_attr(config, known_attrs) != nil
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, []), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp build_user_task_config(config, node) do
    id = Xml.element_attr(node, "id")

    # Check for unknown ash child elements
    known_children = MapSet.new(["candidates", "exclusions", "outcomes", "timers"])

    children = Xml.get_element_children(config)

    unknown_children =
      Enum.filter(children, fn child ->
        name = Xml.normalize_name(Xml.local_name(child))
        name not in known_children
      end)

    if unknown_children != [] do
      name = Xml.local_name(hd(unknown_children))

      {:error,
       Errors.error(id, "Unknown ash: element '#{name}' in ash:taskConfig for userTask '#{id}'")}
    else
      # Parse candidates
      candidates =
        config
        |> Xml.find_children("candidates")
        |> Enum.flat_map(&Xml.get_element_children/1)
        |> Enum.map(fn cand ->
          %{
            "kind" => Xml.element_attr(cand, "kind"),
            "of" => Xml.element_attr(cand, "of")
          }
        end)
        |> Enum.filter(fn c -> c["kind"] != nil end)

      # Parse exclusions
      exclusions =
        config
        |> Xml.find_children("exclusions")
        |> Enum.flat_map(&Xml.get_element_children/1)
        |> Enum.map(fn excl ->
          %{"who" => Xml.element_attr(excl, "who")}
        end)
        |> Enum.filter(fn e -> e["who"] != nil end)

      # Parse outcomes
      outcomes =
        config
        |> Xml.find_children("outcomes")
        |> Enum.flat_map(&Xml.get_element_children/1)
        |> Enum.map(&Xml.element_attr(&1, "name"))
        |> Enum.filter(&(&1 != nil))

      # Parse timers
      timers =
        config
        |> Xml.find_children("timers")
        |> Enum.flat_map(&Xml.get_element_children/1)
        |> Enum.map(&parse_timer/1)
        |> Enum.filter(&(&1 != nil))

      # Validate: >=1 candidate, >=1 outcome
      cond do
        candidates == [] ->
          {:error, Errors.error(id, "userTask '#{id}' must have at least one candidate")}

        outcomes == [] ->
          {:error, Errors.error(id, "userTask '#{id}' must have at least one outcome")}

        true ->
          config_map =
            %{
              "candidates" => candidates,
              "exclusions" => exclusions,
              "outcomes" => outcomes,
              "timers" => timers
            }
            |> Map.filter(fn {_, v} -> v != [] end)

          {:ok, config_map}
      end
    end
  end

  defp parse_timer(timer_el) do
    kind = Xml.element_attr(timer_el, "kind")

    minutes =
      cond do
        m = Xml.element_attr(timer_el, "minutes") -> String.to_integer(m)
        h = Xml.element_attr(timer_el, "hours") -> String.to_integer(h) * 60
        d = Xml.element_attr(timer_el, "days") -> String.to_integer(d) * 60 * 24
        true -> nil
      end

    if kind != nil and minutes != nil do
      %{"kind" => kind, "minutes" => minutes}
    else
      nil
    end
  end

  defp check_unknown_ash_children(config, node, known_children, extra \\ %{}) do
    id = Xml.element_attr(node, "id")
    known = MapSet.new(known_children)
    children = Xml.get_element_children(config)

    unknown =
      Enum.find(children, fn child ->
        name = Xml.normalize_name(Xml.local_name(child))
        name not in known
      end)

    if unknown do
      name = Xml.local_name(unknown)

      {:error, Errors.error(id, "Unknown ash: element '#{name}' in ash:taskConfig for '#{id}'")}
    else
      {:ok, extra}
    end
  end

  defp build_flows(flows_xml, nodes) do
    flows =
      flows_xml
      |> Enum.map(fn flow -> build_flow(flow, nodes) end)
      |> Enum.filter(fn
        {:ok, _} -> true
        _ -> false
      end)
      |> Enum.map(fn {:ok, {id, data}} -> {id, data} end)
      |> Map.new()

    flow_errors =
      flows_xml
      |> Enum.map(fn flow -> build_flow(flow, nodes) end)
      |> Enum.filter(fn
        {:error, _} -> true
        _ -> false
      end)
      |> Enum.map(fn {:error, e} -> e end)

    {flows, flow_errors}
  end

  defp build_flow(flow, nodes) do
    id = Xml.element_attr(flow, "id")
    source_ref = Xml.element_attr(flow, "sourceRef")
    target_ref = Xml.element_attr(flow, "targetRef")

    cond do
      id == nil ->
        {:error, Errors.error("unknown", "sequenceFlow has no id attribute")}

      source_ref == nil ->
        {:error, Errors.error(id, "sequenceFlow '#{id}' has no sourceRef")}

      target_ref == nil ->
        {:error, Errors.error(id, "sequenceFlow '#{id}' has no targetRef")}

      not Map.has_key?(nodes, source_ref) ->
        {:error,
         Errors.error(
           id,
           "sequenceFlow '#{id}' references non-existent source node '#{source_ref}'"
         )}

      not Map.has_key?(nodes, target_ref) ->
        {:error,
         Errors.error(
           id,
           "sequenceFlow '#{id}' references non-existent target node '#{target_ref}'"
         )}

      true ->
        # Parse condition expression
        condition =
          flow
          |> Xml.find_children("conditionExpression")
          |> List.first()
          |> case do
            nil ->
              nil

            expr_el ->
              # BPMN lets a formal expression declare its language. We accept FEEL and
              # nothing else -- and say so rather than ignoring the attribute, because a
              # document written against JUEL or Groovy would otherwise be published and
              # then quietly evaluated as FEEL, which is how a diagram and a system come to
              # mean different things.
              case Xml.element_attr(expr_el, "language") do
                lang when lang in [nil, "", "feel", "FEEL"] ->
                  :ok

                lang ->
                  throw(
                    {:flow_parse_error, id,
                     "conditionExpression language #{inspect(lang)} is not supported; " <>
                       "conditions are FEEL"}
                  )
              end

              body = Xml.element_text(expr_el)

              if body != nil and String.trim(body) != "" do
                case AshBpmn.Feel.compile(body) do
                  {:ok, stored} ->
                    stored

                  {:error, msg} ->
                    throw({:flow_parse_error, id, msg})
                end
              else
                nil
              end
          end

        {:ok,
         {id,
          %{
            "from" => source_ref,
            "to" => target_ref,
            "condition" => condition
          }}}
    end
  catch
    {:flow_parse_error, flow_id, msg} ->
      {:error, Errors.error(flow_id, "conditionExpression parse error: #{msg}")}
  end

  defp find_start(nodes) do
    nodes
    |> Enum.find(fn {_id, node} -> node["type"] == "startEvent" end)
    |> elem(0)
  end

  # Activity id -> the boundary events attached to it. Derived from `nodes` the way `joins`
  # is, so it cannot disagree with them. A list rather than a single id: one activity may
  # legitimately carry several boundaries.
  defp build_boundaries(nodes) do
    nodes
    |> Enum.filter(fn {_id, node} -> node["type"] == "boundaryEvent" end)
    |> Enum.group_by(fn {_id, node} -> node["attached_to"] end, fn {id, _node} -> id end)
  end

  defp build_joins(nodes, flows) do
    nodes
    |> Enum.filter(fn {id, node} ->
      node["type"] == "parallelGateway" and
        Enum.count(flows, fn {_fid, f} -> f["to"] == id end) > 1
    end)
    |> Enum.map(fn {id, _node} ->
      waits_for =
        flows
        |> Enum.filter(fn {_fid, f} -> f["to"] == id end)
        |> Enum.map(fn {_fid, f} -> f["from"] end)

      {id, %{"waits_for" => waits_for}}
    end)
    |> Map.new()
  end
end
