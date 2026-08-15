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
  """

  defmacro __using__(opts) do
    domain = Keyword.fetch!(opts, :domain)
    repo = Keyword.fetch!(opts, :repo)
    definition = Keyword.fetch!(opts, :definition)
    table = Keyword.get(opts, :table, "bpmn_instances")
    tenant? = Keyword.get(opts, :tenant?, false)
    do_block = Keyword.get(opts, :do, nil)

    quote do
      use Ash.Resource,
        domain: unquote(domain),
        data_layer: AshPostgres.DataLayer,
        authorizers: [Ash.Policy.Authorizer]

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

          validate attribute_equals(:status, :running) do
            message "can only complete a running instance"
          end

          change set_attribute(:status, :completed)
        end

        update :mark_failed do
          accept []

          validate attribute_equals(:status, :running) do
            message "can only fail a running instance"
          end

          change set_attribute(:status, :failed)
        end

        update :cancel do
          accept []

          validate attribute_equals(:status, :running) do
            message "can only cancel a running instance"
          end

          change set_attribute(:status, :cancelled)
        end
      end

      code_interface do
        define :create!, action: :create
        define :mark_completed!, action: :mark_completed, args: [:outcome]
        define :mark_failed!, action: :mark_failed
        define :cancel!, action: :cancel
      end

      unquote(do_block)
    end
  end
end
