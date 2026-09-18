# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.Triggers.CursorStore.Dual do
  @moduledoc """
  Reads the legacy cursor, writes both it and the converged one, and reports where they
  disagree.

  This is the cutover ADR 0036 asks for, in the shape it asks for it: *"the cutover runs
  dual-read until checkpoints are proven lag-zero"*. The legacy cursor stays authoritative
  throughout, because the failure it guards against is not one a retry fixes -- a lost cursor
  row is a stuck process instance, and a stuck instance is silent.

  ## What proves the switch is safe

  Divergence, observed rather than asserted. Every read compares the two, and a mismatch is
  emitted as telemetry rather than raised: the legacy value is authoritative and the sweep
  must not stop to argue about bookkeeping.

  So lag-zero becomes evidence — run this, watch `[:ash_bpmn, :cursor_store, :divergence]`
  stay silent across a real workload, and the switch is a configuration change with something
  behind it. Switching without that is what the ADR's migration note exists to prevent.

      config :ash_bpmn,
        cursor_store: AshBpmn.Triggers.CursorStore.Dual,
        converged_cursor_store: MyApp.Bpmn.CheckpointCursorStore
  """

  @behaviour AshBpmn.Triggers.CursorStore

  alias AshBpmn.Triggers.CursorStore

  @impl true
  def read(tenant, ctx) do
    legacy = CursorStore.Legacy.read(tenant, ctx)

    # The converged store is read and not trusted, and a failure to read it is not a failure
    # of the sweep. That asymmetry is the whole point of a dual phase.
    store = converged()

    case {legacy, safely(fn -> store.read(tenant, ctx) end)} do
      {{:ok, position}, {:ok, {:ok, other}}} when other != position ->
        divergence(tenant, :read, position, other)
        legacy

      _ ->
        legacy
    end
  end

  @impl true
  def advance(tenant, position, ctx) do
    store = converged()
    result = CursorStore.Legacy.advance(tenant, position, ctx)
    _ = safely(fn -> store.advance(tenant, position, ctx) end)
    result
  end

  defp converged do
    Application.get_env(:ash_bpmn, :converged_cursor_store) ||
      raise """
      AshBpmn.Triggers.CursorStore.Dual is configured with no :converged_cursor_store.

      The dual store exists to compare the legacy cursor against the converged one. With
      nothing to compare against it is the legacy store with extra steps, which is more
      likely a mistake than an intention.
      """
  end

  # A converged store that raises must not take the sweep down with it: it is the half being
  # evaluated, and the evaluation is the point.
  #
  # `converged/0` is resolved *outside* this, deliberately. A missing configuration is not a
  # misbehaving store, and swallowing it would leave the dual phase silently running as the
  # legacy store while appearing to prove something about a converged one that was never
  # consulted -- which is precisely the evidence the cutover is supposed to produce.
  defp safely(fun) do
    {:ok, fun.()}
  rescue
    error -> {:error, error}
  end

  defp divergence(tenant, phase, authoritative, converged) do
    :telemetry.execute(
      [:ash_bpmn, :cursor_store, :divergence],
      %{authoritative: authoritative || 0, converged: converged || 0},
      %{tenant: tenant, phase: phase}
    )
  end
end
