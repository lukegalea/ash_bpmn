# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.ServiceTaskFailureTest do
  @moduledoc """
  What a failed service task leaves behind, and what a retry of its job does with it.

  The bug these pin: the advance job claimed the token (`:active -> :executing`), the node
  raised, and nothing put the token back. Every Oban retry then looked for an `:active` token,
  found none, and crashed on `nil.status` -- a `BadMapError` that told the operator nothing --
  while the instance stayed `:running` forever. The claim-time `max_attempts` check that was
  meant to fail the instance could never be reached, because no retry ever claimed again.

  Inline mode has no Oban between the caller and the node, so these tests drive
  `AdvanceWorker.perform/1` directly with the `attempt` a real retry would carry.
  """

  use AshBpmn.DataCase, async: false

  require Ash.Query

  alias AshBpmn.Runtime.AdvanceWorker
  alias AshBpmn.Runtime.Oban.TestJobs
  alias AshBpmn.Test.{Definition, Instance, Invoker, ProcessEvent, Token}

  setup do
    Invoker.clear_calls()
    TestJobs.clear()
    on_exit(fn -> Invoker.clear_calls() end)
    :ok
  end

  describe "a service task that errors" do
    test "leaves its token re-claimable rather than executing" do
      {instance, token} = start_failing!()

      assert token.status == :active
      assert token.attempts == 1
      assert reload_instance(instance).status == :running
    end

    test "a retry raises the node's own error, never a BadMapError on the token" do
      {instance, token} = start_failing!()

      error =
        assert_raise RuntimeError, fn ->
          AdvanceWorker.perform(retry_job(instance, token, attempt: 2))
        end

      assert error.message =~ "service task 'do_something' failed"
      assert reload_token(token).status == :active
      assert reload_token(token).attempts == 2
    end

    test "a retry after the cause is fixed advances the instance" do
      {instance, token} = start_failing!()

      Invoker.set_result(:ok)

      assert {:ok, :advanced} = AdvanceWorker.perform(retry_job(instance, token, attempt: 2))
      assert reload_instance(instance).status == :completed
      assert reload_token(token).status == :consumed
    end

    test "exhausting the engine's attempts fails the instance and kills the token" do
      {instance, token} = start_failing!()
      max = AshBpmn.Config.max_attempts()

      # Attempts 2..max-1 fail and hand the token back for the next retry.
      for attempt <- 2..(max - 1) do
        assert_raise RuntimeError, fn ->
          AdvanceWorker.perform(retry_job(instance, token, attempt: attempt))
        end

        assert reload_token(token).status == :active
      end

      # The last one the engine allows gives up: the documented `:failed` + `:action_failed`.
      assert {:ok, :failed_permanently} =
               AdvanceWorker.perform(retry_job(instance, token, attempt: max))

      assert reload_instance(instance).status == :failed
      assert reload_token(token).status == :dead

      assert [event] = events(instance, :action_failed)
      assert event.node_id == "Service_1"
      assert event.token_id == token.id
      assert event.data["reason"] == "max_attempts_exceeded"
      assert event.data["attempts"] == max
      assert event.data["error"] =~ "boom"

      # And a stray redelivery afterwards is a no-op, not a crash.
      assert {:ok, :skipped} =
               AdvanceWorker.perform(retry_job(instance, token, attempt: max + 1))
    end

    test "Oban's last attempt fails the instance even inside the engine's budget" do
      # Oban stops retrying at the job's `max_attempts` whatever the engine's own budget says.
      # Giving up only at the engine's count would let Oban discard the job first and leave the
      # instance `:running` with nothing left to move it.
      {instance, token} = start_failing!()

      assert {:ok, :failed_permanently} =
               AdvanceWorker.perform(retry_job(instance, token, attempt: 3, max_attempts: 3))

      assert reload_instance(instance).status == :failed
      assert reload_token(token).status == :dead
    end

    test "retry_instance resumes a failed instance once the cause is fixed" do
      {instance, token} = start_failing!()
      exhaust!(instance, token)
      assert reload_instance(instance).status == :failed

      Invoker.set_result(:ok)

      retried = AshBpmn.retry_instance!(reload_instance(instance))

      assert retried.status == :completed
      assert reload_token(token).status == :consumed
    end
  end

  describe "a job that resumes while its token is still executing" do
    # The node died mid-job: the claim committed, nothing after it did, and Oban's Lifeline
    # (or an ordinary retry of a job that raised outside the node) runs the job again.

    test "re-claims a stale claim and advances" do
      {instance, token} = start_failing!()
      Invoker.set_result(:ok)
      force_executing!(token, seconds_ago: AshBpmn.Config.claim_timeout() + 60)

      assert {:ok, :advanced} = AdvanceWorker.perform(retry_job(instance, token, attempt: 2))
      assert reload_instance(instance).status == :completed
    end

    test "snoozes while the claim is still fresh" do
      {instance, token} = start_failing!()
      force_executing!(token, seconds_ago: 0)

      assert {:snooze, seconds} =
               AdvanceWorker.perform(retry_job(instance, token, attempt: 2))

      assert seconds > 0 and seconds <= AshBpmn.Config.claim_timeout()
      assert reload_token(token).status == :executing
    end

    test "a first attempt finding the token executing is a redelivery and skips" do
      {instance, token} = start_failing!()
      force_executing!(token, seconds_ago: AshBpmn.Config.claim_timeout() + 60)

      assert {:ok, :skipped} = AdvanceWorker.perform(retry_job(instance, token, attempt: 1))
      assert reload_token(token).status == :executing
    end
  end

  test "a node failing on the far side of a join leaves a token its own job can retry" do
    # The join dispatches the next node inline, in the arriving branch's job -- whose token the
    # join has just killed, so a retry of that job skips. The new token must not be left
    # `:executing` with no job coming for it.
    assert_raise RuntimeError, ~r/ash:call/, fn ->
      start!("join_then_failing_call.bpmn", raise?: true)
    end

    instance = latest_instance!()
    assert [token] = tokens_at(instance, "AfterJoin")
    assert token.status == :active
    assert reload_instance(instance).status == :running

    assert_raise RuntimeError, ~r/ash:call/, fn ->
      AdvanceWorker.perform(retry_job(instance, token, attempt: 2))
    end

    assert reload_token(token).status == :active
  end

  test "a job whose token has moved on skips rather than crashing" do
    instance = start!("linear.bpmn")
    assert reload_instance(instance).status == :completed

    [token] = tokens_at(instance, "Service_1")
    assert token.status == :consumed

    assert {:ok, :skipped} = AdvanceWorker.perform(retry_job(instance, token, attempt: 2))
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp start_failing! do
    Invoker.set_result({:error, "boom"})

    assert_raise RuntimeError, ~r/service task 'do_something' failed/, fn ->
      start!("linear.bpmn", raise?: true)
    end

    instance = latest_instance!()
    [token] = tokens_at(instance, "Service_1")
    {instance, token}
  end

  defp exhaust!(instance, token) do
    max = AshBpmn.Config.max_attempts()

    for attempt <- 2..(max - 1) do
      assert_raise RuntimeError, fn ->
        AdvanceWorker.perform(retry_job(instance, token, attempt: attempt))
      end
    end

    {:ok, :failed_permanently} = AdvanceWorker.perform(retry_job(instance, token, attempt: max))
  end

  defp start!(fixture, opts \\ []) do
    xml = File.read!("test/fixtures/#{fixture}")
    key = "stf_#{System.unique_integer([:positive])}"
    Process.put(:stf_key, key)

    defn = Definition.create!(%{key: key, name: "STF", xml: xml})
    if is_nil(defn.graph), do: raise("compile failed: #{inspect(defn.errors)}")
    defn = Definition.publish!(defn)

    {:ok, subject} = AshBpmn.Test.Subject.create!(%{name: "stf", amount: 0, is_privileged: false})

    if opts[:raise?] do
      AshBpmn.start_instance!(AshBpmn.Test.Domain, definition: defn, subject: subject)
    else
      {:ok, instance} =
        AshBpmn.start_instance(AshBpmn.Test.Domain, definition: defn, subject: subject)

      instance
    end
  end

  defp latest_instance! do
    key = Process.get(:stf_key)

    Instance
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(definition.key == ^key)
    |> Ash.read_one!(authorize?: false)
  end

  # The args a real advance job carries, with the attempt a retry would arrive with.
  defp retry_job(instance, token, opts) do
    %Oban.Job{
      id: System.unique_integer([:positive]),
      attempt: Keyword.fetch!(opts, :attempt),
      max_attempts: Keyword.get(opts, :max_attempts, 20),
      args: %{
        "instance_id" => instance.id,
        "token_id" => token.id,
        "node_id" => token.node_id,
        "domain" => to_string(AshBpmn.Test.Domain)
      }
    }
  end

  # The state a node that died mid-job leaves: claimed, and claimed `seconds_ago`. Written
  # with SQL because no action may produce it -- that is the point of it being a crash.
  defp force_executing!(token, seconds_ago: seconds) do
    at = DateTime.add(DateTime.utc_now(), -seconds, :second)

    AshBpmn.TestRepo.query!(
      "UPDATE bpmn_tokens SET status = 'executing', updated_at = $1 WHERE id = $2",
      [at, Ecto.UUID.dump!(token.id)]
    )
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

  defp reload_instance(instance) do
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
end
