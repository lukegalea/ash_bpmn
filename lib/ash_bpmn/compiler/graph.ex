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
        "joins" => joins
      }

      {:ok, graph}
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

  defp check_unsupported_process_children(process_xml, _supported_nodes, _flows_xml) do
    # Get all direct children of the process
    all_children = Xml.get_element_children(process_xml)

    supported_local_names =
      MapSet.new(Xml.supported_node_types() ++ ["sequenceFlow", "extensionElements"])

    Enum.flat_map(all_children, fn child ->
      type = Xml.local_name(child)
      normalized = Xml.normalize_name(type)
      id = Xml.element_attr(child, "id") || "unknown"

      cond do
        Xml.di_element?(normalized) ->
          []

        normalized in supported_local_names ->
          []

        String.starts_with?(type, "bpmn2:") ->
          if normalized in supported_local_names do
            []
          else
            [
              Errors.error(
                id,
                "Node '#{id}' of type '#{type}' is not supported; the executable subset is: #{Xml.supported_subset_message()}"
              )
            ]
          end

        true ->
          # Unknown extension - ignore silently (hosts may carry other extensions)
          []
      end
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

  defp build_node_config(node, "serviceTask") do
    ext = Xml.find_extension_elements(node)

    ash_task_configs = Xml.find_ash_elements(ext, "taskConfig")

    case ash_task_configs do
      [] ->
        {:error,
         Errors.error(
           Xml.element_attr(node, "id"),
           "serviceTask '#{Xml.element_attr(node, "id")}' must have an ash:taskConfig with a non-empty action attribute"
         )}

      [config | _] ->
        action = Xml.element_attr(config, "action")

        if action == nil or String.trim(action) == "" do
          {:error,
           Errors.error(
             Xml.element_attr(node, "id"),
             "serviceTask '#{Xml.element_attr(node, "id")}' ash:taskConfig must have a non-empty action attribute"
           )}
        else
          # Check for unknown ash attributes on taskConfig
          known_attrs = MapSet.new(["action"])

          unknown_ash =
            Enum.filter(Xml.find_ash_attributes(config), fn {k, _} -> k not in known_attrs end)

          if unknown_ash != [] do
            {k, _} = hd(unknown_ash)

            {:error,
             Errors.error(
               Xml.element_attr(node, "id"),
               "Unknown ash: attribute '#{k}' on ash:taskConfig for serviceTask '#{Xml.element_attr(node, "id")}'"
             )}
          else
            # Check for unknown ash child elements
            check_unknown_ash_children(
              config,
              node,
              ["candidates", "exclusions", "outcomes", "timers"],
              %{
                "action" => action
              }
            )
          end
        end
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


  defp build_business_rule_config(id, ext, decision) do
    ref = Xml.element_attr(decision, "ref")
    binding = Xml.element_attr(decision, "binding") || "latest"
    version = Xml.element_attr(decision, "version")

    cond do
      ref == nil or String.trim(ref) == "" ->
        {:error,
         Errors.error(id, "businessRuleTask '#{id}' ash:decision must have a non-empty ref attribute")}

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
         Errors.error(id, "businessRuleTask '#{id}' ash:decision binding=\"pinned\" requires a version")}

      true ->
        with {:ok, inputs} <- build_decision_inputs(id, ext),
             {:ok, promote} <- build_decision_promotions(id, ext) do
          {:ok,
           %{
             "decision" => %{"ref" => String.trim(ref), "binding" => binding, "version" => version},
             "inputs" => inputs,
             "promote" => promote
           }}
        end
    end
  end

  defp build_decision_inputs(node_id, ext) do
    ext
    |> Xml.find_ash_elements("inputs")
    |> Enum.flat_map(&Xml.find_ash_elements([&1], "input"))
    |> Enum.reduce_while({:ok, []}, fn input, {:ok, acc} ->
      name = Xml.element_attr(input, "name")
      from = Xml.element_attr(input, "from")

      cond do
        name == nil or String.trim(name) == "" ->
          {:halt,
           {:error, Errors.error(node_id, "businessRuleTask '#{node_id}' ash:input needs a name")}}

        from == nil or String.trim(from) == "" ->
          {:halt,
           {:error,
            Errors.error(node_id, "businessRuleTask '#{node_id}' ash:input '#{name}' needs a from expression")}}

        true ->
          # The `from` expression is validated here, at publish time, for the same reason a
          # gateway condition is: a decision node that cannot build its inputs should fail
          # when someone publishes it, not when an instance reaches it.
          case AshBpmn.Feel.compile(from) do
            {:ok, stored} ->
              {:cont, {:ok, [%{"name" => String.trim(name), "from" => stored} | acc]}}

            {:error, message} ->
              {:halt,
               {:error,
                Errors.error(
                  node_id,
                  "businessRuleTask '#{node_id}' ash:input '#{name}' from expression is not valid FEEL: #{message}"
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

  defp build_decision_promotions(node_id, ext) do
    signals =
      ext
      |> Xml.find_ash_elements("promote")
      |> Enum.flat_map(&Xml.find_ash_elements([&1], "signal"))

    names = Enum.map(signals, &(Xml.element_attr(&1, "name") || ""))

    cond do
      Enum.any?(names, &(String.trim(&1) == "")) ->
        {:error, Errors.error(node_id, "businessRuleTask '#{node_id}' ash:signal needs a name")}

      length(Enum.uniq(names)) != length(names) ->
        {:error,
         Errors.error(node_id, "businessRuleTask '#{node_id}' promotes the same signal name twice")}

      length(signals) > @max_promoted_signals ->
        {:error,
         Errors.error(
           node_id,
           "businessRuleTask '#{node_id}' promotes #{length(signals)} signals; at most " <>
             "#{@max_promoted_signals} are allowed -- a token carries routing, not business data"
         )}

      true ->
        {:ok,
         Enum.map(signals, fn signal ->
           %{
             "name" => signal |> Xml.element_attr("name") |> String.trim(),
             "required" => Xml.element_attr(signal, "required") in ["true", "1"]
           }
         end)}
    end
  end

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
