# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.Resources do
  @moduledoc """
  Resource macro registry and introspection helpers.

  Each `use AshBpmn.Resources.X` macro generates a function `ash_bpmn_kind/0` on
  the host module.  This module provides `kind/1` to sniff any loaded module and
  `for_domain/1` to locate all six BPMN resources inside a domain.
  """

  @kinds [:definition, :instance, :token, :human_task, :task_candidate, :process_event]

  @doc "Returns the `@ash_bpmn_kind` atom for a loaded module, or `:not_bpmn`."
  @spec kind(module()) :: atom()
  def kind(module) do
    module.ash_bpmn_kind()
  rescue
    ArgumentError -> :not_bpmn
    UndefinedFunctionError -> :not_bpmn
  end

  @doc """
  Locates all six BPMN resource modules registered in the given domain.

  Returns `{:ok, map}` where each key is a BPMN kind atom and each value is the
  resource module, or `{:error, :missing_resources, [kinds]}` if any are absent.
  """
  @spec for_domain(module()) :: {:ok, map()} | {:error, :missing_resources, [atom()]}
  def for_domain(domain) do
    resources = Ash.Domain.Info.resources(domain)

    mapping =
      for kind <- @kinds, into: %{} do
        mod = Enum.find(resources, fn r -> kind(r) == kind end)
        {kind, mod}
      end

    missing =
      @kinds
      |> Enum.reject(fn k -> mapping[k] end)

    case missing do
      [] -> {:ok, mapping}
      _ -> {:error, :missing_resources, missing}
    end
  end
end
