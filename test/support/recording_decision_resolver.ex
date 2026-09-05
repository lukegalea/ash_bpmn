# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.Test.RecordingDecisionResolver do
  @moduledoc """
  A decision resolver double that sends the context it was called with back to
  the calling test process, so tests can assert exactly what the engine handed
  the seam.

  Safe because engine tests run with `oban_testing: :inline`: the interpreter
  calls this in the test process itself, so `self()` *is* the test and the
  test can `assert_received`.
  """

  @behaviour AshBpmn.DecisionResolver

  @impl true
  def decide(_ref, _inputs, context) do
    send(self(), {:decision_context, context})
    {:ok, %{outputs: %{"tier" => "low"}}}
  end

  @impl true
  def exists?(_ref), do: true
end
