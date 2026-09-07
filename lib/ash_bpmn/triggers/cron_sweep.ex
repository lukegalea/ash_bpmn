# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.Triggers.CronSweep do
  @moduledoc """
  Fans the trigger sweep out to one job per tenant, every minute.

  A separate worker from `AshBpmn.Triggers.SweepWorker` because the cron entry
  has to be a single job and the sweep has to be per tenant: the ordering
  guarantee the cursor relies on holds *within* a tenant and nowhere else, so a
  single job walking every tenant's events would be a global cursor, which the
  design refuses (TRD §5).

  ## Host wiring

  The cron is the driver — the nudge is only a nudge — so a host installing the
  triggers extension adds this to its Oban config:

      config :my_app, Oban,
        queues: [bpmn: 10],
        plugins: [
          {Oban.Plugins.Cron,
           crontab: [
             AshBpmn.Triggers.SweepWorker.cron_entry()
           ]}
        ]

  and tells the fan-out which tenants exist, as a list or an `{m, f, a}`
  (evaluated per call, the `ash_oban` `list_tenants` pattern):

      config :ash_bpmn,
        trigger_tenants: {MyApp.Organizations, :all_tenant_ids, []}

  An empty list fans out to nothing, which is the honest answer for a host that
  has not configured any tenants yet — though a host that leaves the cron
  unconfigured entirely should know the nudge alone is *not* a complete
  dispatch path (a lost nudge is survivable precisely because this sweep
  exists).
  """

  use Oban.Worker, max_attempts: 1

  alias AshBpmn.Triggers.SweepWorker

  @impl Oban.Worker
  def perform(_job), do: SweepWorker.enqueue_all()
end
