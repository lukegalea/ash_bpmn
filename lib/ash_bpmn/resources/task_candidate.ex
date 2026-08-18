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
    * `:base` — the module to `use` in place of `Ash.Resource`, so the generated
      resource inherits a host application's base resource (ownership, audit,
      soft delete, tenancy, the policy set). See `AshBpmn.Resources.Base`.
    * `:base_opts` — options passed to `:base` verbatim, with `:domain` filled
      in. Ignored unless `:base` is set.
    * `:policies?` — emit the engine bypass policy (default `true`). Setting it
      to `false` hands the host the entire policy set, including whatever the
      engine needs to function. See `AshBpmn.Checks.AshBpmnInteraction`.
  """

  defmacro __using__(opts) do
    repo = Keyword.fetch!(opts, :repo)
    task = Keyword.fetch!(opts, :task)
    table = Keyword.get(opts, :table, "bpmn_task_candidates")
    tenant? = AshBpmn.Resources.Base.own_tenancy?(opts)
    policies? = Keyword.get(opts, :policies?, true)

    base_use = AshBpmn.Resources.Base.use_call(opts)

    quote do
      unquote(base_use)

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

      # The engine's own writes. Without this the resource has an authorizer and
      # -- unless the host adds policies -- no way to satisfy it, which is why
      # every internal call used to pass `authorize?: false`. See
      # `AshBpmn.Checks.AshBpmnInteraction` for what this replaces and what it
      # deliberately does not claim to be.
      if unquote(policies?) do
        policies do
          bypass AshBpmn.Checks.AshBpmnInteraction do
            authorize_if always()
          end
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
