# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.Catalogue.AshActions do
  @moduledoc """
  Builds the designer's action catalogue straight out of the host's Ash resources.

  The designer's service-task panel wants a list of the actions a process may
  invoke — each with the arguments the host's action actually declares, so the
  panel can render one FEEL input row per argument instead of asking the
  modeller to guess names. This module walks a declarative allowlist of
  `{ref, resource, action}` triples and produces exactly those entries.

  It is a helper, not a seam: the catalogue options on
  `AshBpmn.Web.DesignerLive` take any function returning action entries, and
  this module is merely the shortest path from Ash to that shape. The
  allowlist is code, so an unknown action raises `ArgumentError` here, at
  boot of the host, rather than rendering a panel that lies.
  """

  @spec entries([{String.t(), module(), atom()}]) :: [map()]
  def entries(specs) when is_list(specs) do
    Enum.map(specs, &entry/1)
  end

  defp entry({ref, resource, action_name}) do
    case Ash.Resource.Info.action(resource, action_name) do
      nil ->
        raise ArgumentError,
              "ash_bpmn catalogue: #{inspect(resource)} does not declare an action named " <>
                "#{inspect(action_name)} (catalogue ref #{inspect(ref)})"

      action ->
        %{
          ref: to_string(ref),
          label: action.description || "#{inspect(resource)}.#{action_name}",
          description: action.description,
          args: Enum.map(action.arguments, &arg_entry/1)
        }
    end
  end

  defp arg_entry(argument) do
    %{
      name: to_string(argument.name),
      type: type_label(argument.type),
      allow_nil?: argument.allow_nil?,
      description: argument.description
    }
  end

  # A readable short type name for a properties panel: `{:array, :string}` is
  # "string[]", Ash's built-in types render in their conventional short form
  # (`Ash.Type.CiString` is "ci_string"), and any other module type keeps only
  # its last segment.
  defp type_label({:array, inner}), do: "#{type_label(inner)}[]"

  defp type_label(type) when is_atom(type) do
    case Module.split(type) do
      ["Ash", "Type", name] -> Macro.underscore(name)
      parts -> List.last(parts)
    end
  end

  defp type_label(type), do: to_string(type)
end
