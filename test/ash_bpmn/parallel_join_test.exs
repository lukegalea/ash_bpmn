# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.ParallelJoinTest do
  @moduledoc """
  A parallel join fires once, when every branch that can still reach it has arrived.

  The join used to look only at its immediate source nodes, and only for `:active` and
  `:executing` tokens. A branch more than one node long, or one parked on a user task or a
  receive task, looked as if it would never arrive: the join fired at the first arrival, fired
  again when the slow branch got there, and the node after the join ran twice.
  """

  use AshBpmn.DataCase, async: false

  require Ash.Query

  alias AshBpmn.Runtime.AdvanceWorker
  alias AshBpmn.Triggers.Correlator

  alias AshBpmn.Test.{
    Definition,
    FaultInjection,
    Instance,
    Invoker,
    ProcessEvent,
    Resolver,
    Token
  }

  @denied {:error, {:bpmn_error, "COVERAGE_DENIED", %{}}}

  setup do
    Invoker.clear_calls()
    FaultInjection.clear()

    on_exit(fn ->
      Invoker.clear_calls()
      FaultInjection.clear()
    end)

    :ok
  end

  describe "branches of different lengths" do
    test "a branch two steps long is waited for, and the node after the join runs once" do
      instance = start!("join_two_step_branch.bpmn")

      assert reload(instance).status == :completed
      assert invoked("book_visit") == 1
      assert ran_after?("book_visit", ["check_coverage", "offer_self_pay", "check_allergies"])
    end

    test "three branches one, two and three nodes long join once, after all of them" do
      instance = start!("join_three_branches.bpmn")

      assert reload(instance).status == :completed
      assert invoked("after_join") == 1
      assert ran_after?("after_join", ["a1", "b1", "b2", "c1", "c2", "c3"])
      assert [fired] = firings(instance, "Join_1")
      assert length(fired.data["arrived_token_ids"]) == 3
    end
  end

  describe "branches parked before the join" do
    test "waits for a user task and a receive task two nodes back, payment first" do
      {instance, subject} = start_with_subject!("join_waiting_branches.bpmn")

      assert invoked("quick_check") == 1
      assert invoked("after_join") == 0
      assert reload(instance).status == :running

      deliver_payment!(subject)
      assert invoked("settle") == 1
      assert invoked("after_join") == 0
      assert reload(instance).status == :running

      complete!(instance, "Review", :approved)
      assert invoked("after_join") == 1
      assert reload(instance).status == :completed
    end

    test "waits for a user task and a receive task two nodes back, review first" do
      {instance, subject} = start_with_subject!("join_waiting_branches.bpmn")

      complete!(instance, "Review", :approved)
      assert invoked("file_review") == 1
      assert invoked("after_join") == 0
      assert reload(instance).status == :running

      deliver_payment!(subject)
      assert invoked("after_join") == 1
      assert reload(instance).status == :completed
    end
  end

  describe "a branch taken somewhere else" do
    test "a review that rejects after its sibling arrived releases the join once" do
      instance = start!("join_pruned_branch.bpmn")

      assert invoked("quick_check") == 1
      assert invoked("after_join") == 0
      assert reload(instance).status == :running

      complete!(instance, "Review", :rejected)

      assert invoked("extra_check") == 0
      assert invoked("after_join") == 1
      assert reload(instance).status == :completed
    end

    test "a review that approves is waited for through the node after it" do
      instance = start!("join_pruned_branch.bpmn")

      complete!(instance, "Review", :approved)

      assert invoked("extra_check") == 1
      assert invoked("after_join") == 1
      assert ran_after?("after_join", ["quick_check", "extra_check"])
      assert reload(instance).status == :completed
    end
  end

  describe "a join inside a loop" do
    test "each pass uses its own arrivals, so the node after the join runs once per pass" do
      instance = start!("join_in_loop.bpmn")
      assert invoked("tally") == 1

      complete!(instance, "Review", :again)
      assert invoked("tally") == 2
      assert invoked("b2") == 2

      complete!(instance, "Review", :again)
      assert invoked("tally") == 3

      complete!(instance, "Review", :done)
      assert reload(instance).status == :completed
      assert invoked("tally") == 3
      assert length(firings(instance, "Join_1")) == 3
    end
  end

  describe "one step at a time, through real Oban" do
    # Inline jobs run each branch to the end before the next starts, so the order the branches
    # reach the join is whatever order the fork's jobs were inserted in. These drive every step
    # by hand.
    setup do
      previous = Application.get_env(:ash_bpmn, :oban_testing)
      Application.put_env(:ash_bpmn, :oban_testing, nil)
      start_supervised!({Oban, repo: AshBpmn.TestRepo, testing: :manual})
      on_exit(fn -> Application.put_env(:ash_bpmn, :oban_testing, previous) end)
      :ok
    end

    test "the short branch arrives first and waits while the long one is still two nodes back" do
      instance = start!("join_two_step_branch.bpmn")
      step!(instance, "Start_1")
      step!(instance, "Fork_1")
      step!(instance, "AllergyCheck")

      assert {:ok, :waiting_for_siblings} = step!(instance, "Join_1")
      assert tokens_at(instance, "BookVisit") == []
      assert [%{status: :active}] = tokens_at(instance, "CoverageCheck")

      step!(instance, "CoverageCheck")
      step!(instance, "OfferSelfPay")
      step!(instance, "CoverageSettled")

      assert {:ok, :joined} = step!(instance, "Join_1")
      assert [%{status: :active}] = tokens_at(instance, "BookVisit")

      step!(instance, "BookVisit")
      step!(instance, "End_1")
      assert reload(instance).status == :completed
      assert invoked("book_visit") == 1
    end

    test "two branches arriving together fire the join once" do
      instance = start!("join_two_step_branch.bpmn")

      for node <- ~w(Start_1 Fork_1 AllergyCheck CoverageCheck OfferSelfPay CoverageSettled),
          do: step!(instance, node)

      arrivals = tokens_at(instance, "Join_1")
      assert length(arrivals) == 2
      assert Enum.all?(arrivals, &(&1.status == :active))

      results = Enum.map(arrivals, &perform(instance, &1, 1))
      assert Enum.sort(results) == [{:ok, :joined}, {:ok, :waiting_for_siblings}]

      assert [%{status: :active}] = tokens_at(instance, "BookVisit")
      assert [fired] = firings(instance, "Join_1")
      assert Enum.sort(fired.data["arrived_token_ids"]) == Enum.sort(Enum.map(arrivals, & &1.id))
    end

    test "a redelivered or retried arrival job does not fire the join again" do
      instance = start!("join_two_step_branch.bpmn")

      for node <- ~w(Start_1 Fork_1 AllergyCheck CoverageCheck OfferSelfPay CoverageSettled),
          do: step!(instance, node)

      arrivals = tokens_at(instance, "Join_1")
      Enum.each(arrivals, &perform(instance, &1, 1))

      for arrival <- arrivals, attempt <- [1, 2] do
        assert {:ok, :skipped} = perform(instance, arrival, attempt)
      end

      assert [_one] = tokens_at(instance, "BookVisit")
      assert [_fired] = firings(instance, "Join_1")
    end

    test "a fault while the join fires rolls the arrival back, and the retry fires it once" do
      instance = start!("join_two_step_branch.bpmn")

      for node <-
            ~w(Start_1 Fork_1 AllergyCheck Join_1 CoverageCheck OfferSelfPay CoverageSettled),
          do: step!(instance, node)

      [last] = tokens_at(instance, "Join_1", :active)
      FaultInjection.fail_event!(:node_completed)

      assert_fault(fn -> perform(instance, last, 1) end)
      assert tokens_at(instance, "BookVisit") == []
      assert [%{status: :active, attempts: 1}] = tokens_at(instance, "Join_1", :active)
      assert firings(instance, "Join_1") == []

      assert {:ok, :joined} = perform(instance, last, 2)
      assert [_one] = tokens_at(instance, "BookVisit")
      assert [_fired] = firings(instance, "Join_1")
    end

    test "a branch an error boundary takes away from the join releases it once" do
      instance = start!("join_boundary_diverts.bpmn")
      step!(instance, "Start_1")
      step!(instance, "Fork_1")
      step!(instance, "Quick")

      assert {:ok, :waiting_for_siblings} = step!(instance, "Join_1")

      Invoker.set_result("check_coverage", @denied)
      drain!(instance)

      assert invoked("notify_denied") == 1
      assert invoked("after_join") == 1
      assert [_fired] = firings(instance, "Join_1")
      assert reload(instance).status == :completed
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp start!(fixture), do: fixture |> start_with_subject!() |> elem(0)

  defp start_with_subject!(fixture) do
    k = "pj_#{System.unique_integer([:positive])}"
    defn = Definition.create!(%{key: k, name: k, xml: File.read!("test/fixtures/#{fixture}")})
    if is_nil(defn.graph), do: raise("compile failed: #{inspect(defn.errors)}")
    defn = Definition.publish!(defn)

    {:ok, subject} = AshBpmn.Test.Subject.create!(%{name: k, amount: 0, is_privileged: false})

    {:ok, instance} =
      AshBpmn.start_instance(AshBpmn.Test.Domain, definition: defn, subject: subject)

    {instance, subject}
  end

  defp complete!(instance, node_id, outcome) do
    [task] =
      AshBpmn.Test.HumanTask
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(instance_id == ^instance.id and node_id == ^node_id and status == :open)
      |> Ash.read!(authorize?: false)

    {:ok, _} =
      AshBpmn.complete_task(task,
        outcome: outcome,
        actor: %{id: Resolver.role_member("approver")}
      )
  end

  defp deliver_payment!(subject) do
    event = %{
      id: "evt-#{System.unique_integer([:positive])}",
      sequence: System.unique_integer([:positive]),
      occurred_at: DateTime.utc_now(),
      resource: "payment",
      action: :create,
      action_type: :create,
      record_id: Ash.UUID.generate(),
      version: 1,
      actor: nil,
      tenant: nil,
      data: %{invoice_id: subject.id},
      changed: %{},
      metadata: %{}
    }

    {:ok, resources} = AshBpmn.Resources.for_domain(AshBpmn.Test.Domain)

    Correlator.dispatch_event(event, [], %{
      event_source: AshBpmn.Test.EventSource,
      resources: resources,
      scope: AshBpmn.Scope.system(:sweep)
    })
  end

  defp step!(instance, node_id) do
    [token] = tokens_at(instance, node_id, :active)
    perform(instance, token, 1)
  end

  # Every live, runnable token, until there are none.
  defp drain!(instance) do
    case Token
         |> Ash.Query.for_read(:read)
         |> Ash.Query.filter(instance_id == ^instance.id and status == :active)
         |> Ash.read!(authorize?: false) do
      [] ->
        :ok

      tokens ->
        Enum.each(tokens, &perform(instance, &1, 1))
        drain!(instance)
    end
  end

  defp perform(instance, token, attempt) do
    AdvanceWorker.perform(%Oban.Job{
      id: System.unique_integer([:positive]),
      attempt: attempt,
      max_attempts: 20,
      args: %{
        "instance_id" => instance.id,
        "token_id" => token.id,
        "node_id" => token.node_id,
        "domain" => to_string(AshBpmn.Test.Domain)
      }
    })
  end

  defp assert_fault(fun) do
    fun.()
    flunk("expected the injected fault to raise")
  rescue
    error in [ExUnit.AssertionError] -> reraise error, __STACKTRACE__
    error -> assert Exception.message(error) =~ "injected fault"
  end

  defp tokens_at(instance, node_id, status \\ nil) do
    Token
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(instance_id == ^instance.id and node_id == ^node_id)
    |> Ash.read!(authorize?: false)
    |> Enum.filter(&(is_nil(status) or &1.status == status))
  end

  defp firings(instance, join_id) do
    ProcessEvent
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(
      instance_id == ^instance.id and node_id == ^join_id and kind == :node_completed
    )
    |> Ash.read!(authorize?: false)
  end

  defp reload(instance) do
    Instance
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^instance.id)
    |> Ash.read_one!(authorize?: false)
  end

  defp invoked(action), do: Enum.count(Invoker.recorded_calls(), fn {_, a, _} -> a == action end)

  # Every call of each action in `before` comes before the first call of `action`.
  defp ran_after?(action, before) do
    calls = Invoker.recorded_calls()
    first = Enum.find_index(calls, fn {_, a, _} -> a == action end)

    first != nil and
      Enum.all?(before, fn b ->
        indices = for {{_, ^b, _}, i} <- Enum.with_index(calls), do: i
        indices != [] and Enum.all?(indices, &(&1 < first))
      end)
  end
end
