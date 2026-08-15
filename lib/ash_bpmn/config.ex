# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.Config do
  @moduledoc """
  Runtime configuration for the ash_bpmn library.

  Reads from `Application.get_env(:ash_bpmn, ...)`.  Required settings raise
  an instructive error when accessed but unset; optional settings return
  documented defaults.
  """

  @doc "Returns the configured `AshBpmn.AssignmentResolver` module.  Raises if unset."
  @spec assignment_resolver!() :: module()
  def assignment_resolver! do
    case Application.get_env(:ash_bpmn, :assignment_resolver) do
      nil ->
        raise """
        ash_bpmn: :assignment_resolver is not configured.

        Add to your config:

            config :ash_bpmn,
              assignment_resolver: MyApp.Bpmn.Resolver

        The module must implement the `AshBpmn.AssignmentResolver` behaviour.
        """

      mod when is_atom(mod) ->
        mod
    end
  end

  @doc "Returns the configured `AshBpmn.ActionInvoker` module.  Raises if unset."
  @spec action_invoker!() :: module()
  def action_invoker! do
    case Application.get_env(:ash_bpmn, :action_invoker) do
      nil ->
        raise """
        ash_bpmn: :action_invoker is not configured.

        Add to your config:

            config :ash_bpmn,
              action_invoker: MyApp.Bpmn.Invoker

        The module must implement the `AshBpmn.ActionInvoker` behaviour.
        """

      mod when is_atom(mod) ->
        mod
    end
  end

  @doc "Returns the Oban queue name for BPMN jobs (default `:bpmn`)."
  @spec queue() :: atom()
  def queue do
    Application.get_env(:ash_bpmn, :queue, :bpmn)
  end

  @doc "Returns the max retry attempts for advance jobs (default `5`)."
  @spec max_attempts() :: pos_integer()
  def max_attempts do
    Application.get_env(:ash_bpmn, :max_attempts, 5)
  end

  @doc """
  Returns the Oban testing mode: `nil` (production) or `:inline`.

  When `:inline`, the runtime's Oban shim executes workers synchronously
  instead of enqueueing.
  """
  @spec oban_testing() :: nil | :inline
  def oban_testing do
    Application.get_env(:ash_bpmn, :oban_testing)
  end
end
