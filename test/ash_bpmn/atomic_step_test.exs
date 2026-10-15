# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.AtomicStepTest do
  @moduledoc """
  A node step's writes commit together or not at all.

  Advancing a token through a node writes the token's own transition, the tokens that replace
  it, the process events and the jobs that carry the next steps. These were separate writes, so
  a crash between two of them left a graph no recovery could read: here, a service token
  `:consumed` with nothing recorded for the action it ran, and an `:active` token at the end
  event that no job would ever advance -- a half-finished node the retry then skipped, because
  its token had moved on.

  The fault is injected on the `:action_invoked` event, which a service task writes after it
  has consumed its token, minted the next one and recorded `:node_completed`, and before the
  next advance job is inserted -- a crash between two of the step's writes.
  """

  use AshBpmn.DataCase, async: false

  require Ash.Query

  alias AshBpmn.Runtime.AdvanceWorker
  alias AshBpmn.Runtime.Oban.TestJobs
  alias AshBpmn.Test.{Definition, FaultInjection, Instance, Invoker, ProcessEvent, Token}

  setup do
    Invoker.clear_calls()
    TestJobs.clear()
    FaultInjection.clear()

    on_exit(fn ->
      Invoker.clear_calls()
      FaultInjection.clear()
    end)

    :ok
  end

  describe "a step that fails between two of its writes" do
    test "leaves none of them behind" do
      FaultInjection.fail_event!(:action_invoked)

      assert_fault(fn -> start!() end)

      instance = latest_instance!()

      # The token is exactly as the job claimed it, handed back for the retry -- not consumed.
      assert [service] = tokens_at(instance, "Service_1")
      assert service.status == :active
      assert service.attempts == 1

      # Nothing the step wrote survived it: no successor token, no event for the node.
      assert tokens_at(instance, "End_1") == []
      assert events(instance, "Service_1") == []
      assert reload(instance).status == :running
    end

    test "the retry then runs the node once, cleanly" do
      FaultInjection.fail_event!(:action_invoked)
      assert_fault(fn -> start!() end)

      instance = latest_instance!()
      [service] = tokens_at(instance, "Service_1")

      assert {:ok, :advanced} = AdvanceWorker.perform(retry_job(instance, service, attempt: 2))

      assert reload(instance).status == :completed
      assert [end_token] = tokens_at(instance, "End_1")
      assert end_token.status == :consumed

      assert instance |> events("Service_1") |> Enum.map(& &1.kind) |> Enum.sort() ==
               [:action_invoked, :node_completed]
    end

    test "a step that exhausts its attempts fails the instance in one step too" do
      # The give-up is a step of its own -- the dead token, the `:failed` instance and the
      # `:action_failed` event -- so a fault in its last write leaves the token as it was for
      # the next attempt rather than a dead token on a running instance.
      Invoker.set_result({:error, "boom"})
      assert_raise RuntimeError, fn -> start!() end

      instance = latest_instance!()
      [service] = tokens_at(instance, "Service_1")

      FaultInjection.fail_event!(:action_failed)

      assert_fault(fn ->
        AdvanceWorker.perform(retry_job(instance, service, attempt: 3, max_attempts: 3))
      end)

      assert reload(instance).status == :running
      assert reload_token(service).status == :executing
      assert events(instance, "Service_1") == []
    end
  end

  describe "with real Oban" do
    # Inline mode has no table, so it cannot show the half of the guarantee that matters most:
    # a job inserted inside the step is part of the transaction. These run the production path,
    # `Oban.insert/2` into `oban_jobs`, through an Oban instance in manual testing mode.
    setup do
      previous = Application.get_env(:ash_bpmn, :oban_testing)
      Application.put_env(:ash_bpmn, :oban_testing, nil)
      start_supervised!({Oban, repo: AshBpmn.TestRepo, testing: :manual})
      on_exit(fn -> Application.put_env(:ash_bpmn, :oban_testing, previous) end)
      :ok
    end

    test "a job inserted by a step that rolls back is not in oban_jobs" do
      {:ok, instance} = start!()
      perform_next!(instance, "Start_1")

      [service] = tokens_at(instance, "Service_1")
      FaultInjection.fail_event!(:action_invoked)

      assert_fault(fn -> AdvanceWorker.perform(job_for(instance, service, attempt: 1)) end)

      assert tokens_at(instance, "End_1") == []

      assert advance_jobs(instance) |> Enum.map(& &1.args["node_id"]) |> Enum.sort() ==
               ["Service_1", "Start_1"]
    end

    test "a step that commits inserts its job with it" do
      {:ok, instance} = start!()
      perform_next!(instance, "Start_1")
      perform_next!(instance, "Service_1")

      assert [end_token] = tokens_at(instance, "End_1")

      assert [job] = Enum.filter(advance_jobs(instance), &(&1.args["node_id"] == "End_1"))
      assert job.args["token_id"] == end_token.id
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  # The injected raise reaches the caller wrapped by Ash as an unknown error; what matters is
  # that it is the injected one.
  defp assert_fault(fun) do
    fun.()
    flunk("expected the injected fault to raise")
  rescue
    error in [ExUnit.AssertionError] -> reraise error, __STACKTRACE__
    error -> assert Exception.message(error) =~ "injected fault"
  end

  defp start! do
    xml = File.read!("test/fixtures/linear.bpmn")
    key = "atomic_#{System.unique_integer([:positive])}"
    Process.put(:atomic_key, key)

    defn = Definition.create!(%{key: key, name: "Atomic", xml: xml})
    if is_nil(defn.graph), do: raise("compile failed: #{inspect(defn.errors)}")
    defn = Definition.publish!(defn)

    {:ok, subject} =
      AshBpmn.Test.Subject.create!(%{name: "atomic", amount: 0, is_privileged: false})

    case AshBpmn.start_instance(AshBpmn.Test.Domain, definition: defn, subject: subject) do
      {:error, %{__exception__: true} = e} -> raise e
      other -> other
    end
  end

  defp latest_instance! do
    key = Process.get(:atomic_key)

    Instance
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(definition.key == ^key)
    |> Ash.read_one!(authorize?: false)
  end

  defp perform_next!(instance, node_id) do
    [token] = tokens_at(instance, node_id)
    assert {:ok, _} = AdvanceWorker.perform(job_for(instance, token, attempt: 1))
  end

  defp job_for(instance, token, opts), do: retry_job(instance, token, opts)

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

  defp advance_jobs(instance) do
    import Ecto.Query, only: [where: 3]

    worker = Oban.Worker.to_string(AdvanceWorker)

    Oban.Job
    |> where([j], j.worker == ^worker)
    |> where([j], fragment("? @> ?", j.args, ^%{"instance_id" => instance.id}))
    |> AshBpmn.TestRepo.all()
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

  defp events(instance, node_id) do
    ProcessEvent
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(instance_id == ^instance.id and node_id == ^node_id)
    |> Ash.read!(authorize?: false)
  end
end
