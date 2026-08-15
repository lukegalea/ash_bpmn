# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.Resources.TaskCandidate do
  @moduledoc """
  Resource macro for materialized task candidates.

  Represents the set of principals eligible to claim a human task.  Candidacy
  is a set (no update action — create or destroy).

  ## Required options

    * `:domain` — the Ash domain.
    * `:repo` — the `AshPostgres.Repo`.
    * `:task` — the HumanTask resource module (for the `belongs_to`).

  ## Optional options

    * `:table` — (default `"bpmn_task_candidates"`).
    * `:tenant?` — (default `false`).
  """

  defmacro __using__(opts) do
    domain = Keyword.fetch!(opts, :domain)
    repo = Keyword.fetch!(opts, :repo)
    task = Keyword.fetch!(opts, :task)
    table = Keyword.get(opts, :table, "bpmn_task_candidates")
    tenant? = Keyword.get(opts, :tenant?, false)

    quote do
      use Ash.Resource,
        domain: unquote(domain),
        data_layer: AshPostgres.DataLayer,
        authorizers: [Ash.Policy.Authorizer]

      @ash_bpmn_kind :task_candidate

      def ash_bpmn_kind, do: @ash_bpmn_kind

      postgres do
        table unquote(table)
        repo unquote(repo)
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

        attribute :principal_type, :atom do
          constraints one_of: [:user, :team]
          allow_nil? false
          public? true
        end

        attribute :principal_id, :uuid do
          allow_nil? false
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

      identities do
        identity :unique_task_principal, [:task_id, :principal_type, :principal_id]
      end

      relationships do
        belongs_to :task, unquote(task) do
          allow_nil? false
          public? true
        end
      end

      actions do
        read :read do
          primary? true
        end

        create :create do
          accept [:task_id, :principal_type, :principal_id]
        end

        destroy :destroy do
          primary? true
        end
      end

      code_interface do
        define :create, action: :create
        define :destroy, action: :destroy
      end
    end
  end
end
