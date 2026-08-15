# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.Resources.Token do
  @moduledoc """
  Resource macro for BPMN execution tokens.

  One row per live branch of a process instance.

  ## Required options

    * `:domain` — the Ash domain.
    * `:repo` — the `AshPostgres.Repo`.
    * `:instance` — the Instance resource module (for the `belongs_to`).

  ## Optional options

    * `:table` — (default `"bpmn_tokens"`).
    * `:tenant?` — (default `false`).
  """

  defmacro __using__(opts) do
    domain = Keyword.fetch!(opts, :domain)
    repo = Keyword.fetch!(opts, :repo)
    instance = Keyword.fetch!(opts, :instance)
    table = Keyword.get(opts, :table, "bpmn_tokens")
    tenant? = Keyword.get(opts, :tenant?, false)
    do_block = Keyword.get(opts, :do, nil)

    quote do
      use Ash.Resource,
        domain: unquote(domain),
        data_layer: AshPostgres.DataLayer,
        authorizers: [Ash.Policy.Authorizer]

      @ash_bpmn_kind :token

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

        attribute :node_id, :string do
          allow_nil? false
          public? true
        end

        attribute :status, :atom do
          constraints one_of: [:active, :executing, :consumed, :dead]
          default :active
          allow_nil? false
          public? true
        end

        attribute :parent_token_id, :uuid do
          public? true
        end

        attribute :fork_id, :uuid do
          public? true
        end

        attribute :attempts, :integer do
          default 0
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
          allow_nil? false
          public? true
        end
      end

      actions do
        read :read do
          primary? true
        end

        create :create do
          accept [:node_id, :status, :parent_token_id, :fork_id, :attempts, :instance_id]
        end

        update :claim do
          accept []

          filter expr(status == :active)
          change set_attribute(:status, :executing)
          change atomic_update(:attempts, expr(attempts + 1))
        end

        update :consume do
          accept []

          filter expr(status == :executing)
          change set_attribute(:status, :consumed)
        end

        update :kill do
          accept []

          change set_attribute(:status, :dead)
        end

        update :reactivate do
          accept []

          filter expr(status in [:dead, :executing])
          change set_attribute(:status, :active)
        end
      end

      code_interface do
        define :create!, action: :create
        define :claim!, action: :claim
        define :consume!, action: :consume
        define :kill!, action: :kill
        define :reactivate!, action: :reactivate
      end

      unquote(do_block)
    end
  end
end
