# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.Phase3ExitTest do
  @moduledoc """
  The three properties Phase 3's exit criterion names by hand: a claim race, a late event
  after a cancel, and expiry honouring conditions.

  They live together because they are the criterion, not because they share a mechanism. Each
  is the case where a wait goes wrong in a way that looks like nothing going wrong at all.
  """

  use AshBpmn.DataCase, async: false

  require Ash.Query

  alias AshBpmn.Runtime.Oban.TestJobs
  alias AshBpmn.Test.{Definition, HumanTask, Instance, ProcessEvent, Token}
  alias AshBpmn.Triggers.Correlator

  setup do
    AshBpmn.Test.Invoker.clear_calls()
    TestJobs.clear()
    :ok
  end

  describe "expiry honours conditions" do
    test "an expired task routes by its outcome, not by flow order" do
      # `Flow_Approved` sorts before `Flow_Expired`, so the old first-flow behaviour would
      # have granted the request it was supposed to withdraw. That is the shape of bug this
      # criterion exists for: a plausible-looking outcome, arrived at by accident.
      {instance, task} = start_expiry!()

      {:ok, :expired} =
        AshBpmn.Runtime.TimerWorker.perform(%Oban.Job{
          args:
            AshBpmn.Scope.to_job_args(AshBpmn.Scope.system(:timer), %{
              "task_id" => task.id,
              "kind" => "expire"
            })
        })

      assert invoked?("withdraw")
      refute invoked?("grant")
      assert reload(instance).status == :completed
    end

    test "the same diagram decided by a person routes the other way" do
      {instance, task} = start_expiry!()

      HumanTask.claim!(task, %{assignee_type: :user, assignee_id: Ash.UUID.generate()})

      {:ok, _} =
        AshBpmn.complete_task(reload_task(task),
          outcome: :approved,
          actor: %{id: Ash.UUID.generate()}
        )

      assert invoked?("grant")
      refute invoked?("withdraw")
      assert reload(instance).status == :completed
    end
  end

  describe "a late event after a cancel" do
    test "an event arriving after the instance is cancelled wakes nothing" do
      # The wait was legitimate when it started. The event is legitimate too. What must not
      # happen is the two meeting after the instance has been cancelled and resuming a
      # process nobody is running any more.
      {instance, subject} = start_message!()

      AshBpmn.cancel_instance(instance)

      deliver!(%{invoice_id: subject.id})

      assert reload(instance).status == :cancelled
      refute invoked?("settle")
      assert events(instance, :message_received) == []
    end
  end

  describe "a claim race" do
    test "two deliveries of the same event advance the token once" do
      {instance, subject} = start_message!()

      deliver!(%{invoice_id: subject.id})
      deliver!(%{invoice_id: subject.id})

      assert length(events(instance, :message_received)) == 1

      # And exactly one token was minted past the catch node. A second would be a duplicate
      # branch running the rest of the process twice.
      past =
        Token
        |> Ash.Query.for_read(:read)
        |> Ash.Query.filter(instance_id == ^instance.id and node_id == "Settle")
        |> Ash.read!(authorize?: false)

      assert length(past) == 1
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp key, do: "p3_#{System.unique_integer([:positive])}"

  defp publish!(fixture) do
    xml = File.read!("test/fixtures/#{fixture}")
    defn = Definition.create!(%{key: key(), name: "P3", xml: xml})
    if is_nil(defn.graph), do: raise("compile failed: #{inspect(defn.errors)}")
    Definition.publish!(defn)
  end

  defp subject! do
    {:ok, subject} =
      AshBpmn.Test.Subject.create!(%{name: "p3", amount: 0, is_privileged: false})

    subject
  end

  defp start_expiry! do
    {:ok, instance} =
      AshBpmn.start_instance(AshBpmn.Test.Domain,
        definition: publish!("expiry_routing.bpmn"),
        subject: subject!()
      )

    task =
      HumanTask
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(instance_id == ^instance.id)
      |> Ash.read!(authorize?: false)
      |> List.first()

    {instance, task}
  end

  defp start_message! do
    subject = subject!()

    {:ok, instance} =
      AshBpmn.start_instance(AshBpmn.Test.Domain,
        definition: publish!("message_catch.bpmn"),
        subject: subject
      )

    {instance, subject}
  end

  defp deliver!(data) do
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
      data: data,
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

  defp reload_task(task) do
    HumanTask
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^task.id)
    |> Ash.read_one!(authorize?: false)
  end

  defp events(instance, kind) do
    ProcessEvent
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(instance_id == ^instance.id and kind == ^kind)
    |> Ash.read!(authorize?: false)
  end
end
