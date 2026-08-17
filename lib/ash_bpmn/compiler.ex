# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.Compiler do
  @moduledoc """
  BPMN XML compiler — parses BPMN 2.0 XML into a verified graph snapshot.

  ## Public API

    * `compile/1` — `compile(xml)` returns `{:ok, graph}` or `{:error, [%{path: _, message: _}]}`
    * `compile!/1` — raises with formatted error list on failure

  ## Graph shape

  The returned graph is a plain map with string keys:

      %{
        "process_id" => "...",
        "start" => "StartEvent_1",
        "nodes" => %{
          "id" => %{"type" => "startEvent" | "endEvent" | "userTask" | "serviceTask" | "exclusiveGateway" | "parallelGateway", "name" => "...", ...}
        },
        "flows" => %{
          "Flow_1" => %{"from" => "node_id", "to" => "node_id", "condition" => parsed_ast | nil}
        },
        "joins" => %{
          "Gateway_1" => %{"waits_for" => ["source_node_id", ...]}
        }
      }
  """

  alias AshBpmn.Compiler.{Errors, Graph, Verify, Xml}

  @doc """
  Compiles BPMN XML into a verified graph snapshot.

  Returns `{:ok, graph}` on success or `{:error, [%{path: _, message: _}]}` on failure.
  """
  @spec compile(String.t()) :: {:ok, map()} | {:error, [map()]}
  def compile(xml) when is_binary(xml) do
    with {:ok, doc} <- Xml.parse(xml),
         {:ok, process} <- Xml.extract_process(doc),
         {:ok, graph} <- Graph.build(process) do
      verify_errors = Verify.verify(graph)

      if verify_errors == [] do
        {:ok, graph}
      else
        {:error, verify_errors}
      end
    else
      {:error, msg} when is_binary(msg) ->
        {:error, [%{path: "xml", message: msg}]}

      {:error, errors} when is_list(errors) ->
        {:error, errors}
    end
  end

  @doc """
  Compiles BPMN XML, raising on failure with a formatted error message.
  """
  @spec compile!(String.t()) :: map()
  def compile!(xml) do
    case compile(xml) do
      {:ok, graph} ->
        graph

      {:error, errors} ->
        formatted = Errors.format_errors(errors)

        raise "BPMN compilation failed:\n#{formatted}"
    end
  end
end
