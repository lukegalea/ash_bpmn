# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.Test.FaultInjection do
  @moduledoc """
  Fails a write partway through a step, so a test can see what the step leaves behind.

  Attached to the test `ProcessEvent` resource's create. `fail_event!/1` arms it for one event
  kind; the next create of that kind raises, which is a crash between two of the writes a
  node step makes -- the token transitions and the events before it already done, the job
  after it not yet inserted. Armed per process, because the engine runs inline in the test's
  own process.
  """
  use Ash.Resource.Change

  @key {__MODULE__, :fail_event}

  @doc "Makes the next process event of `kind` created in this process raise."
  def fail_event!(kind) when is_atom(kind), do: Process.put(@key, kind)

  @doc "Disarms it."
  def clear, do: Process.delete(@key)

  @impl true
  def change(changeset, _opts, _context) do
    kind = Ash.Changeset.get_attribute(changeset, :kind)

    if kind && Process.get(@key) == kind do
      Process.delete(@key)
      raise "injected fault: writing the #{kind} event"
    end

    changeset
  end
end
