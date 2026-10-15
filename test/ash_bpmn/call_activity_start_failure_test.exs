# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.CallActivityStartFailureTest do
  @moduledoc """
  A call activity whose child cannot be started resolves like a failed service task.

  The bug this pins: the call activity parked its token and recorded `:node_entered`, then
  tried to start the child. When the start failed -- here, because nothing is published under
  the key it names -- the park had already committed, so Oban's retry found the token
  `:waiting` rather than `:active` and skipped. The parent waited for a child that was never
  started, forever, with nothing in the log to say so.

  Now the start is part of the call activity's step, so its failure rolls the park back with
  it, and the failure takes the service task's path: handed back for a retry, and on the last
  attempt the instance `:failed` with an `:action_failed` event that names the call activity.
  BPMN would route an error boundary here if the model had one; this subset admits boundary
  events on user tasks only, so the give-up is the whole answer.

  Inline mode has no Oban between the caller and the node, so retries are driven through
  `AdvanceWorker.perform/1` with the `attempt` a real retry would carry.
  """

  use AshBpmn.DataCase, async: false

  require Ash.Query

  alias AshBpmn.Runtime.AdvanceWorker
  alias AshBpmn.Runtime.Oban.TestJobs
  alias AshBpmn.Test.{Definition, Instance, ProcessEvent, Token}

  setup do
    AshBpmn.Test.Invoker.clear_calls()
    TestJobs.clear()
    :ok
  end

  test "the call activity's token is handed back, not left parked" do
    {parent, _child_key} = start_with_missing_child!()

    assert [token] = tokens_at(parent, "Onboard")
    assert token.status == :active
    assert token.attempts == 1
    assert reload(parent).status == :running

    # The rolled-back step recorded nothing: no `:node_entered` claiming the parent is waiting
    # for a child, and no child.
    assert events(parent, "Onboard") == []
    assert children_of(parent) == []
  end

  test "a retry raises the start's own error" do
    {parent, child_key} = start_with_missing_child!()
    [token] = tokens_at(parent, "Onboard")

    error =
      assert_raise RuntimeError, fn ->
        AdvanceWorker.perform(retry_job(parent, token, attempt: 2))
      end

    assert error.message =~ "call activity Onboard could not start #{child_key}"
    assert reload_token(token).status == :active
    assert reload_token(token).attempts == 2
  end

  test "the last attempt fails the instance with :action_failed" do
    {parent, child_key} = start_with_missing_child!()
    [token] = tokens_at(parent, "Onboard")

    assert {:ok, :failed_permanently} =
             AdvanceWorker.perform(retry_job(parent, token, attempt: 3, max_attempts: 3))

    assert reload(parent).status == :failed
    assert reload_token(token).status == :dead

    assert [event] = events(parent, "Onboard", :action_failed)
    assert event.token_id == token.id
    assert event.data["reason"] == "max_attempts_exceeded"
    assert event.data["error"] =~ "could not start #{child_key}"
    assert event.data["error"] =~ "no published definition"
  end

  test "publishing the child and retrying starts it and the parent carries on" do
    {parent, child_key} = start_with_missing_child!()
    [token] = tokens_at(parent, "Onboard")

    publish!("linear.bpmn", child_key)

    assert {:ok, :advanced} = AdvanceWorker.perform(retry_job(parent, token, attempt: 2))

    assert [child] = children_of(parent)
    assert child.status == :completed
    assert reload(parent).status == :completed
  end

  test "retry_instance brings a failed call activity back once the child exists" do
    {parent, child_key} = start_with_missing_child!()
    [token] = tokens_at(parent, "Onboard")

    {:ok, :failed_permanently} =
      AdvanceWorker.perform(retry_job(parent, token, attempt: 3, max_attempts: 3))

    publish!("linear.bpmn", child_key)

    assert AshBpmn.retry_instance!(reload(parent)).status == :completed
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp key, do: "casf_#{System.unique_integer([:positive])}"

  defp publish!(fixture, k) do
    xml = File.read!("test/fixtures/#{fixture}")
    defn = Definition.create!(%{key: k, name: k, xml: xml})
    if is_nil(defn.graph), do: raise("compile failed: #{inspect(defn.errors)}")
    Definition.publish!(defn)
  end

  # The parent names a child key nothing is published under, so the child's start fails.
  defp start_with_missing_child! do
    child_key = key()
    parent_key = key()

    parent_xml =
      File.read!("test/fixtures/call_parent.bpmn")
      |> String.replace("CHILD_KEY", child_key)

    parent_defn = Definition.create!(%{key: parent_key, name: "parent", xml: parent_xml})
    if is_nil(parent_defn.graph), do: raise("compile failed: #{inspect(parent_defn.errors)}")
    parent_defn = Definition.publish!(parent_defn)

    {:ok, subject} =
      AshBpmn.Test.Subject.create!(%{name: "casf", amount: 0, is_privileged: true})

    # Inline, the first advance runs inside the start and its failure comes back from it.
    assert {:error, %RuntimeError{message: message}} =
             AshBpmn.start_instance(AshBpmn.Test.Domain,
               definition: parent_defn,
               subject: subject
             )

    assert message =~ "could not start #{child_key}"

    parent =
      Instance
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(definition.key == ^parent_key)
      |> Ash.read_one!(authorize?: false)

    {parent, child_key}
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

  defp children_of(parent) do
    Instance
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(parent_instance_id == ^parent.id)
    |> Ash.read!(authorize?: false)
  end

  defp reload(instance) do
    Instance
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^instance.id)
    |> Ash.read_one!(authorize?: false)
  end

  defp reload_token(token) do
    Token
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^token.id)
    |> Ash.read_one!(authorize?: false)
  end

  defp tokens_at(instance, node_id) do
    Token
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(instance_id == ^instance.id and node_id == ^node_id)
    |> Ash.read!(authorize?: false)
  end

  defp events(instance, node_id) do
    ProcessEvent
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(instance_id == ^instance.id and node_id == ^node_id)
    |> Ash.read!(authorize?: false)
  end

  defp events(instance, node_id, kind),
    do: instance |> events(node_id) |> Enum.filter(&(&1.kind == kind))
end
