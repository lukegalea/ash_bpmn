# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.NoticesTest do
  @moduledoc """
  Escalation adds people and the engine keeps the exclusions (DESIGN.md §11.6); a fired timer
  tells people through the host's `AshBpmn.TaskNotifier` (§11.7); and a diagram that declares a
  reminder or an escalation nobody wired up is refused at publish (§11.8).

  The negative cases come first. Missing, failed or unmeasured is never recorded as a pass:
  a timer that told nobody says so in the event log.
  """

  use AshBpmn.DataCase, async: false

  require Ash.Query

  alias AshBpmn.ApprovalTestSupport.ApprovalSubject
  alias AshBpmn.Runtime.Oban.TestJobs
  alias AshBpmn.Runtime.TimerWorker
  alias AshBpmn.Scope
  alias AshBpmn.Test.{Definition, HumanTask, Notifier, ProcessEvent, Resolver, TaskCandidate}

  setup do
    TestJobs.clear()
    AshBpmn.ApprovalTestSupport.ensure_table!()
    Resolver.clear_escalations()
    Notifier.clear()

    on_exit(fn ->
      Resolver.clear_escalations()
      Notifier.clear()
    end)

    :ok
  end

  # ── §11.8: refused at publication ─────────────────────────────────────────

  describe "a draft whose timers reach people nobody wired up" do
    test "a remind timer with no task notifier is refused, naming the node" do
      without_notifier()

      defn = draft!(~s(<ash:timer kind="remind" hours="4"/>))

      assert is_nil(defn.graph)
      assert [error] = refusals(defn)
      assert error_node(error) == "Review_1"
      assert error_message(error) =~ "remind timer"
      assert error_message(error) =~ "no task notifier is configured"
    end

    test "an escalate timer with no task notifier is refused" do
      without_notifier()

      defn = draft!(~s(<ash:timer kind="escalate" hours="24"/>))

      assert [error] = refusals(defn)
      assert error_message(error) =~ "no task notifier is configured"
    end

    test "an escalate timer is refused when the resolver has no escalate/2" do
      with_resolver(AshBpmn.Test.NoEscalateResolver)

      defn = draft!(~s(<ash:timer kind="escalate" hours="24"/>))

      assert [error] = refusals(defn)
      assert error_message(error) =~ "does not implement escalate/2"
    end

    test "an escalate timer that throws a signal needs neither" do
      without_notifier()
      with_resolver(AshBpmn.Test.NoEscalateResolver)

      defn = draft!(~s(<ash:timer kind="escalate" hours="24" signal="approval.stalled"/>))

      assert defn.graph
      assert refusals(defn) == []
    end

    test "an expire timer needs no notifier: expiry is an outcome, not a notice" do
      without_notifier()

      defn = draft!(~s(<ash:timer kind="expire" hours="24"/>))

      assert defn.graph
    end

    test "a wired host publishes the same draft" do
      defn =
        draft!(~s(<ash:timer kind="remind" hours="4"/><ash:timer kind="escalate" hours="24"/>))

      assert defn.graph
      assert refusals(defn) == []
    end
  end

  describe "a standalone approval whose timers reach people nobody wired up" do
    test "remind_in with no task notifier is refused when the approval is requested" do
      without_notifier()

      assert {:error, error} =
               ApprovalSubject.request_reminded(%{name: name(), created_by_id: uuid()})

      assert Exception.message(error) =~ "no task notifier is configured"
      assert open_tasks("test_reminded_approval") == []
    end

    test "escalate_in is refused when the resolver has no escalate/2" do
      with_resolver(AshBpmn.Test.NoEscalateResolver)

      assert {:error, error} = ApprovalSubject.create(%{name: name(), created_by_id: uuid()})
      assert Exception.message(error) =~ "does not implement escalate/2"
      assert open_tasks("test_approval") == []
    end
  end

  # ── a definition published before the check ──────────────────────────────

  describe "a timer with no notifier to deliver it" do
    test "a remind fires, records :notice_undelivered and emits telemetry" do
      task = reminded_task!()
      without_notifier()
      attach_undelivered()

      assert {:ok, :reminded} = fire(task, "remind")

      assert [event] = events(task, :notice_undelivered)
      assert event.data["reason"] == "no_notifier"
      assert event.data["notice"] == "remind"
      assert event.data["key"] == "#{task.id}/test_reminded_approval/2/1"
      assert events(task, :notice_delivered) == []

      assert_received {:undelivered, %{count: 1}, %{kind: :remind, reason: :no_notifier}}
    end

    test "an expiry still expires, and records no notice" do
      task = reminded_task!()
      without_notifier()

      assert {:ok, :expired} = fire(task, "expire")

      assert reload(task).status == :completed
      assert reload(task).outcome == "expired"
      assert events(task, :notice_undelivered) == []
      assert events(task, :notice_delivered) == []
    end
  end

  # ── §11.7: delivery ──────────────────────────────────────────────────────

  describe "a notifier that fails" do
    test "errors twice, then succeeds: retried with the same key, delivered once" do
      task = reminded_task!()
      Notifier.fail_times(2)

      assert {:error, _} = fire(task, "remind", attempt: 1)
      assert {:error, _} = fire(task, "remind", attempt: 2)
      assert {:ok, :reminded} = fire(task, "remind", attempt: 3)

      key = "#{task.id}/test_reminded_approval/2/1"
      assert Notifier.attempts() == [key, key, key]
      assert [%{key: ^key, kind: :remind}] = Notifier.notices()

      assert [_] = events(task, :notice_delivered)
      assert events(task, :notice_failed) == []
      # The firing itself is recorded once, not once per attempt.
      assert [_] = events(task, :timer_fired)
    end

    test "always errors: :notice_failed on the final attempt, and never :notice_delivered" do
      task = reminded_task!()
      Notifier.fail_always(:smtp_down)

      assert {:error, _} = fire(task, "remind", attempt: 1)
      assert events(task, :notice_failed) == []

      assert {:error, message} = fire(task, "remind", attempt: 3)
      assert message =~ "smtp_down"

      assert [event] = events(task, :notice_failed)
      assert event.data["error"] =~ "smtp_down"
      assert events(task, :notice_delivered) == []
    end

    test "a notifier that raises is retried, not reported as delivered" do
      task = reminded_task!()
      Notifier.raise_next("pool exhausted")

      assert {:error, message} = fire(task, "remind", attempt: 1)
      assert message =~ "pool exhausted"
      assert events(task, :notice_delivered) == []

      assert {:ok, :reminded} = fire(task, "remind", attempt: 2)
      assert [_] = events(task, :notice_delivered)
    end

    test "an expiry whose notice fails has still expired, and the retry only delivers" do
      task = reminded_task!()
      Notifier.fail_times(1)

      assert {:error, _} = fire(task, "expire", attempt: 1)
      assert reload(task).status == :completed
      assert [_] = events(task, :task_expired)

      assert {:ok, :expired} = fire(task, "expire", attempt: 2)
      assert [%{kind: :expired}] = Notifier.notices()
      assert [_] = events(task, :task_expired)
    end
  end

  describe "a task that is over" do
    test "a cancelled task is never told about" do
      task = reminded_task!()
      set_status!(task, :cancelled)

      assert {:ok, :skipped} = fire(task, "remind")
      assert {:ok, :skipped} = fire(task, "escalate")

      assert Notifier.attempts() == []
      assert Resolver.escalations() == []
    end

    test "a completed task is never told about" do
      task = reminded_task!()
      set_status!(task, :completed)

      assert {:ok, :skipped} = fire(task, "remind")
      assert Notifier.attempts() == []
    end
  end

  describe "who a notice goes to" do
    test "an open task's remind goes to its candidates" do
      creator = uuid()
      task = reminded_task!(creator)

      assert {:ok, :reminded} = fire(task, "remind")

      assert [notice] = Notifier.notices()
      assert notice.recipients == [%{type: :user, id: Resolver.manager_of(creator)}]
      assert notice.due_at == task.due_at
      assert notice.repetition == 1
    end

    test "a claimed task's remind goes to the assignee only" do
      creator = uuid()
      task = reminded_task!(creator)
      manager = Resolver.manager_of(creator)

      # Escalate first, so the task has a second candidate the reminder must leave out.
      assert {:ok, :escalated} = fire(task, "escalate")
      assert length(candidate_ids(task)) == 2
      Notifier.clear()

      {:ok, _claimed} = AshBpmn.claim_task(reload(task), actor: %{id: manager})

      assert {:ok, :reminded} = fire(reload(task), "remind")
      assert [notice] = Notifier.notices()
      assert notice.recipients == [%{type: :user, id: manager}]
    end
  end

  # ── §11.6: escalation adds people, the engine keeps the exclusions ───────

  describe "an escalation the resolver answers" do
    test "adds the answer as candidates, records :task_escalated and tells them" do
      creator = uuid()
      task = reminded_task!(creator)
      target = Resolver.escalation_target(creator)

      assert {:ok, :escalated} = fire(task, "escalate")

      assert Enum.sort(candidate_ids(task)) ==
               Enum.sort([Resolver.manager_of(creator), target])

      assert [event] = events(task, :task_escalated)
      assert event.data["added"] == [%{"type" => "user", "id" => target}]
      assert event.data["refused"] == []
      assert event.data["key"] == "#{task.id}/test_reminded_approval/0/1"

      assert [notice] = Notifier.notices()
      assert notice.kind == :escalated
      assert notice.added == [%{type: :user, id: target}]

      assert Enum.sort_by(notice.recipients, & &1.id) ==
               Enum.sort_by(
                 [%{type: :user, id: Resolver.manager_of(creator)}, %{type: :user, id: target}],
                 & &1.id
               )

      # The escalation widens who may act; it never touches the task's state.
      assert reload(task).status == :open
    end

    test "an excluded person it returns is refused, and never told" do
      creator = uuid()
      task = reminded_task!(creator)
      other = uuid()

      Resolver.set_escalate_result(
        {:ok, [%{type: :user, id: creator}, %{type: :user, id: other}]}
      )

      assert {:ok, :escalated} = fire(task, "escalate")

      refute creator in candidate_ids(task)
      assert other in candidate_ids(task)

      assert [event] = events(task, :task_escalated)
      assert event.data["refused"] == [creator]

      assert [notice] = Notifier.notices()
      refute Enum.any?(notice.recipients, &(&1.id == creator))

      # And the creator still cannot act on it.
      assert {:error, _} = AshBpmn.claim_task(reload(task), actor: %{id: creator})
    end

    test "never removes a candidate or the assignee" do
      creator = uuid()
      task = reminded_task!(creator)
      manager = Resolver.manager_of(creator)
      {:ok, _claimed} = AshBpmn.claim_task(task, actor: %{id: manager})

      Resolver.set_escalate_result({:ok, [%{type: :user, id: uuid()}]})
      assert {:ok, :escalated} = fire(reload(task), "escalate")

      assert manager in candidate_ids(task)
      assert reload(task).assignee_id == manager
      assert reload(task).status == :claimed
    end

    test "an excluded member of a team it adds still cannot claim" do
      creator = uuid()
      task = reminded_task!(creator)
      team = uuid()
      member = uuid()
      Resolver.put_team_ids(creator, [team])
      Resolver.put_team_ids(member, [team])
      Resolver.set_escalate_result({:ok, [%{type: :team, id: team}]})

      assert {:ok, :escalated} = fire(task, "escalate")
      assert team in candidate_ids(task)

      assert {:error, _} = AshBpmn.claim_task(reload(task), actor: %{id: creator})
      assert {:ok, claimed} = AshBpmn.claim_task(reload(task), actor: %{id: member})
      assert claimed.assignee_id in [member, team]
    end

    test "a replayed firing adds no duplicates" do
      creator = uuid()
      task = reminded_task!(creator)
      Notifier.fail_times(1)

      assert {:error, _} = fire(task, "escalate", attempt: 1)
      before = candidate_ids(task)
      assert length(before) == 2

      assert {:ok, :escalated} = fire(task, "escalate", attempt: 2)

      assert Enum.sort(candidate_ids(task)) == Enum.sort(before)
      assert [_] = events(task, :task_escalated)
      [first, second] = Notifier.attempts()
      assert first == second
      assert [%{added: [%{id: added}]}] = Notifier.notices()
      assert added == Resolver.escalation_target(creator)
    end
  end

  describe "a notifier that cannot reach someone, and will not try again" do
    test "a final failure is :notice_failed at once, and not retried" do
      task = reminded_task!()
      Notifier.answer_next({:error, {:final, :address_suppressed}})

      assert {:ok, :reminded} = fire(task, "remind", attempt: 1)

      assert [event] = events(task, :notice_failed)
      assert event.data["final"] == true
      assert event.data["error"] =~ "address_suppressed"
      assert events(task, :notice_delivered) == []

      # A redelivery of the same firing asks nobody again.
      assert {:ok, :already_fired} = fire(task, "remind", attempt: 1)
      assert length(Notifier.attempts()) == 1
    end

    test "a partial delivery names who was reached and who was not" do
      creator = uuid()
      task = reminded_task!(creator)
      manager = Resolver.manager_of(creator)
      target = Resolver.escalation_target(creator)
      Notifier.answer_next({:ok, %{not_reached: [{%{type: :user, id: target}, :hard_bounce}]}})

      assert {:ok, :escalated} = fire(task, "escalate")

      assert [event] = events(task, :notice_delivered)
      assert event.data["recipients"] == [%{"type" => "user", "id" => manager}]

      assert event.data["not_reached"] == [
               %{"type" => "user", "id" => target, "reason" => ":hard_bounce"}
             ]

      assert events(task, :notice_failed) == []
    end

    test "a partial delivery that reached nobody is :notice_failed, not delivered" do
      creator = uuid()
      task = reminded_task!(creator)
      manager = Resolver.manager_of(creator)
      Notifier.answer_next({:ok, %{not_reached: [{%{type: :user, id: manager}, :no_address}]}})

      assert {:ok, :reminded} = fire(task, "remind")

      assert events(task, :notice_delivered) == []
      assert [event] = events(task, :notice_failed)
      assert event.data["final"] == true

      assert event.data["not_reached"] == [
               %{"type" => "user", "id" => manager, "reason" => ":no_address"}
             ]
    end

    test "the notifier is told which attempt is the last" do
      task = reminded_task!()
      Notifier.fail_times(1)

      assert {:error, _} = fire(task, "remind", attempt: 1)
      assert {:ok, :reminded} = fire(task, "remind", attempt: 3)

      assert [{_notice, ctx}] = Notifier.delivered()
      assert ctx.final_attempt? == true
    end

    test "a partial answer naming someone who was not a recipient is refused and retried" do
      task = reminded_task!()
      Notifier.answer_next({:ok, %{not_reached: [{%{type: :user, id: uuid()}, :x}]}})

      assert {:error, message} = fire(task, "remind", attempt: 1)
      assert message =~ "not a recipient"
      assert events(task, :notice_delivered) == []
    end
  end

  describe "an escalation of a claimed task" do
    test "names who holds it, in the event and the notice" do
      creator = uuid()
      task = reminded_task!(creator)
      manager = Resolver.manager_of(creator)
      {:ok, _claimed} = AshBpmn.claim_task(task, actor: %{id: manager})

      assert {:ok, :escalated} = fire(reload(task), "escalate")

      assert [event] = events(task, :task_escalated)
      assert event.data["held_by"] == %{"type" => "user", "id" => manager}

      assert [notice] = Notifier.notices()
      assert notice.holder == %{type: :user, id: manager}
    end

    test "an open task's escalation names no holder" do
      task = reminded_task!()

      assert {:ok, :escalated} = fire(task, "escalate")

      assert [event] = events(task, :task_escalated)
      assert event.data["held_by"] == nil
      assert [%{holder: nil}] = Notifier.notices()
    end
  end

  describe "a decision made with authority an escalation gave" do
    test "says so on the claim and the decision" do
      creator = uuid()
      task = reminded_task!(creator)
      target = Resolver.escalation_target(creator)

      assert {:ok, :escalated} = fire(task, "escalate")
      key = "#{task.id}/test_reminded_approval/0/1"

      {:ok, _} = AshBpmn.complete_task(reload(task), outcome: :approved, actor: %{id: target})

      assert [claimed] = events(task, :task_claimed)
      assert claimed.data["authority"] == "escalation"
      assert claimed.data["escalation_keys"] == [key]

      assert [completed] = events(task, :task_completed)
      assert completed.data["authority"] == "escalation"
      assert completed.data["escalation_keys"] == [key]
    end

    test "a decision by a candidate the task started with says nothing of escalation" do
      creator = uuid()
      task = reminded_task!(creator)
      assert {:ok, :escalated} = fire(task, "escalate")

      manager = Resolver.manager_of(creator)
      {:ok, _} = AshBpmn.complete_task(reload(task), outcome: :approved, actor: %{id: manager})

      assert [completed] = events(task, :task_completed)
      refute Map.has_key?(completed.data, "authority")
    end
  end

  describe "an escalation that reaches nobody" do
    test "{:ok, []} records :escalation_reached_nobody and is not retried" do
      task = reminded_task!()
      Resolver.set_escalate_result({:ok, []})

      assert {:ok, :escalation_reached_nobody} = fire(task, "escalate")

      assert [event] = events(task, :escalation_reached_nobody)
      assert event.data["key"] == "#{task.id}/test_reminded_approval/0/1"
      assert events(task, :task_escalated) == []
      assert events(task, :escalation_failed) == []
      assert length(candidate_ids(task)) == 1
      assert Notifier.attempts() == []
    end

    test "an answer the exclusions empty reaches nobody too" do
      creator = uuid()
      task = reminded_task!(creator)
      Resolver.set_escalate_result({:ok, [%{type: :user, id: creator}]})

      assert {:ok, :escalation_reached_nobody} = fire(task, "escalate")

      assert [event] = events(task, :escalation_reached_nobody)
      assert event.data["refused"] == [creator]
      refute creator in candidate_ids(task)
    end

    test "a host with no escalate/2 reaches nobody, and says so" do
      task = reminded_task!()
      with_resolver(AshBpmn.Test.NoEscalateResolver)

      assert {:ok, :no_escalation_handler} = fire(task, "escalate")

      assert [event] = events(task, :escalation_reached_nobody)
      assert event.data["reason"] == "no_escalate_callback"
    end
  end

  describe "an escalation that fails" do
    test "an error is :escalation_failed, adds nobody, and is retried" do
      task = reminded_task!()
      Resolver.set_escalate_result({:error, :directory_down})

      assert {:error, message} = fire(task, "escalate")
      assert message =~ "directory_down"

      assert [_] = events(task, :escalation_failed)
      assert length(candidate_ids(task)) == 1
      assert Notifier.attempts() == []
    end

    test "a raise is :escalation_failed and retried" do
      task = reminded_task!()
      Resolver.set_escalate_result({:__raise__, "directory timeout"})

      assert {:error, message} = fire(task, "escalate")
      assert message =~ "directory timeout"
      assert [_] = events(task, :escalation_failed)
    end

    test "the old contract's bare :ok is :escalation_failed, not a success" do
      task = reminded_task!()
      Resolver.set_escalate_result(:ok)

      assert {:error, message} = fire(task, "escalate")
      assert message =~ "{:ok, [principal]}"
      assert [_] = events(task, :escalation_failed)
      assert events(task, :task_escalated) == []
    end

    test "principals of an undeclared shape are refused" do
      task = reminded_task!()
      Resolver.set_escalate_result({:ok, [uuid()]})

      assert {:error, message} = fire(task, "escalate")
      assert message =~ "undeclared shape"
    end
  end

  describe "in a tenant" do
    test "escalation writes candidates in the task's tenant, and another tenant sees none" do
      tenant = uuid()
      other_tenant = uuid()
      creator = uuid()
      defn = tenant_definition!(tenant, ~s(<ash:timer kind="escalate" hours="4"/>))

      {:ok, subject} =
        AshBpmn.Test.Subject.create!(%{name: "esc", amount: 1, created_by_id: creator})

      {:ok, instance} =
        AshBpmn.start_instance(AshBpmn.TenantTest.Domain,
          definition: defn,
          subject: subject,
          tenant: tenant
        )

      [task] =
        AshBpmn.TenantTest.HumanTask
        |> Ash.Query.filter(instance_id == ^instance.id)
        |> Ash.read!(Scope.engine(%Scope{tenant: tenant}))

      TestJobs.fire!("escalate", task.id)

      target = Resolver.escalation_target(creator)

      in_tenant =
        AshBpmn.TenantTest.TaskCandidate
        |> Ash.Query.filter(task_id == ^task.id)
        |> Ash.read!(Scope.engine(%Scope{tenant: tenant}))

      assert target in Enum.map(in_tenant, & &1.principal_id)
      assert Enum.all?(in_tenant, &(&1.organization_id == tenant))

      assert AshBpmn.TenantTest.TaskCandidate
             |> Ash.Query.filter(task_id == ^task.id)
             |> Ash.read!(Scope.engine(%Scope{tenant: other_tenant})) == []

      assert [notice] = Notifier.notices()
      assert notice.tenant == tenant
      assert [{_notice, ctx}] = Notifier.delivered()
      assert ctx.tenant == tenant
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp reminded_task!(creator \\ uuid()) do
    ApprovalSubject.request_reminded!(%{name: name(), created_by_id: creator})
    [task] = open_tasks("test_reminded_approval", creator)
    task
  end

  defp open_tasks(node_id, creator \\ nil) do
    HumanTask
    |> Ash.Query.filter(node_id == ^node_id and status in [:open, :claimed])
    |> Ash.read!(authorize?: false)
    |> Enum.filter(fn task ->
      is_nil(creator) or creator in (task.excluded_principal_ids || [])
    end)
  end

  # Runs the stored job's args through the worker, as Oban would on attempt `n` of 3.
  defp fire(task, kind, opts \\ []) do
    record =
      Enum.find(TestJobs.all(), fn rec ->
        is_map(rec.args) and rec.args["kind"] == kind and rec.args["task_id"] == task.id
      end) || raise "no #{kind} job for #{task.id}"

    TimerWorker.perform(%Oban.Job{
      id: record.id,
      args: record.args,
      scheduled_at: record[:scheduled_at],
      attempt: Keyword.get(opts, :attempt, 1),
      max_attempts: 3
    })
  end

  defp draft!(timers) do
    Definition.create!(%{
      key: "notice_#{System.unique_integer([:positive])}",
      name: "Notices",
      xml: xml(timers)
    })
  end

  defp refusals(defn), do: defn.errors || []

  defp error_node(error), do: Map.get(error, :path) || Map.get(error, "path")
  defp error_message(error), do: Map.get(error, :message) || Map.get(error, "message")

  defp without_notifier do
    previous = Application.get_env(:ash_bpmn, :task_notifier)
    Application.delete_env(:ash_bpmn, :task_notifier)
    on_exit(fn -> Application.put_env(:ash_bpmn, :task_notifier, previous) end)
  end

  defp with_resolver(resolver) do
    previous = Application.get_env(:ash_bpmn, :assignment_resolver)
    Application.put_env(:ash_bpmn, :assignment_resolver, resolver)
    on_exit(fn -> Application.put_env(:ash_bpmn, :assignment_resolver, previous) end)
  end

  defp attach_undelivered do
    test = self()
    id = "undelivered-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      id,
      AshBpmn.Runtime.Notices.undelivered_event(),
      fn _event, measurements, metadata, _ ->
        send(test, {:undelivered, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)
  end

  defp set_status!(task, status) do
    AshBpmn.TestRepo.query!("UPDATE bpmn_human_tasks SET status = $1 WHERE id = $2", [
      to_string(status),
      Ecto.UUID.dump!(task.id)
    ])
  end

  defp reload(task) do
    HumanTask
    |> Ash.Query.filter(id == ^task.id)
    |> Ash.read_one!(authorize?: false)
  end

  defp candidate_ids(task) do
    TaskCandidate
    |> Ash.Query.filter(task_id == ^task.id)
    |> Ash.read!(authorize?: false)
    |> Enum.map(& &1.principal_id)
  end

  defp events(task, kind) do
    ProcessEvent
    |> Ash.Query.filter(task_id == ^task.id and kind == ^kind)
    |> Ash.read!(authorize?: false)
  end

  defp tenant_definition!(tenant, timers) do
    defn =
      AshBpmn.TenantTest.Definition.create!(
        %{key: "notice_#{System.unique_integer([:positive])}", name: "Notices", xml: xml(timers)},
        Scope.engine(%Scope{tenant: tenant})
      )

    if is_nil(defn.graph), do: raise("compile failed: #{inspect(defn.errors)}")

    AshBpmn.TestRepo.query!(
      "UPDATE tenant_bpmn_definitions SET status = 'published' WHERE id = $1",
      [Ecto.UUID.dump!(defn.id)]
    )

    AshBpmn.TenantTest.Definition
    |> Ash.Query.filter(id == ^defn.id)
    |> Ash.read_one!(Scope.engine(%Scope{tenant: tenant}))
  end

  defp xml(timers) do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <bpmn2:definitions xmlns:bpmn2="http://www.omg.org/spec/BPMN/20100524/MODEL"
                       xmlns:ash="https://github.com/lukegalea/ash_bpmn/ns"
                       id="Definitions_notices"
                       targetNamespace="https://github.com/lukegalea/ash_bpmn/ns">
      <bpmn2:process id="Process_notices" isExecutable="true">
        <bpmn2:startEvent id="Start_1"><bpmn2:outgoing>Flow_1</bpmn2:outgoing></bpmn2:startEvent>
        <bpmn2:userTask id="Review_1" name="Review">
          <bpmn2:extensionElements>
            <ash:taskConfig>
              <ash:candidates><ash:candidate kind="role" of="reviewer"/></ash:candidates>
              <ash:exclusions><ash:exclusion who="subject.created_by_id"/></ash:exclusions>
              <ash:outcomes><ash:outcome name="approved"/></ash:outcomes>
              <ash:timers>#{timers}</ash:timers>
            </ash:taskConfig>
          </bpmn2:extensionElements>
          <bpmn2:incoming>Flow_1</bpmn2:incoming>
          <bpmn2:outgoing>Flow_2</bpmn2:outgoing>
        </bpmn2:userTask>
        <bpmn2:endEvent id="End_1"><bpmn2:incoming>Flow_2</bpmn2:incoming></bpmn2:endEvent>
        <bpmn2:sequenceFlow id="Flow_1" sourceRef="Start_1" targetRef="Review_1"/>
        <bpmn2:sequenceFlow id="Flow_2" sourceRef="Review_1" targetRef="End_1"/>
      </bpmn2:process>
    </bpmn2:definitions>
    """
  end

  defp name, do: "notice_#{System.unique_integer([:positive])}"
  defp uuid, do: Ash.UUID.generate()
end
