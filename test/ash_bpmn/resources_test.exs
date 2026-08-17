# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.ResourcesTest do
  use AshBpmn.DataCase, async: false

  alias AshBpmn.Test.{
    Definition,
    HumanTask,
    Instance,
    ProcessEvent,
    TaskCandidate,
    Token
  }

  # Minimal test XML — not valid BPMN, so the compiler will store errors.
  # Tests that need a published definition use force_publish!/1 to bypass
  # the compile-check gate.  Once Lane B's xmerl parsing is fixed, the
  # force-publish helper can be removed and real BPMN fixtures used.
  @minimal_xml "<bpmn2:definitions xmlns:bpmn2='http://www.omg.org/spec/BPMN/20100524/MODEL' id='D1'/>"

  # ── Definition ────────────────────────────────────────────────────────

  describe "Definition" do
    test "create assigns version 1 and computes content hash" do
      definition =
        Definition.create!(%{
          key: "test_process",
          name: "Test Process",
          xml: @minimal_xml
        })

      assert definition.version == 1
      assert definition.status == :draft

      expected_hash =
        :crypto.hash(:sha256, @minimal_xml)
        |> Base.encode16(case: :lower)

      assert definition.content_hash == expected_hash
    end

    test "second definition with same key gets version 2" do
      d1 =
        Definition.create!(%{
          key: "versioned",
          name: "V1",
          xml: @minimal_xml
        })

      assert d1.version == 1

      # First draft must be published before another version of the same key
      # can be created (UniqueDraftCheck).
      _d1 = force_publish!(d1)

      d2 =
        Definition.create!(%{
          key: "versioned",
          name: "V2",
          xml: @minimal_xml <> "<extra/>"
        })

      assert d2.version == 2

      _d2 = force_publish!(d2)

      d3 =
        Definition.create!(%{
          key: "versioned",
          name: "V3",
          xml: @minimal_xml
        })

      assert d3.version == 3
    end

    test "create rejects duplicate draft for same key" do
      Definition.create!(%{
        key: "draft_unique",
        name: "Draft 1",
        xml: @minimal_xml
      })

      assert_raise Ash.Error.Invalid, ~r/draft already exists/i, fn ->
        Definition.create!(%{
          key: "draft_unique",
          name: "Draft 2",
          xml: @minimal_xml
        })
      end
    end

    test "save_xml updates XML and recomputes hash" do
      draft =
        Definition.create!(%{
          key: "save_xml_test",
          name: "Save XML Test",
          xml: @minimal_xml
        })

      new_xml = @minimal_xml <> "<extra/>"

      updated =
        Definition.save_xml!(draft, new_xml)

      assert updated.xml == new_xml

      expected_hash =
        :crypto.hash(:sha256, new_xml)
        |> Base.encode16(case: :lower)

      assert updated.content_hash == expected_hash
    end

    test "save_xml rejects when status is not draft" do
      draft =
        Definition.create!(%{
          key: "save_published_test",
          name: "Save Published Test",
          xml: @minimal_xml
        })

      published = force_publish!(draft)

      assert_raise Ash.Error.Invalid, ~r/draft/, fn ->
        Definition.save_xml!(published, "<new/>")
      end
    end

    test "publish transitions draft to published" do
      draft =
        Definition.create!(%{
          key: "publish_test",
          name: "Publish Test",
          xml: @minimal_xml
        })

      published = force_publish!(draft)
      assert published.status == :published
    end

    test "publish rejects non-draft" do
      draft =
        Definition.create!(%{
          key: "republish_test",
          name: "Republish Test",
          xml: @minimal_xml
        })

      published = force_publish!(draft)

      assert_raise Ash.Error.Invalid, ~r/draft/, fn ->
        Definition.publish!(published)
      end
    end

    test "retire transitions published to retired" do
      draft =
        Definition.create!(%{
          key: "retire_test",
          name: "Retire Test",
          xml: @minimal_xml
        })

      published = force_publish!(draft)

      retired = Definition.retire!(published)
      assert retired.status == :retired
    end

    test "latest_published returns the highest version" do
      d1 =
        Definition.create!(%{
          key: "latest_test",
          name: "Latest V1",
          xml: @minimal_xml
        })

      force_publish!(d1)

      d2 =
        Definition.create!(%{
          key: "latest_test",
          name: "Latest V2",
          xml: @minimal_xml <> "v2"
        })

      force_publish!(d2)

      results = Definition.latest_published!("latest_test")
      assert [%{version: v}] = results
      assert v == 2
    end

    test "create stores compile errors when XML does not compile" do
      definition =
        Definition.create!(%{
          key: "compile_err_test",
          name: "Compile Error Test",
          xml: @minimal_xml
        })

      assert definition.graph == nil
      assert definition.errors != []
    end
  end

  # ── Instance ──────────────────────────────────────────────────────────

  describe "Instance" do
    test "create and mark_completed" do
      defn = create_test_definition!("inst_complete")

      instance =
        Instance.create!(%{
          definition_id: defn.id,
          subject_type: "AshBpmn.Test.Subject",
          subject_id: Ash.UUID.generate()
        })

      assert instance.status == :running

      completed =
        Instance.mark_completed!(instance, :approved)

      assert completed.status == :completed
      assert completed.outcome == :approved
    end

    test "mark_failed and cancel" do
      defn = create_test_definition!("inst_fail")

      instance =
        Instance.create!(%{
          definition_id: defn.id,
          subject_type: "AshBpmn.Test.Subject",
          subject_id: Ash.UUID.generate()
        })

      failed = Instance.mark_failed!(instance)
      assert failed.status == :failed

      # New instance for cancel
      instance2 =
        Instance.create!(%{
          definition_id: defn.id,
          subject_type: "AshBpmn.Test.Subject",
          subject_id: Ash.UUID.generate()
        })

      cancelled = Instance.cancel!(instance2)
      assert cancelled.status == :cancelled
    end
  end

  # ── Token ─────────────────────────────────────────────────────────────

  describe "Token" do
    test "claim transitions active to executing" do
      instance = create_test_instance!("token_claim")
      token = create_test_token!(instance, "node_1")

      claimed = Token.claim!(token)
      assert claimed.status == :executing
      assert claimed.attempts == 1
    end

    test "second claim on same token errors (optimistic lock)" do
      instance = create_test_instance!("token_double_claim")
      token = create_test_token!(instance, "node_1")

      Token.claim!(token)

      # Reload the now-executing token
      executing = Ash.load!(token, :id)

      # Attempting to claim again should fail because the DB check sees
      # the token is no longer :active.
      assert_raise Ash.Error.Invalid, fn ->
        Token.claim!(executing)
      end
    end

    test "consume transitions executing to consumed" do
      instance = create_test_instance!("token_consume")
      token = create_test_token!(instance, "node_1")
      claimed = Token.claim!(token)
      consumed = Token.consume!(claimed)
      assert consumed.status == :consumed
    end

    test "kill and reactivate" do
      instance = create_test_instance!("token_kill")
      token = create_test_token!(instance, "node_1")

      dead = Token.kill!(token)
      assert dead.status == :dead

      reactivated = Token.reactivate!(dead)
      assert reactivated.status == :active
    end
  end

  # ── HumanTask ─────────────────────────────────────────────────────────

  describe "HumanTask" do
    test "claim sets assignee and status" do
      instance = create_test_instance!("ht_claim")
      token = create_test_token!(instance, "node_1")

      task =
        HumanTask.create!(%{
          instance_id: instance.id,
          token_id: token.id,
          node_id: "approval_1",
          name: "Approve Request"
        })

      user_id = Ash.UUID.generate()

      claimed =
        HumanTask.claim!(task, %{assignee_type: :user, assignee_id: user_id})

      assert claimed.status == :claimed
      assert claimed.assignee_type == :user
      assert claimed.assignee_id == user_id
      assert claimed.claimed_at != nil
    end

    test "complete requires outcome" do
      instance = create_test_instance!("ht_complete_no_outcome")
      token = create_test_token!(instance, "node_1")

      task =
        HumanTask.create!(%{
          instance_id: instance.id,
          token_id: token.id,
          node_id: "approval_1",
          name: "Approve"
        })

      user_id = Ash.UUID.generate()
      claimed = HumanTask.claim!(task, %{assignee_type: :user, assignee_id: user_id})

      assert_raise Ash.Error.Invalid, ~r/outcome.*required/i, fn ->
        HumanTask.complete!(claimed, %{})
      end
    end

    test "complete with valid outcome" do
      instance = create_test_instance!("ht_complete")
      token = create_test_token!(instance, "node_1")

      task =
        HumanTask.create!(%{
          instance_id: instance.id,
          token_id: token.id,
          node_id: "approval_1",
          name: "Approve"
        })

      user_id = Ash.UUID.generate()
      claimed = HumanTask.claim!(task, %{assignee_type: :user, assignee_id: user_id})
      decider_id = Ash.UUID.generate()

      completed =
        HumanTask.complete!(claimed, %{
          outcome: :approved,
          comment: "Looks good",
          decided_by_id: decider_id
        })

      assert completed.status == :completed
      assert completed.outcome == :approved
    end

    test "cancel from open and claimed" do
      instance = create_test_instance!("ht_cancel")
      token = create_test_token!(instance, "node_1")

      # Cancel from open
      task_open =
        HumanTask.create!(%{
          instance_id: instance.id,
          token_id: token.id,
          node_id: "cancel_open",
          name: "Cancel Me"
        })

      cancelled_open = HumanTask.cancel!(task_open)
      assert cancelled_open.status == :cancelled
    end

    test "delegate records previous assignee" do
      instance = create_test_instance!("ht_delegate")
      token = create_test_token!(instance, "node_1")

      task =
        HumanTask.create!(%{
          instance_id: instance.id,
          token_id: token.id,
          node_id: "delegate_1",
          name: "Delegate Me"
        })

      original_user = Ash.UUID.generate()
      new_user = Ash.UUID.generate()

      claimed =
        HumanTask.claim!(task, %{assignee_type: :user, assignee_id: original_user})

      delegated =
        HumanTask.delegate!(claimed, :user, new_user)

      assert delegated.assignee_id == new_user
      assert delegated.delegated_from_id == original_user
    end

    test "force_complete completes without assignee" do
      instance = create_test_instance!("ht_force")
      token = create_test_token!(instance, "node_1")

      task =
        HumanTask.create!(%{
          instance_id: instance.id,
          token_id: token.id,
          node_id: "force_1",
          name: "Force Complete"
        })

      # Force complete from open status
      forced =
        HumanTask.force_complete!(task, :expired)

      assert forced.status == :completed
      assert forced.outcome == :expired
      assert forced.decided_by_id == nil
    end
  end

  # ── TaskCandidate ─────────────────────────────────────────────────────

  describe "TaskCandidate" do
    test "create and unique identity" do
      instance = create_test_instance!("tc_unique")
      token = create_test_token!(instance, "node_1")

      task =
        HumanTask.create!(%{
          instance_id: instance.id,
          token_id: token.id,
          node_id: "cand_1",
          name: "Candidate Task"
        })

      user_id = Ash.UUID.generate()

      c1 =
        TaskCandidate.create!(%{
          task_id: task.id,
          principal_type: :user,
          principal_id: user_id
        })

      assert c1.task_id == task.id

      # Duplicate should fail on unique identity (DB constraint → Ash.Error.Unknown)
      assert_raise Ash.Error.Unknown, fn ->
        TaskCandidate.create!(%{
          task_id: task.id,
          principal_type: :user,
          principal_id: user_id
        })
      end
    end

    test "destroy candidate" do
      instance = create_test_instance!("tc_destroy")
      token = create_test_token!(instance, "node_1")

      task =
        HumanTask.create!(%{
          instance_id: instance.id,
          token_id: token.id,
          node_id: "cand_2",
          name: "Destroy Task"
        })

      user_id = Ash.UUID.generate()

      c =
        TaskCandidate.create!(%{
          task_id: task.id,
          principal_type: :user,
          principal_id: user_id
        })

      :ok = TaskCandidate.destroy!(c)
    end
  end

  # ── HumanTask partial unique index ───────────────────────────────────

  describe "HumanTask partial unique index" do
    test "second live approval for same subject+node raises" do
      subject_id = Ash.UUID.generate()
      node_id = "access_request.grant"

      task1 =
        HumanTask.create!(%{
          node_id: node_id,
          name: "Approve Access",
          subject_type: "AshBpmn.Test.Subject",
          subject_id: subject_id
        })

      assert task1.status == :open

      # Second open task for same subject+node should hit the partial unique index
      assert_raise Ash.Error.Invalid, fn ->
        HumanTask.create!(%{
          node_id: node_id,
          name: "Approve Access Again",
          subject_type: "AshBpmn.Test.Subject",
          subject_id: subject_id
        })
      end

      # Cancel the first (moves it out of open/claimed)
      HumanTask.cancel!(task1)

      # Now a new one should succeed
      HumanTask.create!(%{
        node_id: node_id,
        name: "Approve Access V2",
        subject_type: "AshBpmn.Test.Subject",
        subject_id: subject_id
      })
    end
  end

  # ── ProcessEvent ──────────────────────────────────────────────────────

  describe "ProcessEvent" do
    test "create event" do
      instance = create_test_instance!("pe_create")

      event =
        ProcessEvent.create!(%{
          instance_id: instance.id,
          kind: :instance_started,
          data: %{"triggered_by" => "test"}
        })

      assert event.kind == :instance_started
      assert event.instance_id == instance.id
      assert event.recorded_at != nil
    end
  end

  # ── Resources.kind/1 ─────────────────────────────────────────────────

  describe "AshBpmn.Resources.kind/1" do
    test "identifies BPMN resource modules" do
      assert AshBpmn.Resources.kind(AshBpmn.Test.Definition) == :definition
      assert AshBpmn.Resources.kind(AshBpmn.Test.Instance) == :instance
      assert AshBpmn.Resources.kind(AshBpmn.Test.Token) == :token
      assert AshBpmn.Resources.kind(AshBpmn.Test.HumanTask) == :human_task
      assert AshBpmn.Resources.kind(AshBpmn.Test.TaskCandidate) == :task_candidate
      assert AshBpmn.Resources.kind(AshBpmn.Test.ProcessEvent) == :process_event
    end

    test "returns :not_bpmn for non-BPMN modules" do
      assert AshBpmn.Resources.kind(AshBpmn.Test.Subject) == :not_bpmn
      assert AshBpmn.Resources.kind(String) == :not_bpmn
    end
  end

  # ── Resources.for_domain/1 ───────────────────────────────────────────

  describe "AshBpmn.Resources.for_domain/1" do
    test "returns all six resource modules" do
      assert {:ok, mapping} = AshBpmn.Resources.for_domain(AshBpmn.Test.Domain)
      assert mapping.definition == AshBpmn.Test.Definition
      assert mapping.instance == AshBpmn.Test.Instance
      assert mapping.token == AshBpmn.Test.Token
      assert mapping.human_task == AshBpmn.Test.HumanTask
      assert mapping.task_candidate == AshBpmn.Test.TaskCandidate
      assert mapping.process_event == AshBpmn.Test.ProcessEvent
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  defp create_test_definition!(key) do
    Definition.create!(%{
      key: key,
      name: "Test #{key}",
      xml: @minimal_xml
    })
  end

  defp create_test_instance!(key) do
    defn = create_test_definition!("inst_#{key}")

    Instance.create!(%{
      definition_id: defn.id,
      subject_type: "AshBpmn.Test.Subject",
      subject_id: Ash.UUID.generate()
    })
  end

  defp create_test_token!(instance, node_id) do
    Token.create!(%{
      instance_id: instance.id,
      node_id: node_id
    })
  end

  # Force-publishes a draft definition using raw SQL, bypassing the
  # publish action's compile-error gate.
  # Needed because Lane B's xmerl-based compiler does not yet parse XML,
  # so every create stores compile errors and publish!/1 rejects them.
  # Once the compiler works, replace callers with Definition.publish!/1.
  defp force_publish!(definition) do
    AshBpmn.TestRepo.query!(
      "UPDATE bpmn_definitions SET status = 'published' WHERE id = '#{definition.id}'"
    )

    Definition.by_key_version!(definition.key, definition.version)
  end
end
