# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.InvocationKeyTest do
  @moduledoc """
  The invocation key a service task hands its callee: `{instance_id, token_id, node_id}`.

  An advance job runs at least once, so a callee can be asked to do the same work twice. The
  key is what lets it notice: every redelivery of one execution of the node carries the same
  key, and every new execution of the node carries a new one. Both bindings receive it -- the
  `ActionInvoker` in its ctx, an `ash:call` callable in its action context.

  Inline mode has no Oban between the caller and the node, so the redelivery tests drive
  `AdvanceWorker.perform/1` directly with the `attempt` a real retry would carry.
  """

  use AshBpmn.DataCase, async: false

  require Ash.Query

  alias AshBpmn.Runtime.AdvanceWorker
  alias AshBpmn.Runtime.Oban.TestJobs
  alias AshBpmn.Test.{CallablesRecorder, Definition, Instance, Invoker, Subject, Token}

  setup do
    Invoker.clear_calls()
    CallablesRecorder.clear()
    TestJobs.clear()
    on_exit(fn -> Invoker.clear_calls() end)
    :ok
  end

  describe "the ActionInvoker binding" do
    test "receives the instance, the token and the node" do
      instance = start!("linear.bpmn")
      [token] = tokens_at(instance, "Service_1")

      assert [{_, "do_something", ctx}] = Invoker.recorded_ctxs()
      assert ctx[:invocation_key] == {instance.id, token.id, "Service_1"}
    end

    test "a retry of the advance job carries the key the failed attempt carried" do
      Invoker.set_result({:error, "the lab is unavailable"})

      assert_raise RuntimeError, fn -> start!("linear.bpmn", raise?: true) end

      instance = latest_instance!()
      [token] = tokens_at(instance, "Service_1")

      Invoker.set_result(:ok)
      assert {:ok, :advanced} = AdvanceWorker.perform(retry_job(instance, token, attempt: 2))

      assert invocation_keys("do_something") == [
               {instance.id, token.id, "Service_1"},
               {instance.id, token.id, "Service_1"}
             ]
    end

    test "a claim recovered from a worker that died mid-node carries the same key" do
      Invoker.set_result({:error, "the lab is unavailable"})

      assert_raise RuntimeError, fn -> start!("linear.bpmn", raise?: true) end

      instance = latest_instance!()
      [token] = tokens_at(instance, "Service_1")
      force_executing!(token, seconds_ago: AshBpmn.Config.claim_timeout() + 60)

      Invoker.set_result(:ok)
      assert {:ok, :advanced} = AdvanceWorker.perform(retry_job(instance, token, attempt: 2))

      assert invocation_keys("do_something") |> Enum.uniq() == [
               {instance.id, token.id, "Service_1"}
             ]
    end

    test "retry_instance after the engine gave up carries the same key" do
      Invoker.set_result({:error, "the lab is unavailable"})

      assert_raise RuntimeError, fn -> start!("linear.bpmn", raise?: true) end

      instance = latest_instance!()
      [token] = tokens_at(instance, "Service_1")

      assert {:ok, :failed_permanently} =
               AdvanceWorker.perform(retry_job(instance, token, attempt: 3, max_attempts: 3))

      Invoker.set_result(:ok)
      assert AshBpmn.retry_instance!(reload(instance)).status == :completed

      assert invocation_keys("do_something") |> Enum.uniq() == [
               {instance.id, token.id, "Service_1"}
             ]
    end

    test "each execution of the node has a key of its own" do
      # Three instances of one multi-instance activity are three executions of one node: a
      # callee deduplicating on the key must run all three, not the first.
      instance = start_multi_instance!(["p1", "p2", "p3"])

      keys = invocation_keys("onboard")
      instance_token_ids = instance |> tokens_at("Onboard") |> Enum.reject(&is_nil(&1.fork_id))

      assert length(Enum.uniq(keys)) == 3

      assert Enum.sort(keys) ==
               instance_token_ids
               |> Enum.map(&{instance.id, &1.id, "Onboard"})
               |> Enum.sort()
    end
  end

  describe "the ash:call binding" do
    test "the callable finds the key in its action context" do
      instance = start!("ash_call.bpmn", amount: 5000)
      [token] = tokens_at(instance, "RecordCall")

      assert [record] =
               CallablesRecorder.recorded()
               |> Enum.filter(&(&1.action == "record_inputs"))

      assert record.invocation_key == {instance.id, token.id, "RecordCall"}
      # Beside the engine's mark, not instead of it.
      assert record.engine_context? == true
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp invocation_keys(action) do
    for {_id, ^action, ctx} <- Invoker.recorded_ctxs(), do: ctx[:invocation_key]
  end

  defp start!(fixture, opts \\ []) do
    xml = File.read!("test/fixtures/#{fixture}")
    key = "ik_#{System.unique_integer([:positive])}"
    Process.put(:ik_key, key)

    defn = Definition.create!(%{key: key, name: "Invocation key", xml: xml})
    if is_nil(defn.graph), do: raise("compile failed: #{inspect(defn.errors)}")
    defn = Definition.publish!(defn)

    {:ok, subject} =
      Subject.create!(%{
        name: "ik",
        amount: Keyword.get(opts, :amount, 0),
        is_privileged: false
      })

    if opts[:raise?] do
      AshBpmn.start_instance!(AshBpmn.Test.Domain, definition: defn, subject: subject)
    else
      {:ok, instance} =
        AshBpmn.start_instance(AshBpmn.Test.Domain, definition: defn, subject: subject)

      instance
    end
  end

  defp start_multi_instance!(ids) do
    xml = File.read!("test/fixtures/multi_instance.bpmn")

    defn =
      Definition.create!(%{
        key: "ik_mi_#{System.unique_integer([:positive])}",
        name: "MI",
        xml: xml
      })

    defn = Definition.publish!(defn)

    {:ok, subject} =
      Subject.create!(%{name: "ik", amount: 0, is_privileged: false, property_ids: ids})

    {:ok, instance} =
      AshBpmn.start_instance(AshBpmn.Test.Domain, definition: defn, subject: subject)

    instance
  end

  defp latest_instance! do
    key = Process.get(:ik_key)

    Instance
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(definition.key == ^key)
    |> Ash.read_one!(authorize?: false)
  end

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

  defp reload(instance) do
    Instance
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^instance.id)
    |> Ash.read_one!(authorize?: false)
  end
end
