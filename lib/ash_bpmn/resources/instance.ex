# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.Resources.Instance do
  @moduledoc """
  Resource macro for BPMN process instances.

  Pins one definition version for the lifetime of the process.

  ## Required options

    * `:domain` — the Ash domain.
    * `:repo` — the `AshPostgres.Repo`.
    * `:definition` — the Definition resource module (for the `belongs_to`).

  ## Optional options

    * `:table` — (default `"bpmn_instances"`).
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
    definition = Keyword.fetch!(opts, :definition)
    table = Keyword.get(opts, :table, "bpmn_instances")
    tenant? = AshBpmn.Resources.Base.own_tenancy?(opts)
    policies? = Keyword.get(opts, :policies?, true)

    base_use = AshBpmn.Resources.Base.use_call(opts)

    quote do
      unquote(base_use)

      @ash_bpmn_kind :instance

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

        attribute :subject_type, :string do
          allow_nil? false
          public? true
        end

        attribute :subject_id, :uuid do
          allow_nil? false
          public? true
        end

        attribute :correlation_id, :string do
          public? true
        end

        attribute :status, :atom do
          constraints one_of: [:running, :completed, :failed, :cancelled]
          default :running
          allow_nil? false
          public? true
        end

        attribute :started_by_id, :uuid do
          public? true
        end

        attribute :outcome, :atom do
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
        belongs_to :definition, unquote(definition) do
          allow_nil? false
          public? true
        end
      end

      actions do
        read :read do
          primary? true
        end

        create :create do
          accept [
            :subject_type,
            :subject_id,
            :correlation_id,
            :started_by_id,
            :outcome,
            :definition_id
          ]
        end

        update :mark_completed do
          accept [:outcome]
          require_atomic? false

          validate AshBpmn.Resources.Instance.StatusIsRunning
          change set_attribute(:status, :completed)
        end

        update :mark_failed do
          accept []
          require_atomic? false

          validate AshBpmn.Resources.Instance.StatusIsRunning
          change set_attribute(:status, :failed)
        end

        update :cancel do
          accept []
          require_atomic? false

          validate AshBpmn.Resources.Instance.StatusIsRunning
          change set_attribute(:status, :cancelled)
        end
      end

      code_interface do
        define :create, action: :create
        define :mark_completed, action: :mark_completed, args: [:outcome]
        define :mark_failed, action: :mark_failed
        define :cancel, action: :cancel
      end
    end
  end
end

defmodule AshBpmn.Resources.Instance.StatusIsRunning do
  @moduledoc false
  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    status = Ash.Changeset.get_attribute(changeset, :status)

    if status == :running do
      :ok
    else
      {:error, field: :status, message: "can only perform this action on a running instance"}
    end
  end
end
