# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.Resources do
  @moduledoc """
  Resource macro registry and introspection helpers.

  Each `use AshBpmn.Resources.X` macro generates a function `ash_bpmn_kind/0` on
  the host module.  This module provides `kind/1` to sniff any loaded module and
  `for_domain/1` to locate the BPMN resources inside a domain.

  ## Core kinds and trigger kinds

  There are two sets. The **core six** (`:definition`, `:instance`, `:token`,
  `:human_task`, `:task_candidate`, `:process_event`) are what every process
  engine needs; `for_domain/1` demands all of them, which is what makes the
  domain fallback in `AshBpmn.Runtime.DomainResolver` safe. The **trigger
  kinds** (`:subscription`, `:cursor`, `:dispatch`) belong to the triggers
  extension (TRD §4.1–§4.3) and are **optional**: a domain that does not
  install them still resolves, with those keys `nil`. The mapping carries the
  trigger keys either way, so a caller — the sweep, mostly — can tell "not
  installed" from "forgotten to ask".
  """

  @core_kinds [:definition, :instance, :token, :human_task, :task_candidate, :process_event]
  @trigger_kinds [:subscription, :cursor, :dispatch]
  @kinds @core_kinds ++ @trigger_kinds

  @doc "The kinds every BPMN domain must register."
  @spec core_kinds() :: [atom()]
  def core_kinds, do: @core_kinds

  @doc "The triggers extension's kinds, which a domain may omit."
  @spec trigger_kinds() :: [atom()]
  def trigger_kinds, do: @trigger_kinds

  @doc "Returns the `@ash_bpmn_kind` atom for a loaded module, or `:not_bpmn`."
  @spec kind(module()) :: atom()
  def kind(module) do
    module.ash_bpmn_kind()
  rescue
    ArgumentError -> :not_bpmn
    UndefinedFunctionError -> :not_bpmn
  end

  @doc """
  Locates the BPMN resource modules registered in the given domain.

  Returns `{:ok, map}` where each key is a BPMN kind atom and each value is the
  resource module — `nil` for trigger kinds the domain does not install — or
  `{:error, :missing_resources, [kinds]}` if any of the core six are absent.
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
      @core_kinds
      |> Enum.reject(fn k -> mapping[k] end)

    case missing do
      [] -> {:ok, mapping}
      _ -> {:error, :missing_resources, missing}
    end
  end
end
