# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.ConditionalCatchTest do
  @moduledoc """
  A token waiting for its subject to become something.

  The distinguishing property is that the condition is asked of the subject **as it now is**,
  read live, and not of the event's snapshot. The snapshot is what a particular write
  contained; the condition is about the record, and on a partial update those are different
  questions with different answers.
  """

  use AshBpmn.DataCase, async: false

  require Ash.Query

  alias AshBpmn.Runtime.Oban.TestJobs
  alias AshBpmn.Test.{Definition, Instance, ProcessEvent, Subject, Token}
  alias AshBpmn.Triggers.Correlator

  setup do
    AshBpmn.Test.Invoker.clear_calls()
    TestJobs.clear()
    :ok
  end

  test "the token parks on the subject's identity, with nothing for a modeller to write" do
    {instance, subject} = start!(amount: 0)

    token = token_at(instance, "AwaitFunding")
    assert token.status == :waiting
    assert token.subscription_signature == "conditional:subject"

    # The correlation is the subject's own id. A message catch makes the modeller write both
    # halves of this; here there is nothing to get wrong.
    assert token.correlation_key == subject.id
  end

  test "an update that satisfies the condition wakes it" do
    {instance, subject} = start!(amount: 0)

    Subject.update!(subject, %{amount: 2_500})
    deliver_update!(subject)

    assert reload(instance).status == :completed
    assert invoked?("release")
    assert [_] = Enum.filter(events(instance), &(&1.kind == :condition_met))
  end

  test "an update that does not satisfy it leaves the token waiting, and records nothing" do
    # Most updates to a watched record will not satisfy the condition. One row per
    # non-matching write would bury the log in exactly the place somebody looks to find out
    # why a process is still waiting.
    {instance, subject} = start!(amount: 0)

    Subject.update!(subject, %{amount: 10})
    deliver_update!(subject)

    assert token_at(instance, "AwaitFunding").status == :waiting
    assert events(instance) |> Enum.filter(&(&1.kind == :condition_met)) == []
  end

  test "the condition is asked of the record, not of the event's snapshot" do
    # The event here carries no amount at all -- as a partial update would not. Reading the
    # snapshot would answer null and the token would never wake, however funded the account
    # actually was.
    {instance, subject} = start!(amount: 0)

    Subject.update!(subject, %{amount: 5_000})
    deliver_update!(subject, data: %{name: "renamed"})

    assert reload(instance).status == :completed
  end

  test "an unrelated record's update does not wake a token whose own subject would satisfy it" do
    # The case that makes the identity filter correctness rather than optimisation. This
    # subject is *already* funded, so the condition is true of it -- and the update is to
    # something else entirely. Without correlating on identity first, any write anywhere to a
    # watched resource would wake it, and the process would appear to respond to an event that
    # had nothing to do with it.
    {instance, subject} = start!(amount: 0)
    Subject.update!(subject, %{amount: 5_000})

    {:ok, other} = Subject.create!(%{name: "other", amount: 1, is_privileged: false})
    deliver_update!(other)

    assert token_at(instance, "AwaitFunding").status == :waiting
    refute invoked?("release")

    # And the token still wakes when its own subject is what changed.
    deliver_update!(subject)
    assert reload(instance).status == :completed
  end

  describe "refusing" do
    test "a conditional catch with no condition is refused" do
      xml =
        String.replace(
          File.read!("test/fixtures/conditional_catch.bpmn"),
          ~r|<bpmn2:condition .*?</bpmn2:condition>|s,
          ""
        )

      defn = Definition.create!(%{key: key(), name: "C", xml: xml})
      refute defn.graph
      assert errors(defn) =~ "waiting for nothing to become true"
    end

    test "a conditional catch with no ash:subscribe is refused, and says why it matters" do
      xml =
        String.replace(
          File.read!("test/fixtures/conditional_catch.bpmn"),
          ~s(<ash:subscribe resource="subject"/>),
          ""
        )

      defn = Definition.create!(%{key: key(), name: "C", xml: xml})
      refute defn.graph
      assert errors(defn) =~ "every write in the system"
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp key, do: "cc_#{System.unique_integer([:positive])}"
  defp errors(defn), do: Enum.map_join(defn.errors, " ", & &1["message"])

  defp start!(amount: amount) do
    xml = File.read!("test/fixtures/conditional_catch.bpmn")
    defn = Definition.create!(%{key: key(), name: "CC", xml: xml})
    if is_nil(defn.graph), do: raise("compile failed: #{inspect(defn.errors)}")
    defn = Definition.publish!(defn)

    {:ok, subject} = Subject.create!(%{name: "cc", amount: amount, is_privileged: false})

    {:ok, instance} =
      AshBpmn.start_instance(AshBpmn.Test.Domain, definition: defn, subject: subject)

    {instance, subject}
  end

  defp deliver_update!(subject, opts \\ []) do
    event = %{
      id: "evt-#{System.unique_integer([:positive])}",
      sequence: System.unique_integer([:positive]),
      occurred_at: DateTime.utc_now(),
      resource: "subject",
      action: :update,
      action_type: :update,
      record_id: subject.id,
      version: 2,
      actor: nil,
      tenant: nil,
      data: Keyword.get(opts, :data, %{amount: subject.amount}),
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

  defp invoked?(action) do
    Enum.any?(AshBpmn.Test.Invoker.recorded_calls(), fn {_id, a, _ts} -> a == action end)
  end

  defp reload(instance) do
    Instance
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^instance.id)
    |> Ash.read_one!(authorize?: false)
  end

  defp token_at(instance, node_id) do
    Token
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(instance_id == ^instance.id and node_id == ^node_id)
    |> Ash.read!(authorize?: false)
    |> List.first()
  end

  defp events(instance) do
    ProcessEvent
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(instance_id == ^instance.id)
    |> Ash.read!(authorize?: false)
  end
end
