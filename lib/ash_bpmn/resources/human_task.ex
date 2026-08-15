# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.Resources.HumanTask do
  @moduledoc """
  Resource macro for BPMN human work items (user tasks and standalone approvals).

  ## Required options

    * `:domain` — the Ash domain.
    * `:repo` — the `AshPostgres.Repo`.
    * `:instance` — the Instance resource module.
    * `:token` — the Token resource module.

  ## Optional options

    * `:table` — (default `"bpmn_human_tasks"`).
    * `:tenant?` — (default `false`).
  """

  defmacro __using__(opts) do
    domain = Keyword.fetch!(opts, :domain)
    repo = Keyword.fetch!(opts, :repo)
    instance = Keyword.fetch!(opts, :instance)
    token = Keyword.fetch!(opts, :token)
    table = Keyword.get(opts, :table, "bpmn_human_tasks")
    tenant? = Keyword.get(opts, :tenant?, false)
    do_block = Keyword.get(opts, :do, nil)

    quote do
      use Ash.Resource,
        domain: unquote(domain),
        data_layer: AshPostgres.DataLayer,
        authorizers: [Ash.Policy.Authorizer]

      @ash_bpmn_kind :human_task

      def ash_bpmn_kind, do: @ash_bpmn_kind

      postgres do
        table unquote(table)
        repo unquote(repo)

        custom_indexes do
          index [:subject_type, :subject_id, :node_id],
            unique: true,
            where: "status IN ('open','claimed')"
        end
      end

      if unquote(tenant?) do
        multitenancy do
          strategy :attribute
          attribute :organization_id
          global? true
        end
      end

      attributes do
        uuid_primary_key :id

        attribute :node_id, :string do
          allow_nil? false
          public? true
        end

        attribute :name, :string do
          allow_nil? false
          public? true
        end

        attribute :status, :atom do
          constraints one_of: [:open, :claimed, :completed, :cancelled]
          default :open
          allow_nil? false
          public? true
        end

        attribute :assignee_type, :atom do
          constraints one_of: [:user, :team]
          public? true
        end

        attribute :assignee_id, :uuid do
          public? true
        end

        attribute :claimed_at, :utc_datetime_usec do
          public? true
        end

        attribute :due_at, :utc_datetime_usec do
          public? true
        end

        attribute :outcome, :atom do
          public? true
        end

        attribute :decided_by_id, :uuid do
          public? true
        end

        attribute :delegated_from_id, :uuid do
          public? true
        end

        attribute :timer_job_ids, {:array, :integer} do
          default []
          public? true
        end

        attribute :comment, :string do
          public? true
        end

        attribute :on_complete, :map do
          default %{}
          public? true
        end

        attribute :subject_type, :string do
          public? true
        end

        attribute :subject_id, :uuid do
          public? true
        end

        if unquote(tenant?) do
          attribute :organization_id, :uuid do
            allow_nil? false
            public? true
            writable? false
          end
        end

        timestamps()
      end

      relationships do
        belongs_to :instance, unquote(instance) do
          public? true
        end

        belongs_to :token, unquote(token) do
          public? true
        end
      end

      actions do
        read :read do
          primary? true
        end

        create :create do
          accept [
            :instance_id,
            :token_id,
            :node_id,
            :name,
            :status,
            :assignee_type,
            :assignee_id,
            :due_at,
            :on_complete,
            :subject_type,
            :subject_id
          ]
        end

        update :claim do
          accept [:assignee_type, :assignee_id]

          filter expr(status == :open)
          change set_attribute(:status, :claimed)
          change set_attribute(:claimed_at, &DateTime.utc_now/0)
        end

        update :complete do
          accept [:outcome, :comment, :decided_by_id]

          filter expr(status == :claimed)
          validate AshBpmn.Resources.HumanTask.RequireOutcome
          change set_attribute(:status, :completed)
        end

        update :cancel do
          accept []

          filter expr(status in [:open, :claimed])
          change set_attribute(:status, :cancelled)
        end

        update :delegate do
          accept [:assignee_type, :assignee_id]
          require_atomic? false

          filter expr(status == :claimed)
          change AshBpmn.Resources.HumanTask.RecordDelegatedFrom
        end

        update :attach_timers do
          accept [:timer_job_ids]
        end

        update :force_complete do
          accept [:outcome]

          filter expr(status in [:open, :claimed])
          change set_attribute(:status, :completed)
          change set_attribute(:decided_by_id, nil)
        end
      end

      code_interface do
        define :create!, action: :create
        define :claim!, action: :claim
        define :complete!, action: :complete
        define :cancel!, action: :cancel
        define :delegate!, action: :delegate, args: [:assignee_type, :assignee_id]
        define :force_complete!, action: :force_complete, args: [:outcome]
        define :attach_timers!, action: :attach_timers, args: [:timer_job_ids]
      end

      unquote(do_block)
    end
  end
end

defmodule AshBpmn.Resources.HumanTask.RequireOutcome do
  @moduledoc false
  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    outcome = Ash.Changeset.get_attribute(changeset, :outcome)

    if is_nil(outcome) do
      {:error, field: :outcome, message: "outcome is required to complete a task"}
    else
      :ok
    end
  end
end

defmodule AshBpmn.Resources.HumanTask.RecordDelegatedFrom do
  @moduledoc false
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    current_assignee_id =
      case changeset.data do
        nil -> nil
        data -> Map.get(data, :assignee_id)
      end

    Ash.Changeset.change_attribute(changeset, :delegated_from_id, current_assignee_id)
  end
end
