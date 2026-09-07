# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.Triggers.Nudge do
  @moduledoc """
  Nudges the trigger sweep when an audited write lands on a resource some
  subscription cares about (TRD §5.1).

  ## The host attaches it, by config

  The library never touches a host resource, so the host attaches this notifier
  to **its own event-log resource** — the resource the configured
  `AshBpmn.EventSource` reads — the same way it attaches any notifier:

      use Ash.Resource,
        notifiers: [AshBpmn.Triggers.Nudge]

  Two fields are read off the created event row, with defaults matching the
  reference application's log (`:resource` — the module atom or short string —
  and `:organization_id`). A host whose log spells them differently overrides
  without wrapping:

      config :ash_bpmn,
        nudge_resource_field: :resource,
        nudge_tenant_field: :tenant

  ## It is a nudge, and it must never be more than that

  Ash defers notifications until the transaction is over, so this runs **after**
  the write has committed. That is good — it means the notifier cannot extend
  the per-tenant advisory lock the log's writer holds, and cannot make other
  audited writes queue behind it.

  It also means **enqueuing here is not transactional with the write**. A crash
  between `COMMIT` and the Oban insert loses the nudge, silently and
  undetectably.

  That is survivable only because the nudge is not how dispatch completes: the
  cron-driven sweep walks the cursor and reaches the same events regardless
  (`AshBpmn.Triggers.CronSweep`). Losing a nudge costs latency; it cannot cost a
  process. If anyone ever removes the cron sweep and relies on this, the system
  acquires a silent failure mode — which is why it is stated here and not only
  in the TRD.

  ## Debounced

  The insert is `unique` over a five-second window per tenant, so a burst of
  writes produces one sweep rather than one job each.
  """

  use Ash.Notifier

  require Logger

  alias AshBpmn.Config
  alias AshBpmn.Resources.Subscription.ResourceName
  alias AshBpmn.Runtime.Oban, as: BpmnOban
  alias AshBpmn.Triggers.{Index, SweepWorker}

  @impl true
  def notify(%Ash.Notifier.Notification{data: event}) do
    resource = short_name(Map.get(event, Config.nudge_resource_field()))
    tenant = Map.get(event, Config.nudge_tenant_field())

    if is_binary(resource) and Index.interested?(resource) do
      enqueue(tenant)
    end

    :ok
  rescue
    e ->
      # A notifier that raises must not fail the write it is notifying about.
      # The write has already committed; the worst case here is a missed nudge,
      # which the sweep covers.
      Logger.warning("ash_bpmn trigger notifier failed: #{Exception.message(e)}")
      :ok
  end

  def notify(_other), do: :ok

  # The index is keyed on the short name a person types. A log row's resource
  # may arrive as the module atom (Ash casts the column back) or as either
  # string spelling, so all three normalize through `ResourceName`.
  defp short_name(nil), do: nil
  defp short_name(resource) when is_atom(resource), do: ResourceName.canonical(resource)
  defp short_name(resource) when is_binary(resource), do: ResourceName.short(resource)

  defp enqueue(tenant) do
    BpmnOban.insert(
      SweepWorker,
      %{"tenant" => tenant},
      unique: [period: 5, keys: [:tenant], states: [:available, :scheduled]]
    )
  end
end
