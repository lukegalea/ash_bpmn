# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.TestJobsTest do
  @moduledoc """
  The inline-mode job table.

  Both tests start from no table at all, which is the state a host's suite is in when its
  first async tests store their first timers.
  """

  # async: false because each test stops the owner of the VM-wide named ETS table
  # `:ash_bpmn_test_jobs`, which every other test storing a timer depends on.
  use ExUnit.Case, async: false

  alias AshBpmn.Runtime.Oban.TestJobs

  @owner :ash_bpmn_test_jobs_owner

  setup do
    drop_table()
    on_exit(&TestJobs.ensure_started/0)
  end

  test "the table outlives the process that stored the first job" do
    task =
      Task.async(fn ->
        TestJobs.store(%{id: 1, worker: __MODULE__, args: %{}, scheduled_at: nil, meta: %{}})
      end)

    :ok = Task.await(task)
    ref = Process.monitor(task.pid)
    assert_receive {:DOWN, ^ref, :process, _, _}

    assert [%{id: 1}] = TestJobs.all()
  end

  test "many processes starting the table at once all succeed, and one owner holds it" do
    parent = self()

    pids =
      for _ <- 1..50 do
        spawn(fn ->
          receive do
            :go -> send(parent, {self(), start_reporting_errors()})
          end
        end)
      end

    Enum.each(pids, &send(&1, :go))

    results =
      for pid <- pids do
        assert_receive {^pid, result}, 5_000
        result
      end

    assert Enum.all?(results, &(&1 == :ok))
    assert is_pid(Process.whereis(@owner))
    refute :ets.whereis(:ash_bpmn_test_jobs) == :undefined
  end

  defp start_reporting_errors do
    TestJobs.ensure_started()
  rescue
    error -> error
  end

  defp drop_table do
    case Process.whereis(@owner) do
      nil ->
        if :ets.whereis(:ash_bpmn_test_jobs) != :undefined, do: :ets.delete(:ash_bpmn_test_jobs)

      pid ->
        ref = Process.monitor(pid)
        send(pid, :stop)
        assert_receive {:DOWN, ^ref, :process, ^pid, _}
    end

    assert :ets.whereis(:ash_bpmn_test_jobs) == :undefined
  end
end
