# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.WhoActsTest do
  @moduledoc """
  Who may claim, complete and delegate a human task, and the candidacy read a host's task
  board is built on. Both reference hosts had to rebuild these checks around the engine
  (ash_bpmn PR #17 lists them); these tests hold the engine to them.
  """
  use AshBpmn.DataCase, async: false

  require Ash.Query

  alias AshBpmn.Runtime.Oban.TestJobs

  alias AshBpmn.Test.{
    Definition,
    FaultInjection,
    HumanTask,
    ProcessEvent,
    Resolver,
    TaskCandidate
  }

  setup do
    TestJobs.clear()
    FaultInjection.clear()
    :ok
  end

  # ── 1. the claim is guarded in the database, and written with its event ──────────────────

  describe "claim guard" do
    test "a claim from a stale struct loses to the claim that already committed" do
      first = %{id: Ash.UUID.generate()}
      second = %{id: Ash.UUID.generate()}
      task = task!(candidates: [{:user, first.id}, {:user, second.id}])

      assert {:ok, _} = AshBpmn.claim_task(task, actor: first)

      # `task` is the struct from before the first claim: still `:open` as far as it knows.
      assert {:error, _} =
               HumanTask.claim(task, %{assignee_type: :user, assignee_id: second.id})

      assert reload(task).assignee_id == first.id
    end

    test "the claim and its :task_claimed event commit together" do
      actor = %{id: Ash.UUID.generate()}
      task = task!(candidates: [{:user, actor.id}])

      FaultInjection.fail_event!(:task_claimed)
      assert {:error, _} = AshBpmn.claim_task(task, actor: actor)

      reloaded = reload(task)
      assert reloaded.status == :open
      assert reloaded.assignee_id == nil
    end

    test "claiming a task that is already claimed is refused" do
      first = %{id: Ash.UUID.generate()}
      second = %{id: Ash.UUID.generate()}
      task = task!(candidates: [{:user, first.id}, {:user, second.id}])

      assert {:ok, _} = AshBpmn.claim_task(task, actor: first)
      assert {:error, _} = AshBpmn.claim_task(task, actor: second)
      assert reload(task).assignee_id == first.id
      assert length(events(task, :task_claimed)) == 1
    end
  end

  # ── 2. team candidates can claim ─────────────────────────────────────────────────────────

  describe "team candidates" do
    test "a member of a candidate team can claim, through the actor's team ids" do
      team_id = Ash.UUID.generate()
      member = %{id: Ash.UUID.generate(), team_ids: [team_id]}
      task = task!(candidates: [{:team, team_id}])

      assert {:ok, claimed} = AshBpmn.claim_task(task, actor: member)
      assert claimed.status == :claimed
      assert claimed.assignee_type == :user
      assert claimed.assignee_id == member.id
    end

    test "a member of a candidate team can claim, through the resolver's team_ids/2" do
      team_id = Ash.UUID.generate()
      member = %{id: Ash.UUID.generate()}
      Resolver.put_team_ids(member.id, [team_id])
      task = task!(candidates: [{:team, team_id}])

      assert {:ok, _} = AshBpmn.claim_task(task, actor: member)
    end

    test "a team row does not admit a user who merely shares its id" do
      id = Ash.UUID.generate()
      task = task!(candidates: [{:team, id}])

      assert {:error, %ArgumentError{}} = AshBpmn.claim_task(task, actor: %{id: id})
    end

    test "a requester excluded by maker-checker cannot claim through a candidate team" do
      team_id = Ash.UUID.generate()
      requester = %{id: Ash.UUID.generate(), team_ids: [team_id]}
      task = task!(candidates: [{:team, team_id}], excluded: [requester.id])

      assert {:error, %ArgumentError{message: message}} =
               AshBpmn.claim_task(task, actor: requester)

      assert message =~ "maker-checker"
      assert reload(task).status == :open
    end

    test "my_tasks matches team rows on team ids" do
      team_id = Ash.UUID.generate()
      task = task!(candidates: [{:team, team_id}])

      assert ids(AshBpmn.my_tasks(AshBpmn.Test.Domain, principal_ids: [], team_ids: [team_id])) ==
               [task.id]
    end

    test "my_tasks takes the user id and team ids from the actor" do
      team_id = Ash.UUID.generate()
      member = %{id: Ash.UUID.generate(), team_ids: [team_id]}
      team_task = task!(candidates: [{:team, team_id}])
      user_task = task!(candidates: [{:user, member.id}])
      _other = task!(candidates: [{:user, Ash.UUID.generate()}])

      assert Enum.sort(ids(AshBpmn.my_tasks(AshBpmn.Test.Domain, actor: member))) ==
               Enum.sort([team_task.id, user_task.id])
    end

    test "my_tasks leaves out a task that excludes the principal" do
      team_id = Ash.UUID.generate()
      requester = %{id: Ash.UUID.generate(), team_ids: [team_id]}
      _task = task!(candidates: [{:team, team_id}], excluded: [requester.id])

      assert AshBpmn.my_tasks(AshBpmn.Test.Domain, actor: requester) == []
    end
  end

  # ── 3. completing checks who ─────────────────────────────────────────────────────────────

  describe "complete_task/2" do
    test "an open task is refused to someone who is not a candidate, and nothing is written" do
      task = task!(candidates: [{:user, Ash.UUID.generate()}])
      stranger = %{id: Ash.UUID.generate()}

      assert {:error, %ArgumentError{message: message}} =
               AshBpmn.complete_task(task, outcome: :approved, actor: stranger)

      assert message =~ "not a candidate"
      assert reload(task).status == :open
      assert events(task, :task_claimed) == []
      assert events(task, :task_completed) == []
    end

    test "an open task is completed by a candidate, who claims it on the way" do
      candidate = %{id: Ash.UUID.generate()}
      task = task!(candidates: [{:user, candidate.id}])

      assert {:ok, completed} =
               AshBpmn.complete_task(task, outcome: :approved, actor: candidate)

      assert completed.status == :completed
      assert completed.decided_by_id == candidate.id
      assert [_] = events(task, :task_claimed)
    end

    test "an open task is completed by a member of a candidate team" do
      team_id = Ash.UUID.generate()
      member = %{id: Ash.UUID.generate(), team_ids: [team_id]}
      task = task!(candidates: [{:team, team_id}])

      assert {:ok, completed} = AshBpmn.complete_task(task, outcome: :approved, actor: member)
      assert completed.decided_by_id == member.id
    end

    test "a claimed task is refused to another candidate" do
      holder = %{id: Ash.UUID.generate()}
      other = %{id: Ash.UUID.generate()}
      task = task!(candidates: [{:user, holder.id}, {:user, other.id}])
      {:ok, _} = AshBpmn.claim_task(task, actor: holder)

      assert {:error, %ArgumentError{message: message}} =
               AshBpmn.complete_task(task, outcome: :approved, actor: other)

      assert message =~ "does not hold"
      assert reload(task).status == :claimed
    end

    test "a claimed task is completed by the person holding it" do
      holder = %{id: Ash.UUID.generate()}
      task = task!(candidates: [{:user, holder.id}])
      {:ok, _} = AshBpmn.claim_task(task, actor: holder)

      assert {:ok, completed} = AshBpmn.complete_task(task, outcome: :approved, actor: holder)
      assert completed.status == :completed
    end

    test "a process task's requester cannot decide their own request" do
      requester_id = Ash.UUID.generate()
      task = process_task!(requester_id)

      assert task.excluded_principal_ids == [requester_id]

      assert {:error, %ArgumentError{}} =
               AshBpmn.complete_task(task, outcome: :approved, actor: %{id: requester_id})

      assert {:ok, _} =
               AshBpmn.complete_task(task,
                 outcome: :approved,
                 actor: %{id: Resolver.manager_of(requester_id)}
               )
    end
  end

  # ── 4. delegating checks the holder and the delegate ─────────────────────────────────────

  describe "delegate_task/2" do
    test "someone who does not hold the task cannot delegate it" do
      holder = %{id: Ash.UUID.generate()}
      other = %{id: Ash.UUID.generate()}
      task = task!(candidates: [{:user, holder.id}, {:user, other.id}])
      {:ok, _} = AshBpmn.claim_task(task, actor: holder)

      assert {:error, %ArgumentError{message: message}} =
               AshBpmn.delegate_task(task,
                 to_principal: %{type: :user, id: other.id},
                 actor: other
               )

      assert message =~ "does not hold"
      assert reload(task).assignee_id == holder.id
      assert events(task, :task_delegated) == []
    end

    test "a delegate who is not a candidate is refused" do
      holder = %{id: Ash.UUID.generate()}
      task = task!(candidates: [{:user, holder.id}])
      {:ok, _} = AshBpmn.claim_task(task, actor: holder)

      assert {:error, %ArgumentError{message: message}} =
               AshBpmn.delegate_task(task,
                 to_principal: %{type: :user, id: Ash.UUID.generate()},
                 actor: holder
               )

      assert message =~ "not a candidate"
      assert reload(task).assignee_id == holder.id
    end

    test "a delegate excluded by maker-checker is refused, even through a candidate team" do
      team_id = Ash.UUID.generate()
      holder = %{id: Ash.UUID.generate(), team_ids: [team_id]}
      requester_id = Ash.UUID.generate()
      Resolver.put_team_ids(requester_id, [team_id])
      task = task!(candidates: [{:team, team_id}], excluded: [requester_id])
      {:ok, _} = AshBpmn.claim_task(task, actor: holder)

      assert {:error, %ArgumentError{message: message}} =
               AshBpmn.delegate_task(task,
                 to_principal: %{type: :user, id: requester_id},
                 actor: holder
               )

      assert message =~ "maker-checker"
      assert reload(task).assignee_id == holder.id
    end

    test "a requester excluded by subtraction is refused as a delegate" do
      requester_id = Ash.UUID.generate()
      task = process_task!(requester_id)
      manager = %{id: Resolver.manager_of(requester_id)}
      {:ok, _} = AshBpmn.claim_task(task, actor: manager)

      assert {:error, %ArgumentError{}} =
               AshBpmn.delegate_task(task,
                 to_principal: %{type: :user, id: requester_id},
                 actor: manager
               )

      assert reload(task).assignee_id == manager.id
    end

    test "a candidate delegate takes the task, and the hand-off is recorded" do
      holder = %{id: Ash.UUID.generate()}
      delegate = %{id: Ash.UUID.generate()}
      task = task!(candidates: [{:user, holder.id}, {:user, delegate.id}])
      {:ok, _} = AshBpmn.claim_task(task, actor: holder)

      assert {:ok, delegated} =
               AshBpmn.delegate_task(task,
                 to_principal: %{type: :user, id: delegate.id},
                 actor: holder
               )

      assert delegated.assignee_id == delegate.id
      assert delegated.delegated_from_id == holder.id
      assert [_] = events(task, :task_delegated)

      # The person who delegated it away no longer holds it.
      assert {:error, %ArgumentError{}} =
               AshBpmn.complete_task(task, outcome: :approved, actor: holder)

      assert {:ok, _} = AshBpmn.complete_task(task, outcome: :approved, actor: delegate)
    end

    test "a task delegated to a candidate team is held by its members" do
      team_id = Ash.UUID.generate()
      holder = %{id: Ash.UUID.generate()}
      member = %{id: Ash.UUID.generate(), team_ids: [team_id]}
      task = task!(candidates: [{:user, holder.id}, {:team, team_id}])
      {:ok, _} = AshBpmn.claim_task(task, actor: holder)

      assert {:ok, delegated} =
               AshBpmn.delegate_task(task,
                 to_principal: %{type: :team, id: team_id},
                 actor: holder
               )

      assert delegated.assignee_type == :team
      assert {:ok, _} = AshBpmn.complete_task(task, outcome: :approved, actor: member)
    end

    test "the delegation and its event commit together" do
      holder = %{id: Ash.UUID.generate()}
      delegate = %{id: Ash.UUID.generate()}
      task = task!(candidates: [{:user, holder.id}, {:user, delegate.id}])
      {:ok, _} = AshBpmn.claim_task(task, actor: holder)

      FaultInjection.fail_event!(:task_delegated)

      assert {:error, _} =
               AshBpmn.delegate_task(task,
                 to_principal: %{type: :user, id: delegate.id},
                 actor: holder
               )

      assert reload(task).assignee_id == holder.id
    end
  end

  # ── 5. the candidacy read, the candidates relationship and the declared outcomes ─────────

  describe "the :awaiting_actor read" do
    test "open tasks the actor or their team is a candidate for, and claimed tasks they hold" do
      team_id = Ash.UUID.generate()
      me = %{id: Ash.UUID.generate(), team_ids: [team_id]}
      someone = %{id: Ash.UUID.generate()}

      mine_open = task!(candidates: [{:user, me.id}])
      team_open = task!(candidates: [{:team, team_id}])
      mine_claimed = task!(candidates: [{:user, me.id}])
      {:ok, _} = AshBpmn.claim_task(mine_claimed, actor: me)

      theirs_claimed = task!(candidates: [{:user, me.id}, {:user, someone.id}])
      {:ok, _} = AshBpmn.claim_task(theirs_claimed, actor: someone)

      _not_mine = task!(candidates: [{:user, someone.id}])
      _excluded = task!(candidates: [{:team, team_id}], excluded: [me.id])

      decided = task!(candidates: [{:user, me.id}])
      {:ok, _} = AshBpmn.complete_task(decided, outcome: :approved, actor: me)

      assert Enum.sort(awaiting(me)) ==
               Enum.sort([mine_open.id, team_open.id, mine_claimed.id])
    end

    test "nothing for no actor, or an actor with no id" do
      _task = task!(candidates: [{:user, Ash.UUID.generate()}])

      assert awaiting(nil) == []
      assert awaiting(AshBpmn.SystemActor.engine()) == []
    end

    test "an actor given only when the query runs still narrows it" do
      me = %{id: Ash.UUID.generate()}
      mine = task!(candidates: [{:user, me.id}])
      _theirs = task!(candidates: [{:user, Ash.UUID.generate()}])

      tasks =
        HumanTask
        |> Ash.Query.for_read(:awaiting_actor)
        |> Ash.read!(actor: me)

      assert ids(tasks) == [mine.id]
    end

    test "a task's candidates load through its relationship" do
      user_id = Ash.UUID.generate()
      team_id = Ash.UUID.generate()
      task = task!(candidates: [{:user, user_id}, {:team, team_id}])

      loaded = Ash.load!(task, :candidates)

      assert loaded.candidates |> Enum.map(&{&1.principal_type, &1.principal_id}) |> Enum.sort() ==
               Enum.sort([{:user, user_id}, {:team, team_id}])
    end

    test "a process task offers the outcomes its BPMN step declares" do
      task = process_task!(Ash.UUID.generate())

      assert Ash.load!(task, :outcomes).outcomes == ["approved", "rejected"]
    end

    test "a standalone approval has no declared outcomes to offer" do
      task = task!(candidates: [{:user, Ash.UUID.generate()}])

      assert Ash.load!(task, :outcomes).outcomes == nil
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────────────────────

  # A standalone task with the candidate rows and recorded exclusions the engine would have
  # written for it.
  defp task!(opts) do
    attrs = %{
      node_id: "who_acts_#{System.unique_integer([:positive])}",
      name: "Approve",
      subject_type: "AshBpmn.Test.Subject",
      subject_id: Ash.UUID.generate()
    }

    task =
      case Keyword.get(opts, :excluded, []) do
        [] -> HumanTask.create!(attrs)
        excluded -> HumanTask.create!(Map.put(attrs, :excluded_principal_ids, excluded))
      end

    for {type, id} <- Keyword.fetch!(opts, :candidates) do
      TaskCandidate.create!(%{task_id: task.id, principal_type: type, principal_id: id})
    end

    task
  end

  # The access request's manager approval: candidates are the requester's manager, and the
  # requester is excluded.
  defp process_task!(requester_id) do
    key = "who_acts_process_#{System.unique_integer([:positive])}"

    %{key: key, name: key, xml: File.read!("test/fixtures/access_request.bpmn")}
    |> Definition.create!()
    |> Definition.publish!()

    subject =
      case AshBpmn.Test.Subject.create!(%{
             name: key,
             amount: 0,
             is_privileged: false,
             created_by_id: requester_id
           }) do
        {:ok, subject} -> subject
        subject -> subject
      end

    {:ok, instance} =
      AshBpmn.start_instance(AshBpmn.Test.Domain, process: key, subject: subject)

    HumanTask
    |> Ash.Query.filter(instance_id == ^instance.id and node_id == "ManagerApproval")
    |> Ash.read_one!()
  end

  defp awaiting(actor) do
    HumanTask
    |> Ash.Query.for_read(:awaiting_actor, %{}, actor: actor)
    |> Ash.read!()
    |> ids()
  end

  defp reload(task), do: Ash.get!(HumanTask, task.id)

  defp events(task, kind) do
    ProcessEvent
    |> Ash.Query.filter(task_id == ^task.id and kind == ^kind)
    |> Ash.read!()
  end

  defp ids(tasks), do: Enum.map(tasks, & &1.id)
end
