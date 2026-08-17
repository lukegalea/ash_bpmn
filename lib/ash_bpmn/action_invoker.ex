# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.ActionInvoker do
  @moduledoc """
  Behaviour for invoking service-task actions.

  The host application implements this to translate an opaque action string
  (from BPMN taskConfig or `RequireApproval` on_complete) into actual work.
  The engine passes a context map with `:subject`, `:actor`, `:instance`,
  `:task`, `:tenant`, and `:assigns`.

  ## Callback

    * `invoke/2` — invoke the named action with the given context.
  """

  @doc "Invokes a named action with the given context."
  @callback invoke(action :: String.t(), ctx :: map()) ::
              :ok | {:ok, map()} | {:error, term()}
end
