# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.Compiler.Graph do
  @moduledoc false

  alias AshBpmn.Compiler.Errors
  alias AshBpmn.Compiler.Xml

  @spec build(map()) :: {:ok, map()} | {:error, [map()]}
  def build(process) do
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
    {nodes, node_errors} = build_nodes(supported_nodes)
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

      graph = %{
        "process_id" => process_id,
        "start" => start_node,
        "nodes" => nodes,
        "flows" => flows,
        "joins" => joins,
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

  @known_unimplemented MapSet.new(~w(
    timerEventDefinition messageEventDefinition signalEventDefinition
    errorEventDefinition escalationEventDefinition conditionalEventDefinition
    compensationEventDefinition terminateEventDefinition cancelEventDefinition
    linkEventDefinition multiInstanceLoopCharacteristics standardLoopCharacteristics
    dataInputAssociation dataOutputAssociation dataStore dataStoreReference
    ioSpecification dataInput dataOutput inputSet outputSet property
    callActivity subProcess adHocSubProcess transaction
    receiveTask scriptTask manualTask task
    complexGateway eventBasedGateway intermediateCatchEvent
    intermediateThrowEvent boundaryEvent
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

        Xml.bpmn_prefixed?(Xml.local_name(child)) ->
          [unsupported_process_child_error(id, normalized)]

        true ->
          # Foreign namespace or bare name at process level - ignore silently
          # (hosts may carry other extensions)
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

  defp build_nodes(nodes_xml) do
    nodes =
      nodes_xml
      |> Enum.map(fn node -> build_node(node) end)
      |> Enum.filter(fn
        {:ok, _} -> true
        _ -> false
      end)
      |> Enum.map(fn {:ok, {id, data}} -> {id, data} end)
      |> Map.new()

    node_errors =
      nodes_xml
      |> Enum.map(fn node -> build_node(node) end)
      |> Enum.filter(fn
        {:error, _} -> true
        _ -> false
      end)
      |> Enum.map(fn {:error, e} -> e end)

    {nodes, node_errors}
  end

  defp build_node(node) do
    id = Xml.element_attr(node, "id")
    type = Xml.node_type(node)
    name = Xml.element_attr(node, "name")

    if id == nil do
      {:error, Errors.error("unknown", "Node has no id attribute")}
    else
      base = %{"type" => type, "name" => name}

      case build_node_config(node, type) do
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
  defp build_node_config(node, "businessRuleTask") do
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
  defp build_node_config(node, type) when type in ["serviceTask", "sendTask"] do
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

  defp build_node_config(node, "userTask") do
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

  defp build_node_config(node, "endEvent") do
    ext = Xml.find_extension_elements(node)
    ash_task_configs = Xml.find_ash_elements(ext, "taskConfig")

    case ash_task_configs do
      [] ->
        {:ok, %{}}

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
                {:ok, %{"outcome" => outcome}}
              else
                {:ok, %{}}
              end

            {:error, _} = err ->
              err
          end
        end
    end
  end

  defp build_node_config(node, "exclusiveGateway") do
    default_flow = Xml.element_attr(node, "default")
    {:ok, Map.filter(%{"default_flow" => default_flow}, fn {_, v} -> v != nil end)}
  end

  defp build_node_config(_node, type) when type in ["startEvent", "parallelGateway"] do
    {:ok, %{}}
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
