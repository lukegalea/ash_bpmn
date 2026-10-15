# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.SweepExecutingTest do
  @moduledoc """
  The sweep recovers tokens whose worker died holding the claim.

  An advance job claims its token (`:active -> :executing`) before running the node, and only
  the job hands it on. A worker killed after the claim -- a deploy, the OOM killer, a lost
  node -- left the token `:executing` with nothing coming for it, and the sweep only looked at
  `:active` and `:waiting` tokens, so it stayed that way forever.

  The sweep now takes back a claim older than `claim_timeout` with a compare-and-set and
  re-enqueues the advance. These pin the three properties that make that safe: a fresh claim
  is left alone, a poison node still runs out of attempts, and a worker that was merely slow
  cannot advance the token a second time.
  """

  use AshBpmn.DataCase, async: false

  require Ash.Query

  alias AshBpmn.Runtime.Oban.TestJobs
  alias AshBpmn.Runtime.SweepWorker
  alias AshBpmn.Test.{Definition, Instance, Invoker, ProcessEvent, Token}

  setup do
    Invoker.clear_calls()
    TestJobs.clear()
    on_exit(fn -> Invoker.clear_calls() end)
    :ok
  end

  test "a claim older than claim_timeout is taken back and the instance advances" do
    {instance, token} = start_parked_at_service!()
    abandon_claim!(token, seconds_ago: AshBpmn.Config.claim_timeout() + 60)

    assert {:ok, :swept} = sweep()

    assert reload(instance).status == :completed
    assert reload_token(token).status == :consumed

    assert [event] = recoveries(instance)
    assert event.token_id == token.id
    assert event.data["problem"] == "stale_claim"
    assert event.data["claimed_for_seconds"] >= AshBpmn.Config.claim_timeout()
  end

  test "a claim younger than claim_timeout is left alone" do
    {instance, token} = start_parked_at_service!()
    abandon_claim!(token, seconds_ago: 0)

    assert {:ok, :swept} = sweep()

    assert reload_token(token).status == :executing
    assert reload(instance).status == :running
    assert recoveries(instance) == []
  end

  test "recovery is idempotent: a second sweep, or a racing one, does nothing more" do
    {instance, token} = start_parked_at_service!()
    abandon_claim!(token, seconds_ago: AshBpmn.Config.claim_timeout() + 60)
    seen = reload_token(token)

    assert {:ok, :swept} = sweep()
    assert {:ok, :swept} = sweep()
    assert length(recoveries(instance)) == 1

    # A sweep that read the token before the first one recovered it loses the compare-and-set
    # instead of claiming it a second time.
    assert {:error, _} = Token.recover(seen, authorize?: false)
  end

  test "a node that kills its worker every time still runs out of attempts" do
    {instance, token} = start_parked_at_service!()
    max = AshBpmn.Config.max_attempts()

    # The worker has died holding the claim on every attempt the budget allows.
    abandon_claim!(token, seconds_ago: AshBpmn.Config.claim_timeout() + 60, attempts: max)

    assert {:ok, :swept} = sweep()

    assert reload(instance).status == :failed
    assert reload_token(token).status == :dead

    assert [failed] = events(instance, :action_failed)
    assert failed.token_id == token.id
    assert failed.data["attempts"] == max + 1
    assert failed.data["error"] =~ "attempts exhausted"
  end

  test "a worker that was merely slow cannot advance the token a second time" do
    {instance, slow_token} = start_slow_worker!()

    # Everything the recovery path did happened while the slow worker's action was running:
    # the sweep took the claim back, a fresh job claimed and advanced the token, and the
    # instance completed. Then the slow worker finished.
    assert reload(instance).status == :completed
    assert length(recoveries(instance)) == 1

    # Its step found somebody else's claim on the token and wrote nothing: one end token, one
    # completion, the node's events once.
    assert [_end_token] = tokens_at(instance, "End_1")
    assert length(events(instance, :instance_completed)) == 1
    assert length(events(instance, :action_invoked)) == 1
    assert reload_token(slow_token).status == :consumed

    # The host action ran in both workers -- the one cost of being wrong about a slow worker,
    # and the reason the docs say to keep `claim_timeout` above the slowest service task.
    assert Enum.count(Invoker.recorded_calls(), fn {_, action, _} -> action == "do_something" end) ==
             2
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp sweep, do: SweepWorker.perform(%Oban.Job{args: %{}})

  # Runs the instance to its service task and leaves the token there as a dead worker would:
  # the service fails once, so the token is handed back `:active`, and `abandon_claim!/2` then
  # puts it in the state a worker killed mid-node leaves.
  defp start_parked_at_service! do
    Invoker.set_result({:error, "boom"})

    assert_raise RuntimeError, ~r/service task 'do_something' failed/, fn ->
      start!()
    end

    Invoker.set_result(:ok)

    instance = latest_instance!()
    [token] = tokens_at(instance, "Service_1")
    {instance, token}
  end

  # The slow worker: its action runs the recovery path -- claim gone stale, the sweep -- before
  # it returns. The recovered job's own invocation answers `:ok` straight away.
  defp start_slow_worker! do
    test_pid = self()

    Invoker.set_result(fn ->
      Invoker.set_result(:ok)
      instance = latest_instance!()
      [token] = tokens_at(instance, "Service_1")
      send(test_pid, {:slow_token, token})
      abandon_claim!(token, seconds_ago: AshBpmn.Config.claim_timeout() + 60)
      {:ok, :swept} = sweep()
      :ok
    end)

    start!()

    assert_received {:slow_token, token}
    {latest_instance!(), token}
  end

  # The state a worker killed mid-node leaves: claimed, `seconds_ago`. Written with SQL because
  # no action may produce it -- that is the point of it being a crash.
  defp abandon_claim!(token, opts) do
    at = DateTime.add(DateTime.utc_now(), -Keyword.fetch!(opts, :seconds_ago), :second)
    attempts = Keyword.get(opts, :attempts, token.attempts)

    AshBpmn.TestRepo.query!(
      "UPDATE bpmn_tokens SET status = 'executing', attempts = $1, updated_at = $2 WHERE id = $3",
      [attempts, at, Ecto.UUID.dump!(token.id)]
    )
  end

  defp start! do
    xml = File.read!("test/fixtures/linear.bpmn")
    key = "sweepx_#{System.unique_integer([:positive])}"
    Process.put(:sweepx_key, key)

    defn = Definition.create!(%{key: key, name: "SweepX", xml: xml})
    if is_nil(defn.graph), do: raise("compile failed: #{inspect(defn.errors)}")
    defn = Definition.publish!(defn)

    {:ok, subject} =
      AshBpmn.Test.Subject.create!(%{name: "sweepx", amount: 0, is_privileged: false})

    AshBpmn.start_instance!(AshBpmn.Test.Domain, definition: defn, subject: subject)
  end

  defp latest_instance! do
    key = Process.get(:sweepx_key)

    Instance
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(definition.key == ^key)
    |> Ash.read_one!(authorize?: false)
  end

  defp tokens_at(instance, node_id) do
    Token
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(instance_id == ^instance.id and node_id == ^node_id)
    |> Ash.read!(authorize?: false)
  end

  defp reload_token(token) do
    Token
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^token.id)
    |> Ash.read_one!(authorize?: false)
  end

  defp reload(instance) do
    Instance
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^instance.id)
    |> Ash.read_one!(authorize?: false)
  end

  defp events(instance, kind) do
    ProcessEvent
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(instance_id == ^instance.id and kind == ^kind)
    |> Ash.read!(authorize?: false)
  end

  defp recoveries(instance) do
    instance
    |> events(:sweep_recovered)
    |> Enum.filter(&(&1.data["problem"] == "stale_claim"))
  end
end
