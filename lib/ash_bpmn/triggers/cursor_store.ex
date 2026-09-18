# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.Triggers.CursorStore do
  @moduledoc """
  Where the sweep's position in a tenant's event log is kept.

  A seam, introduced by ADR 0036 (converge process triggers onto projection checkpoints).
  The process domain and `ash_events_projections` grew the same machinery independently --
  per-tenant cursor tracking over a committed event stream -- and the decision is to stop
  owning it. This behaviour is what makes that swap a configuration rather than a rewrite,
  and what makes reversing it cheap: the ADR's own reversal clause asks for the legacy
  apparatus to stay behind a behaviour for a release, and this is that behaviour.

  ## Two things the projections engine does not do yet, which this seam exists to survive

  Read before assuming the swap is a drop-in, because neither is visible from the ADR:

  **`Checkpoint` is one row per projector, not per tenant.** Its primary key is
  `projection_name` and the process sweep's cursor is `identity :one_per_tenant`. Encoding
  the tenant into the name is the obvious workaround and it is a real cost, not a free one:
  the engine's lag, rebuild and verify tooling all assume a projector is one row, so a
  thousand tenants become a thousand projectors to that tooling.

  **`Checkpoint.last_seen_event_id` is the `ash_events` bigserial.** ADR 0036 says
  explicitly that checkpoints must key off the per-tenant advisory-lock hash chain rather
  than raw bigserial, because that chain is the stronger ordering primitive and converging
  must not downgrade it. Adopting the checkpoint as it stands *is* that downgrade. Closing
  it is upstream work in a package already running four projectors in production, which is
  why this ships as the dual-write half of the cutover the ADR describes and not as the
  switch.

  ## The contract

  `read/2` answers where the tenant's sweep has reached, creating the position at the log's
  high-water mark when there is none -- a fresh cursor must not replay a tenant's history.
  `advance/4` records a new position. Both take the resolved resources and the scope,
  because an implementation may need either and neither is reachable from a tenant alone.
  """

  @type tenant :: term()
  @type position :: integer() | nil

  @doc "Where this tenant's sweep has reached. Creates it at the high-water mark if absent."
  @callback read(tenant(), map()) :: {:ok, position()} | {:error, term()}

  @doc "Records that the sweep has reached `position` for this tenant."
  @callback advance(tenant(), position(), map()) :: :ok | {:error, term()}

  @doc """
  The configured store, defaulting to the legacy one.

  Defaulting rather than requiring is deliberate: ADR 0036 is a convergence, and a host that
  has not opted into it must keep working exactly as it did.
  """
  @spec impl() :: module()
  def impl do
    Application.get_env(:ash_bpmn, :cursor_store, AshBpmn.Triggers.CursorStore.Legacy)
  end
end

defmodule AshBpmn.Triggers.CursorStore.Legacy do
  @moduledoc """
  The cursor as the process domain has always kept it: one `AshBpmn.Resources.Cursor` row
  per tenant, holding the last dispatched sequence.

  Retained deliberately. ADR 0036's reversal clause asks for the old apparatus to stay
  behind a behaviour for one release, on the grounds that a lost cursor row is a stuck
  process instance -- so reversal must stay a configuration change rather than a restore.
  """

  @behaviour AshBpmn.Triggers.CursorStore

  require Ash.Query

  alias AshBpmn.Scope

  @impl true
  def read(tenant, ctx) do
    cursor =
      ctx.resources.cursor
      |> Ash.Query.for_read(:read)
      |> Ash.read_one!(Scope.engine(ctx.scope))

    case cursor do
      nil ->
        created =
          ctx.resources.cursor.create!(
            %{last_sequence: high_water(ctx.event_source, tenant)},
            Scope.engine(ctx.scope)
          )

        {:ok, created.last_sequence}

      cursor ->
        {:ok, cursor.last_sequence}
    end
  end

  @impl true
  def advance(_tenant, position, ctx) do
    ctx.resources.cursor
    |> Ash.Query.for_read(:read)
    |> Ash.read_one!(Scope.engine(ctx.scope))
    |> case do
      nil -> :ok
      cursor -> ctx.resources.cursor.advance!(cursor, position, Scope.engine(ctx.scope)) && :ok
    end
  end

  # A fresh cursor starts at the newest event rather than at zero: a subscription hears what
  # happens after it exists, and starting at zero would walk the tenant's whole history.
  #
  # The adapter's contract is forward-only -- `stream/3` reads *after* a sequence -- so the
  # high-water mark is found by paging to the end once, bounded by the batch size and paid
  # once per tenant before anything dispatches. Moved here verbatim from the sweep worker,
  # because it is the legacy cursor's own business rather than the sweep's.
  @batch 500

  defp high_water(event_source, tenant, after_sequence \\ 0, last \\ nil)

  defp high_water(event_source, tenant, after_sequence, last) do
    case event_source.stream(tenant, after_sequence, @batch) do
      {:ok, {[], _}} ->
        last || 0

      {:ok, {events, _}} ->
        last = event_source.sequence(List.last(events))
        high_water(event_source, tenant, last, last)
    end
  end
end
