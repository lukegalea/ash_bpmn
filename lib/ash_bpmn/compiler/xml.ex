# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.Compiler.Xml do
  @moduledoc false

  # XML parsing helpers using :xmerl. Handles bpmn2: prefixed names pragmatically.
  # DI section (bpmndi:) is entirely ignored.

  # The ash: namespace URI is https://github.com/lukegalea/ash_bpmn/ns, but it
  # is never compared against: xmerl scans without :namespace_conform, so
  # extension attributes arrive as prefixed atoms and are matched by prefix.
  @supported_node_types ~w(startEvent endEvent userTask serviceTask businessRuleTask exclusiveGateway parallelGateway)
  @supported_node_types_with_prefix Enum.map(@supported_node_types, &"bpmn2:#{&1}")

  @spec parse(String.t()) :: {:ok, tuple()} | {:error, String.t()}
  def parse(xml) when is_binary(xml) do
    {doc, _} =
      :xmerl_scan.string(
        :unicode.characters_to_list(xml),
        [
          # NOTE: no :namespace_conform here. The default keeps prefixed
          # names ('bpmn2:process'), which is what the matchers expect;
          # the option also only accepts booleans and :strict crashes
          # initial_state/2.
          {:quiet, true}
        ]
      )

    {:ok, doc}
  rescue
    e ->
      {:error, "XML parse error: #{Exception.message(e)}"}
  catch
    # NOTE: bare `catch {:exit, r}` would match a *thrown* {:exit, r} tuple,
    # not a real exit — malformed XML (e.g. a bare `&`) exits here.
    :exit, reason ->
      {:error, "XML parse error: #{inspect(reason)}"}
  end

  @spec extract_process(tuple()) :: {:ok, map()} | {:error, String.t()}
  def extract_process(doc) do
    # Find the bpmn2:process element (or process without prefix)
    # Direct descendant search: a <process> cannot nest inside another, and
    # the root may be `definitions` or `bpmn2:definitions` (or absent in
    # hand-written XML), so anchoring on it buys nothing.
    processes =
      :xmerl_xpath.string(~c"//process", doc) ++
        :xmerl_xpath.string(~c"//bpmn2:process", doc)

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
  # NOTE: returns the RAW (possibly prefix-qualified) element name. Callers
  # that want the bare name compose with normalize_name/1 -- local_name must
  # not collapse that distinction or prefix-branching logic breaks.
  def local_name(element), do: element_name(element)

  # ── xmerl tuple accessors ────────────────────────────────────────────────
  #
  # Verified shapes (OTP 27 xmerl):
  #   element:  {:xmlElement, name_atom, prefixed, expanded, nsinfo, namespace,
  #              pos, attributes, content, parents, path, ...} (12-tuple)
  #              -> attrs at idx 7, content at idx 8, name at idx 1
  #   attr:     {:xmlAttribute, name_atom, prefix, expanded, parents, pos,
  #              order, normalized, value_charlist, ...} (10-tuple)
  #              -> name at idx 1, value at idx 8
  #   text:     {:xmlText, parents, pos, ?, value_charlist, type} (6-tuple)
  #              -> value at idx 4

  defguard is_element?(el)
           when is_tuple(el) and tuple_size(el) >= 9 and elem(el, 0) == :xmlElement

  defp raw_attributes(el) when is_element?(el), do: elem(el, 7) |> List.wrap()
  defp raw_attributes(_), do: []

  defp raw_content(el) when is_element?(el), do: elem(el, 8) |> List.wrap()
  defp raw_content(_), do: []

  @spec attr_value(tuple()) :: String.t() | nil
  defp attr_value(attr) when is_tuple(attr) and tuple_size(attr) == 10 do
    case elem(attr, 8) do
      value when is_list(value) -> List.to_string(value)
      value -> to_string(value)
    end
  end

  defp attr_value(_), do: nil

  defp xml_attr(element, name) do
    element
    |> raw_attributes()
    |> Enum.find(fn attr ->
      is_tuple(attr) and tuple_size(attr) >= 2 and elem(attr, 1) == String.to_atom(name)
    end)
    |> attr_value()
  end

  @spec find_children(tuple(), String.t()) :: [tuple()]
  def find_children(element, local_name) do
    element
    |> raw_content()
    |> Enum.filter(fn child ->
      is_element?(child) and child |> element_name() |> normalize_name() == local_name
    end)
  end

  @spec find_extension_elements(tuple()) :: [tuple()]
  def find_extension_elements(element) do
    find_children(element, "extensionElements")
  end

  @spec find_ash_elements([tuple()], String.t()) :: [tuple()]
  def find_ash_elements(ext_elements, local_name) do
    Enum.flat_map(ext_elements, fn ext ->
      Enum.filter(get_element_children(ext), fn child ->
        element_name(child) |> normalize_name() == local_name
      end)
    end)
  end

  @doc """
  Attributes in the `ash:` namespace, as `{\"local_name\", \"value\"}` pairs.

  With default (non namespace-conformant) xmerl scanning, `ash:action="x"`
  surfaces as the attribute atom `:\"ash:action\"` — there is no URI to
  compare against, so the namespace check is on the name prefix.
  """
  @spec find_ash_attributes(tuple()) :: [{String.t(), String.t()}]
  def find_ash_attributes(element) do
    element
    |> raw_attributes()
    |> Enum.filter(fn attr ->
      is_tuple(attr) and tuple_size(attr) >= 2 and
        attr |> elem(1) |> Atom.to_string() |> String.starts_with?("ash:")
    end)
    |> Enum.map(fn attr ->
      {attr |> elem(1) |> Atom.to_string() |> String.trim_leading("ash:"), attr_value(attr)}
    end)
  end

  @spec get_element_children(tuple()) :: [tuple()]
  def get_element_children(element) do
    element
    |> raw_content()
    |> Enum.filter(&is_element?/1)
  end

  @spec element_attrs(tuple()) :: [{String.t(), String.t()}]
  def element_attrs(element) do
    element
    |> raw_attributes()
    |> Enum.filter(fn attr -> is_tuple(attr) and tuple_size(attr) == 10 end)
    |> Enum.map(fn attr -> {attr |> elem(1) |> Atom.to_string(), attr_value(attr)} end)
    |> Enum.reject(fn {k, _v} -> String.starts_with?(k, "xmlns") end)
  end

  @spec element_attr(tuple(), String.t()) :: String.t() | nil
  def element_attr(element, name) do
    xml_attr(element, name)
  end

  @spec element_text(tuple()) :: String.t() | nil
  def element_text(element) do
    element
    |> raw_content()
    |> Enum.filter(fn child -> is_tuple(child) and elem(child, 0) == :xmlText end)
    |> Enum.map_join("", fn text ->
      value = elem(text, 4)
      if is_list(value), do: List.to_string(value), else: to_string(value)
    end)
    |> String.trim()
    |> case do
      "" -> nil
      text -> text
    end
  end

  @spec element_name(tuple()) :: String.t()
  def element_name(el) when is_element?(el) do
    el |> elem(1) |> Atom.to_string()
  end

  def element_name(_), do: ""

  @spec collect_all_nodes(tuple()) :: [tuple()]
  def collect_all_nodes(process) do
    xpath_base = ~c"//"

    Enum.flat_map(@supported_node_types ++ @supported_node_types_with_prefix, fn type ->
      xpath = xpath_base ++ String.to_charlist(type)
      :xmerl_xpath.string(xpath, process)
    end)
  end

  @spec collect_all_flows(tuple()) :: [tuple()]
  def collect_all_flows(process) do
    :xmerl_xpath.string(~c"//sequenceFlow", process) ++
      :xmerl_xpath.string(~c"//bpmn2:sequenceFlow", process)
  end

  @spec collect_all_gateways(tuple()) :: [tuple()]
  def collect_all_gateways(process) do
    :xmerl_xpath.string(~c"//exclusiveGateway", process) ++
      :xmerl_xpath.string(~c"//bpmn2:exclusiveGateway", process) ++
      :xmerl_xpath.string(~c"//parallelGateway", process) ++
      :xmerl_xpath.string(~c"//bpmn2:parallelGateway", process)
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
  def normalize_name("bpmn:" <> local), do: local
  def normalize_name("ash:" <> local), do: local
  def normalize_name(name), do: name

  @spec supported_node_type?(String.t()) :: boolean()
  def supported_node_type?(type), do: type in @supported_node_types

  @doc """
  The executable subset, as node type names.

  Exposed because the same list was previously written out by hand in four places -- two
  membership checks and two error messages -- and adding a node type meant finding all four.
  """
  @spec supported_node_types() :: [String.t()]
  def supported_node_types, do: @supported_node_types

  @doc "The subset, phrased for an error message a modeller will read."
  @spec supported_subset_message() :: String.t()
  def supported_subset_message,
    do: Enum.join(@supported_node_types ++ ["sequenceFlow"], ", ")

  @spec flow_type?(String.t()) :: boolean()
  def flow_type?("sequenceFlow"), do: true
  def flow_type?(_), do: false

  @spec di_element?(String.t()) :: boolean()
  def di_element?("BPMNDiagram"), do: true
  def di_element?("BPMNPlane"), do: true
  def di_element?("BPMNShape"), do: true
  def di_element?("BPMNEdge"), do: true
  def di_element?("bpmndi:BPMNDiagram"), do: true
  def di_element?("bpmndi:BPMNPlane"), do: true
  def di_element?("bpmndi:BPMNShape"), do: true
  def di_element?("bpmndi:BPMNEdge"), do: true
  def di_element?("dc:Bounds"), do: true
  def di_element?("di:waypoint"), do: true
  def di_element?(_), do: false
end
