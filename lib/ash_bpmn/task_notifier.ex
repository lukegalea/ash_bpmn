# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.TaskNotifier do
  @moduledoc """
  The host behaviour that tells people about a task's timers (DESIGN.md §11.7).

      # config/config.exs
      config :ash_bpmn, task_notifier: MyApp.Bpmn.Notices

      defmodule MyApp.Bpmn.Notices do
        @behaviour AshBpmn.TaskNotifier

        @impl true
        def deliver(%AshBpmn.Notice{} = notice, _ctx) do
          # Turn notice.recipients into people and addresses, in notice.tenant, and send
          # once per notice.key.
          :ok
        end
      end

  A `remind` timer delivers a `:remind` notice, an `escalate` timer that the resolver answers
  an `:escalated` one, and an `expire` timer an `:expired` one.

  ## What the engine guarantees

    * `deliver/2` is called after the timer's state changes have committed, so a failed
      delivery never undoes an escalation.
    * It is called at least once per fired timer, and again on every retry with the same
      `key`. Make delivery idempotent by that key.
    * Success writes a `:notice_delivered` process event. `{:error, reason}`, a raise or any
      other answer is retried by Oban; the final failure writes `:notice_failed`.
    * Nothing is delivered for a task that is completed or cancelled before its timer fires.
    * With no notifier configured, a remind or escalate timer on a definition published before
      the publish-time check (DESIGN.md §11.8) writes `:notice_undelivered` with reason
      `"no_notifier"` and emits `[:ash_bpmn, :notice, :undelivered]` telemetry. An expiry
      still expires: it routes the graph whether or not anyone is told.

  `ctx` carries `:tenant`, `:instance` (nil for a standalone approval), `:timer` (`kind`,
  `index`, `repetition`, `key`) and `:actor`.
  """

  @doc "Delivers one notice. Return `:ok` once it has been handed to the channel."
  @callback deliver(notice :: AshBpmn.Notice.t(), ctx :: map()) :: :ok | {:error, term()}
end
