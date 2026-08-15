# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.Compiler.Xml do
  @moduledoc false

  # XML parsing helpers using :xmerl. Handles bpmn2: prefixed names pragmatically.
  # DI section (bpmndi:) is entirely ignored.

  @ash_ns "https://github.com/lukegalea/ash_bpmn/ns"
  @supported_node_types ~w(startEvent endEvent userTask serviceTask exclusiveGateway parallelGateway)
  @supported_node_types_with_prefix Enum.map(@supported_node_types, &"bpmn2:#{&1}")

  @spec parse(String.t()) :: {:ok, tuple()} | {:error, String.t()}
  def parse(xml) do
    try do
      {doc, _} =
        :xmerl_scan.string(
          xml,
          [
            {:namespace_conform, :strict},
            {:quiet, true}
          ]
        )

      {:ok, doc}
    rescue
      e in [MatchError] ->
        {:error, "XML parse error: #{Exception.message(e)}"}

      e ->
        {:error, "XML parse error: #{Exception.message(e)}"}
    end
  catch
    {:exit, {:fatal, {:xmerl_scan, reason, _}}} ->
      {:error, "XML parse error: #{inspect(reason)}"}

    {:exit, reason} ->
      {:error, "XML parse error: #{inspect(reason)}"}
  end

  @spec extract_process(tuple()) :: {:ok, map()} | {:error, String.t()}
  def extract_process(doc) do
    # Find the bpmn2:process element (or process without prefix)
    processes = :xmerl_xpath.string('/definitions/process', doc) ++
                  :xmerl_xpath.string('/definitions/bpmn2:process', doc)

    case processes do
      [process] ->
        {:ok, process_to_map(process)}

      [] ->
        {:error, "No <process> element found in BPMN XML"}

      _multiple ->
        {:error, "Multiple <process> elements found; only one is supported"}
    end
  end

  @spec process_to_map(tuple()) :: map()
  def process_to_map(process) do
    %{
      id: xml_attr(process, "id"),
      name: xml_attr(process, "name"),
      is_executable: xml_attr(process, "isExecutable"),
      xml: process
    }
  end

  @spec local_name(tuple()) :: String.t()
  def local_name(element) do
    case element do
      {:xmlElement, name, _, _, _, _, _, _, _, _, _, _} ->
        atom_to_string(name)

      _ ->
        ""
    end
  end

  defp atom_to_string(atom) when is_atom(atom), do: Atom.to_string(atom)

  defp xml_attr(element, name) do
    attrs =
      case element do
        {:xmlElement, _, _, _, attrs, _, _, _, _, _, _} -> attrs
        _ -> []
      end

    case List.keyfind(attrs, name, 1) do
      {:xmlAttribute, _, _, _, _, _, _, _, _, value, _} -> to_string(value)
      nil -> nil
    end
  end

  @spec find_children(tuple(), String.t()) :: [tuple()]
  def find_children(element, local_name) do
    case element do
      {:xmlElement, _, _, _, _, _, _, children, _, _, _} ->
        Enum.filter(children, fn
          {:xmlElement, name, _, _, _, _, _, _, _, _, _} ->
            normalize_name(name) == local_name

          _ ->
            false
        end)

      _ ->
        []
    end
  end

  @spec find_extension_elements(tuple()) :: [tuple()]
  def find_extension_elements(element) do
    find_children(element, "extensionElements")
  end

  @spec find_ash_elements([tuple()], String.t()) :: [tuple()]
  def find_ash_elements(ext_elements, local_name) do
    Enum.flat_map(ext_elements, fn ext ->
      Enum.filter(get_element_children(ext), fn
        {:xmlElement, name, _, _, _, _, _, _, _, _, _} ->
          normalize_name(name) == local_name

        _ ->
          false
      end)
    end)
  end

  @spec find_ash_attributes(tuple()) :: [{String.t(), String.t()}]
  def find_ash_attributes(element) do
    case element do
      {:xmlElement, _, _, _, attrs, _, _, _, _, _, _} ->
        attrs
        |> Enum.filter(fn
          {:xmlAttribute, ns, _, _, _, _, _, _, _, _, _} ->
            ns == @ash_ns

          _ ->
            false
        end)
        |> Enum.map(fn {:xmlAttribute, _, _, _, _, name, _, _, _, value, _} ->
          {Atom.to_string(name), to_string(value)}
        end)

      _ ->
        []
    end
  end

  @spec get_element_children(tuple()) :: [tuple()]
  def get_element_children(element) do
    case element do
      {:xmlElement, _, _, _, _, _, _, children, _, _, _} ->
        Enum.filter(children, fn
          {:xmlElement, _, _, _, _, _, _, _, _, _, _} -> true
          _ -> false
        end)

      _ ->
        []
    end
  end

  @spec element_attrs(tuple()) :: [{String.t(), String.t()}]
  def element_attrs(element) do
    case element do
      {:xmlElement, _, _, _, attrs, _, _, _, _, _, _} ->
        attrs
        |> Enum.map(fn {:xmlAttribute, _, _, _, _, name, _, _, _, value, _} ->
          {Atom.to_string(name), to_string(value)}
        end)
        |> Enum.reject(fn {k, _v} ->
          # Filter out namespace declarations
          String.starts_with?(k, "xmlns")
        end)

      _ ->
        []
    end
  end

  @spec element_attr(tuple(), String.t()) :: String.t() | nil
  def element_attr(element, name) do
    case element do
      {:xmlElement, _, _, _, attrs, _, _, _, _, _, _} ->
        case List.keyfind(attrs, name, 1) do
          {:xmlAttribute, _, _, _, _, _, _, _, _, value, _} -> to_string(value)
          nil -> nil
        end

      _ ->
        nil
    end
  end

  @spec element_text(tuple()) :: String.t() | nil
  def element_text(element) do
    case element do
      {:xmlElement, _, _, _, _, _, _, children, _, _, _} ->
        children
        |> Enum.filter(fn
          {:xmlText, _, _, _, _, _, _, _} -> true
          _ -> false
        end)
        |> Enum.map(fn {:xmlText, _, _, _, value, _, _, _} -> to_string(value) end)
        |> Enum.join()
        |> String.trim()
        |> case do
          "" -> nil
          text -> text
        end

      _ ->
        nil
    end
  end

  @spec collect_all_nodes(tuple()) :: [tuple()]
  def collect_all_nodes(process) do
    direct_types = @supported_node_types ++ @supported_node_types_with_prefix

    Enum.flat_map(direct_types, fn type ->
      xpath = "/process/#{type}"
      :xmerl_xpath.string(xpath, process)
    end) ++
      Enum.flat_map(direct_types, fn type ->
        xpath = "/process/bpmn2:#{type}"
        :xmerl_xpath.string(xpath, process)
      end)
  end

  @spec collect_all_flows(tuple()) :: [tuple()]
  def collect_all_flows(process) do
    :xmerl_xpath.string('/process/sequenceFlow', process) ++
      :xmerl_xpath.string('/process/bpmn2:sequenceFlow', process)
  end

  @spec collect_all_gateways(tuple()) :: [tuple()]
  def collect_all_gateways(process) do
    :xmerl_xpath.string('/process/exclusiveGateway', process) ++
      :xmerl_xpath.string('/process/bpmn2:exclusiveGateway', process) ++
      :xmerl_xpath.string('/process/parallelGateway', process) ++
      :xmerl_xpath.string('/process/bpmn2:parallelGateway', process)
  end

  @spec incoming_ids(tuple()) :: [String.t()]
  def incoming_ids(node) do
    node
    |> find_children("incoming")
    |> Enum.map(&element_text/1)
    |> Enum.filter(&(&1 != nil))
  end

  @spec outgoing_ids(tuple()) :: [String.t()]
  def outgoing_ids(node) do
    node
    |> find_children("outgoing")
    |> Enum.map(&element_text/1)
    |> Enum.filter(&(&1 != nil))
  end

  @spec node_type(tuple()) :: String.t() | nil
  def node_type(element) do
    name = local_name(element)
    normalize_name(name)
  end

  @spec normalize_name(String.t()) :: String.t()
  def normalize_name("bpmn2:" <> local), do: local
  def normalize_name(name), do: name

  @spec is_supported_node_type?(String.t()) :: boolean()
  def is_supported_node_type?(type), do: type in @supported_node_types

  @spec is_flow_type?(String.t()) :: boolean()
  def is_flow_type?("sequenceFlow"), do: true
  def is_flow_type?(_), do: false

  @spec is_di_element?(String.t()) :: boolean()
  def is_di_element?("BPMNDiagram"), do: true
  def is_di_element?("BPMNPlane"), do: true
  def is_di_element?("BPMNShape"), do: true
  def is_di_element?("BPMNEdge"), do: true
  def is_di_element?("bpmndi:BPMNDiagram"), do: true
  def is_di_element?("bpmndi:BPMNPlane"), do: true
  def is_di_element?("bpmndi:BPMNShape"), do: true
  def is_di_element?("bpmndi:BPMNEdge"), do: true
  def is_di_element?("dc:Bounds"), do: true
  def is_di_element?("di:waypoint"), do: true
  def is_di_element?(_), do: false
end
