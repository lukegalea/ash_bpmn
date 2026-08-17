# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.ApprovalTestSupport do
  @moduledoc """
  Test support for approval tests — defines a minimal domain + resource
  that the RequireApproval change can be attached to.

  This module is registered in config/test.exs under ash_domains.
  """

  defmodule Domain do
    @moduledoc false
    use Ash.Domain

    resources do
      resource AshBpmn.ApprovalTestSupport.ApprovalSubject
    end
  end

  defmodule ApprovalSubject do
    @moduledoc false
    use Ash.Resource,
      domain: AshBpmn.ApprovalTestSupport.Domain,
      data_layer: AshPostgres.DataLayer

    postgres do
      table "bpmn_approval_subjects"
      repo AshBpmn.TestRepo
    end

    attributes do
      uuid_primary_key :id

      attribute :name, :string do
        allow_nil? false
        public? true
      end

      attribute :created_by_id, :uuid do
        public? true
      end

      timestamps()
    end

    actions do
      read :read do
        primary? true
      end

      create :create do
        accept [:name, :created_by_id]

        change {AshBpmn.Changes.RequireApproval,
                key: "test_approval",
                name: "Test Approval",
                outcomes: [:approved, :rejected],
                candidates: [{:manager_of, "subject.created_by_id"}],
                excluding: ["subject.created_by_id"],
                on_complete: %{approved: "handle_approved"},
                due_in: [hours: 48],
                escalate_in: [hours: 24],
                expire_in: [days: 7]}
      end

      create :create_no_approval do
        accept [:name, :created_by_id]
      end

      # Same approval key on the *same* subject, so requesting twice while the
      # first is still open trips the partial unique index — the double-submit
      # guard. A second `create` could never trip it: that is a new subject.
      update :request_change do
        accept [:name]
        require_atomic? false

        change {AshBpmn.Changes.RequireApproval,
                key: "test_change_approval",
                name: "Approve change",
                outcomes: [:approved, :rejected],
                candidates: [{:manager_of, "subject.created_by_id"}],
                excluding: ["subject.created_by_id"]}
      end
    end

    code_interface do
      define :create
      define :create_no_approval
      define :request_change
    end
  end

  @doc "Ensures the test table exists via raw SQL."
  def ensure_table! do
    AshBpmn.TestRepo.query!("""
      CREATE TABLE IF NOT EXISTS bpmn_approval_subjects (
        id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
        name text NOT NULL,
        created_by_id uuid,
        inserted_at timestamp without time zone NOT NULL DEFAULT now(),
        updated_at timestamp without time zone NOT NULL DEFAULT now()
      )
    """)
  end
end
