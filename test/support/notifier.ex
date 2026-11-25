# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.Test.Notifier do
  @moduledoc """
  Test double for `AshBpmn.TaskNotifier`. Sends nothing anywhere: it records each notice it
  is handed, in the calling process, as the resolver double does.

  `fail_times/2` makes the next `n` deliveries fail with a reason, so a retry is reachable;
  `fail_always/1` makes every delivery fail; `raise_next/1` makes the next one raise;
  `answer_next/1` makes the next one answer anything, such as a final failure or a partial
  delivery.
  """

  @behaviour AshBpmn.TaskNotifier

  @impl true
  def deliver(%AshBpmn.Notice{} = notice, ctx) do
    Process.put({__MODULE__, :attempts}, attempts() ++ [notice.key])

    case Process.get({__MODULE__, :stage}) do
      {:fail, n, reason} when n > 0 ->
        Process.put({__MODULE__, :stage}, {:fail, n - 1, reason})
        {:error, reason}

      {:always, reason} ->
        {:error, reason}

      {:raise, message} ->
        Process.delete({__MODULE__, :stage})
        raise message

      {:answer, answer} ->
        Process.delete({__MODULE__, :stage})
        answer

      _ ->
        Process.put({__MODULE__, :delivered}, delivered() ++ [{notice, ctx}])
        :ok
    end
  end

  @doc "The notices delivered in this process, in order, with their contexts."
  @spec delivered() :: [{AshBpmn.Notice.t(), map()}]
  def delivered, do: Process.get({__MODULE__, :delivered}, [])

  @doc "The notices delivered in this process, in order."
  @spec notices() :: [AshBpmn.Notice.t()]
  def notices, do: Enum.map(delivered(), &elem(&1, 0))

  @doc "The key of every delivery attempt, failed or not, in order."
  @spec attempts() :: [String.t()]
  def attempts, do: Process.get({__MODULE__, :attempts}, [])

  @doc "The next `n` deliveries answer `{:error, reason}`."
  def fail_times(n, reason \\ :channel_down),
    do: Process.put({__MODULE__, :stage}, {:fail, n, reason})

  @doc "Every delivery answers `{:error, reason}`."
  def fail_always(reason \\ :channel_down),
    do: Process.put({__MODULE__, :stage}, {:always, reason})

  @doc "The next delivery answers `answer` as it is, recording nothing as delivered."
  def answer_next(answer), do: Process.put({__MODULE__, :stage}, {:answer, answer})

  @doc "The next delivery raises."
  def raise_next(message), do: Process.put({__MODULE__, :stage}, {:raise, message})

  @doc "Forgets everything recorded and staged."
  def clear do
    Process.delete({__MODULE__, :delivered})
    Process.delete({__MODULE__, :attempts})
    Process.delete({__MODULE__, :stage})
  end
end
