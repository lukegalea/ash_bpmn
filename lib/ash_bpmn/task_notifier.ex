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
    * `{:error, {:final, reason}}` says the host will not try again (a suppressed address, a
      rejection, a send whose outcome it cannot know): `:notice_failed` with
      `"final" => true` is written at once and nothing is retried.
    * `{:ok, %{not_reached: [{principal, reason}]}}` says some recipients were reached and
      these were not, and the host will not try them again. `:notice_delivered` names only
      the recipients reached and lists the others under `"not_reached"`; when that leaves
      nobody, it is `:notice_failed` with `"final" => true`. A principal that is not one of
      `notice.recipients` makes the answer an error, retried.
    * A notice nobody received is never recorded as `:notice_delivered`.
    * On a claimed task `notice.holder` names who holds it. The people an escalation adds
      can act on it only if the holder delegates it to one of them: say that, not that the
      task was passed to them.
    * Nothing is delivered for a task that is completed or cancelled before its timer fires.
    * With no notifier configured, a remind or escalate timer on a definition published before
      the publish-time check (DESIGN.md §11.8) writes `:notice_undelivered` with reason
      `"no_notifier"` and emits `[:ash_bpmn, :notice, :undelivered]` telemetry. An expiry
      still expires: it routes the graph whether or not anyone is told.

  `ctx` carries `:tenant`, `:instance` (nil for a standalone approval), `:timer` (`kind`,
  `index`, `repetition`, `key`), `:actor` and `:final_attempt?`, true on the last attempt Oban
  will make. A host that answers `{:error, reason}` to have a missed recipient retried answers
  `{:ok, %{not_reached: ...}}` on the final attempt instead, so the record names who was told.
  """

  @doc "Delivers one notice. Return `:ok` once it has been handed to the channel."
  @callback deliver(notice :: AshBpmn.Notice.t(), ctx :: map()) ::
              :ok
              | {:ok, %{not_reached: [{AshBpmn.AssignmentResolver.principal(), term()}]}}
              | {:error, {:final, term()}}
              | {:error, term()}
end
