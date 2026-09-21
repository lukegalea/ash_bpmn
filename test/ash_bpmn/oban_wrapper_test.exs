# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.ObanWrapperTest do
  @moduledoc """
  The Oban seam, and the three gaps that made Phase 3 timers unbuildable on it.

  Research into Oban 2.23.1 (OSS, no Pro) settled what this layer should and should not do:
  Oban is an excellent timer *engine* — durable scheduling at any horizon, a leader-elected
  promotion loop, retry and backoff, a GIN index on `meta` that makes cancel-by-owner an
  indexed query — and a useless timer *record*, because its Pruner deletes `completed`,
  `cancelled` and `discarded` rows sixty seconds after they land there.

  So the seam gained exactly what Oban does not give us, and nothing it already does:

    * `cancel_all/1` — cancel every job an owner has, by `meta` containment, with no second
      index of job ids to keep in step (and no window between inserting a job and recording
      its id, which is the flaw in the `timer_job_ids` approach it replaces);
    * detection of the **silent unique-insert conflict**, where Oban returns `{:ok, job}` with
      `conflict?: true` and `id: nil` having written no row at all;
    * a virtual clock in inline mode, so "when" is testable.
  """

  use AshBpmn.DataCase, async: false

  alias AshBpmn.Runtime.Oban.TestJobs

  defmodule EchoWorker do
    @moduledoc false
    use Oban.Worker, max_attempts: 1

    def perform(%Oban.Job{args: args}) do
      :ets.insert(:ash_bpmn_test_calls, {{:echo, args["tag"]}, System.monotonic_time()})
      :ok
    end
  end

  defmodule SnoozingWorker do
    @moduledoc false
    use Oban.Worker, max_attempts: 1
    def perform(%Oban.Job{}), do: {:snooze, 60}
  end

  defmodule CancellingWorker do
    @moduledoc false
    use Oban.Worker, max_attempts: 1
    def perform(%Oban.Job{}), do: {:cancel, :not_relevant_any_more}
  end

  setup do
    TestJobs.clear()
    :ets.delete_all_objects(:ash_bpmn_test_calls)
    :ok
  end

  # Sorted by the recorded monotonic time, not by ETS order. `:ets.tab2list/1` on a `:set`
  # returns in arbitrary order, so reading it directly asserts nothing about sequence -- which
  # is why the timestamp is recorded at all.
  defp fired do
    :ash_bpmn_test_calls
    |> :ets.tab2list()
    |> Enum.filter(fn {key, _} -> match?({:echo, _}, key) end)
    |> Enum.sort_by(fn {_, at} -> at end)
    |> Enum.map(fn {{:echo, tag}, _} -> tag end)
  end

  defp in_minutes(n), do: DateTime.add(DateTime.utc_now(), n, :minute)

  describe "cancel_all/1 — cancel every timer an owner holds" do
    test "removes exactly the jobs whose meta matches, and leaves the rest" do
      token = Ash.UUID.generate()
      other = Ash.UUID.generate()

      for kind <- ["remind", "escalate"] do
        AshBpmn.Runtime.Oban.insert(EchoWorker, %{"tag" => kind},
          scheduled_at: in_minutes(30),
          meta: AshBpmn.Runtime.Oban.timer_meta(%{token_id: token, kind: kind})
        )
      end

      AshBpmn.Runtime.Oban.insert(EchoWorker, %{"tag" => "other"},
        scheduled_at: in_minutes(30),
        meta: AshBpmn.Runtime.Oban.timer_meta(%{token_id: other, kind: "remind"})
      )

      assert length(TestJobs.all()) == 3

      assert {:ok, 2} = AshBpmn.Runtime.Oban.cancel_all(%{"token_id" => token})

      remaining = TestJobs.all()
      assert length(remaining) == 1
      assert hd(remaining).meta["token_id"] == other
    end

    test "can defuse one kind of timer while leaving the others armed" do
      # The reason `kind` is in the meta at all: an escalation is cancelled when a task is
      # reassigned, but the reminder that goes with it should survive.
      token = Ash.UUID.generate()

      for kind <- ["remind", "escalate"] do
        AshBpmn.Runtime.Oban.insert(EchoWorker, %{"tag" => kind},
          scheduled_at: in_minutes(30),
          meta: AshBpmn.Runtime.Oban.timer_meta(%{token_id: token, kind: kind})
        )
      end

      assert {:ok, 1} =
               AshBpmn.Runtime.Oban.cancel_all(%{"token_id" => token, "kind" => "escalate"})

      assert [%{meta: %{"kind" => "remind"}}] = TestJobs.all()
    end

    test "matching nothing is zero, not an error" do
      assert {:ok, 0} = AshBpmn.Runtime.Oban.cancel_all(%{"token_id" => Ash.UUID.generate()})
    end
  end

  describe "timer_meta/1" do
    test "stringifies keys and stamps the library, so our jobs are distinguishable" do
      meta = AshBpmn.Runtime.Oban.timer_meta(%{token_id: "abc", kind: :escalate})

      assert meta["token_id"] == "abc"
      assert meta["kind"] == :escalate
      # Cron-inserted jobs carry `meta.cron`; ours carry this, so neither query catches the
      # other's jobs by accident.
      assert meta["ash_bpmn"] == true
    end
  end

  describe "fire_due!/1 — the virtual clock" do
    test "fires what is due and leaves what is not" do
      AshBpmn.Runtime.Oban.insert(EchoWorker, %{"tag" => "soon"}, scheduled_at: in_minutes(10))
      AshBpmn.Runtime.Oban.insert(EchoWorker, %{"tag" => "later"}, scheduled_at: in_minutes(120))

      assert 1 == TestJobs.fire_due!(in_minutes(30))

      assert fired() == ["soon"]
      assert [%{args: %{"tag" => "later"}}] = TestJobs.all()
    end

    test "nothing fires early" do
      AshBpmn.Runtime.Oban.insert(EchoWorker, %{"tag" => "later"}, scheduled_at: in_minutes(120))

      assert 0 == TestJobs.fire_due!(in_minutes(5))
      assert fired() == []
      assert length(TestJobs.all()) == 1
    end

    test "fires in due order, not insertion order" do
      # The assertion that was impossible before this existed. A reminder armed *after* an
      # escalation but due *before* it must still fire first; insertion order would hide it.
      AshBpmn.Runtime.Oban.insert(EchoWorker, %{"tag" => "escalate"},
        scheduled_at: in_minutes(90)
      )

      AshBpmn.Runtime.Oban.insert(EchoWorker, %{"tag" => "remind"}, scheduled_at: in_minutes(30))

      assert 2 == TestJobs.fire_due!(in_minutes(240))
      assert fired() == ["remind", "escalate"]
    end
  end

  describe "inline mode accepts every legal worker return" do
    test "a snoozing worker does not crash the suite" do
      # "Not due yet, check again later" is the natural idiom for a catch that is still
      # waiting. It used to raise CaseClauseError here, which made it untestable.
      assert {:ok, job} = AshBpmn.Runtime.Oban.insert(SnoozingWorker, %{})
      assert job.meta["snoozed_for"] == 60
    end

    test "a self-cancelling worker is an ordinary outcome" do
      assert {:ok, _} = AshBpmn.Runtime.Oban.insert(CancellingWorker, %{})
    end

    test "a scheduled snoozing worker survives the virtual clock too" do
      AshBpmn.Runtime.Oban.insert(SnoozingWorker, %{}, scheduled_at: in_minutes(1))

      assert 1 == TestJobs.fire_due!(in_minutes(5))
    end
  end
end
