# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmnDev.Notices do
  @moduledoc """
  The demo's `AshBpmn.TaskNotifier`. It sends nothing: it logs each notice, so the
  demo shows who would have been told without a mail server.
  """

  @behaviour AshBpmn.TaskNotifier

  require Logger

  @impl true
  def deliver(%AshBpmn.Notice{} = notice, _ctx) do
    Logger.info(
      "notice #{notice.kind} for task #{notice.task.id} (#{notice.key}) to " <>
        Enum.map_join(notice.recipients, ", ", &"#{&1.type}:#{&1.id}")
    )

    :ok
  end
end
