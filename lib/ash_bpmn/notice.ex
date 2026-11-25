# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.Notice do
  @moduledoc """
  What a fired task timer asks a host to tell people (DESIGN.md §11.7).

  Handed to `c:AshBpmn.TaskNotifier.deliver/2`. The engine decides *who* (`recipients`); the
  host decides how they are reached and in what words.

    * `key` — the timer's key, `"<task id>/<node id>/<timer index>/<repetition>"`. The same on
      every retry of one firing and different for every repetition: deduplicate on it.
    * `kind` — `:remind`, `:escalated` or `:expired`.
    * `task` — the task, as it was when the timer fired.
    * `recipients` — the principals to tell: the assignee when the task is claimed, otherwise
      its candidates, plus on `:escalated` the principals just added, always minus the task's
      exclusions. `%{type: :user | :team, id: id}`; a team is the host's to expand.
    * `added` — on `:escalated`, the principals the escalation added. `[]` otherwise.
    * `due_at` — the task's due date, or nil.
    * `late` — true when the timer fired after its moment had passed.
    * `repetition` — 1 for the first firing of a timer.
    * `tenant` — the task's tenant, or nil.
    * `holder` — who holds the task when it is claimed (`%{type:, id:}`), or nil when it is
      open. Escalation only adds people (DESIGN.md §11.6): on a claimed task the principals in
      `added` become candidates, but only the holder can act on it until the holder delegates
      it to one of them. A host's words must say so, not that the task was passed to them.
  """

  @enforce_keys [:key, :kind, :task, :recipients]
  defstruct [
    :key,
    :kind,
    :task,
    :due_at,
    :tenant,
    :holder,
    recipients: [],
    added: [],
    late: false,
    repetition: 1
  ]

  @type kind :: :remind | :escalated | :expired

  @type t :: %__MODULE__{
          key: String.t(),
          kind: kind(),
          task: map(),
          recipients: [AshBpmn.AssignmentResolver.principal()],
          added: [AshBpmn.AssignmentResolver.principal()],
          due_at: DateTime.t() | nil,
          late: boolean(),
          repetition: pos_integer(),
          tenant: term(),
          holder: AshBpmn.AssignmentResolver.principal() | nil
        }
end
