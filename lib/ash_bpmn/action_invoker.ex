# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.ActionInvoker do
  @moduledoc """
  Behaviour for invoking service-task and send-task actions.

  The host application implements this to translate an opaque action string
  (from BPMN taskConfig or `RequireApproval` on_complete) into actual work.

  ## Callback

    * `invoke/2` — invoke the named action with the given context.

  ## The context

  The context is a map whose keys depend on the path that calls it — read it
  with `ctx[:key]`, never by pattern-matching a fixed shape:

    * from the interpreter (a `serviceTask` or `sendTask` node): `:instance`,
      `:token`, `:subject`, `:assigns`, `:scope`, `:actor`, `:tenant`, and
      `:inputs`. `:inputs` holds the node's declared `ash:inputs` already
      evaluated through FEEL — a map of input name to value, empty when the
      node declares none.
    * from the standalone approval path (`AshBpmn.decide/2`): `:subject`,
      `:actor`, `:instance`, `:task`, and `:assigns`.

  Keys a caller did not supply are absent rather than nil, so `ctx[:key]`
  returns nil for each of them.

  Optionally, the module may also export `exists?(action :: String.t()) ::
  boolean`. When it does, the compiler asks it at publish time whether every
  service/send task's action actually exists — the same publish-time promise
  the decision resolver's `exists?/1` makes. The export is voluntary: without
  it, invoking remains the only contract.
  """

  @doc "Invokes a named action with the given context."
  @callback invoke(action :: String.t(), ctx :: map()) ::
              :ok | {:ok, map()} | {:error, term()}
end
