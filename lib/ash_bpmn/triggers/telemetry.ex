# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.Triggers.Telemetry do
  @moduledoc """
  The `:telemetry` events the trigger sweep emits: how far behind each tenant's log it is,
  and how long an event waits before the process it starts exists.

  | Event | Measurements | Metadata |
  |---|---|---|
  | `[:ash_bpmn, :triggers, :sweep]` | `duration_ms`, `events`, and `lag` when the adapter implements `c:AshBpmn.EventSource.latest_sequence/1` | `tenant`, `last_sequence` |
  | `[:ash_bpmn, :triggers, :dispatch, :start]` | `latency`, in native time units | `tenant`, `kind`, `subscription_id` |

  A host declares its metrics over these names, for example with `Telemetry.Metrics`:

      last_value("ash_bpmn.triggers.sweep.lag", tags: [:tenant])
      distribution("ash_bpmn.triggers.dispatch.start.latency",
        unit: {:native, :millisecond},
        tags: [:kind]
      )

  ## Sweep lag

  Each sweep batch reports how many events of the tenant's log lie beyond the position its
  cursor reached: the adapter's newest sequence minus `last_sequence`, never below zero.
  Zero means the sweep is caught up. A lag that keeps growing means the tenant writes faster
  than its one sweeper reads.

  `lag` is present only when the adapter implements the optional
  `c:AshBpmn.EventSource.latest_sequence/1`. Without it the newest sequence is found by
  paging the whole log, which is too costly to do after every batch, so the measurement is
  left out. The newest sequence is read after the batch has committed. A read that raises is
  logged and leaves `lag` out of that batch's event; it never fails the sweep.

  ## Dispatch latency

  A dispatch that starts a process (`status: :started`) reports the time from its event's
  `occurred_at` to the moment the row is written. That covers the cron interval, the
  sweep's lag and the funnel. A re-driven failure that starts a process reports it too, so
  the hours it waited show. Dispatches that start nothing report nothing.

  The event is emitted as the row is written, inside the event's transaction. A transaction
  that rolls back after the row was written has still reported its start.
  """

  require Logger

  @sweep [:ash_bpmn, :triggers, :sweep]
  @dispatch_start [:ash_bpmn, :triggers, :dispatch, :start]

  @doc "The sweep batch event's name."
  @spec sweep_event() :: [atom()]
  def sweep_event, do: @sweep

  @doc "The started-dispatch event's name."
  @spec dispatch_start_event() :: [atom()]
  def dispatch_start_event, do: @dispatch_start

  @doc """
  Reports one sweep batch for `tenant`: how long it took, how many events it walked, the
  position the cursor reached and, when `event_source` can say, the lag behind the log.
  """
  @spec sweep(term(), integer(), non_neg_integer(), non_neg_integer(), module()) :: :ok
  def sweep(tenant, last_sequence, events, duration_ms, event_source) do
    measurements =
      put_lag(%{duration_ms: duration_ms, events: events}, event_source, tenant, last_sequence)

    :telemetry.execute(@sweep, measurements, %{tenant: tenant, last_sequence: last_sequence})
  end

  @doc """
  Reports how long the event behind `dispatch` waited for the process it started. Reports
  nothing for a dispatch that started nothing.
  """
  @spec dispatch_started(term(), struct()) :: :ok
  def dispatch_started(tenant, %{status: :started, event_occurred_at: %DateTime{} = at} = row) do
    micros = max(DateTime.diff(DateTime.utc_now(), at, :microsecond), 0)

    :telemetry.execute(
      @dispatch_start,
      %{latency: System.convert_time_unit(micros, :microsecond, :native)},
      %{tenant: tenant, kind: row.kind, subscription_id: row.subscription_id}
    )
  end

  def dispatch_started(_tenant, _dispatch), do: :ok

  defp put_lag(measurements, event_source, tenant, position) when is_integer(position) do
    if latest_sequence?(event_source) do
      newest = event_source.latest_sequence(tenant) || 0
      Map.put(measurements, :lag, max(newest - position, 0))
    else
      measurements
    end
  rescue
    e ->
      Logger.warning(
        "ash_bpmn sweep lag not reported for #{inspect(tenant)}: #{Exception.message(e)}"
      )

      measurements
  end

  defp put_lag(measurements, _event_source, _tenant, _position), do: measurements

  defp latest_sequence?(event_source) do
    Code.ensure_loaded?(event_source) and function_exported?(event_source, :latest_sequence, 1)
  end
end
