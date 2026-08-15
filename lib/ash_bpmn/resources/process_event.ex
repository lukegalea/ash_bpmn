# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.Resources.ProcessEvent do
  @moduledoc """
  Resource macro for BPMN process events (audit log).

  Records process facts that `ash_events` cannot express.  Events are
  append-only (create + read, no update or destroy).

  ## Required options

    * `:domain` — the Ash domain.
    * `:repo` — the `AshPostgres.Repo`.
    * `:instance` — the Instance resource module.

  ## Optional options

    * `:table` — (default `"bpmn_process_events"`).
    * `:tenant?` — (default `false`).
  """

  defmacro __using__(opts) do
    domain = Keyword.fetch!(opts, :domain)
    repo = Keyword.fetch!(opts, :repo)
    instance = Keyword.fetch!(opts, :instance)
    table = Keyword.get(opts, :table, "bpmn_process_events")
    tenant? = Keyword.get(opts, :tenant?, false)

    quote do
      use Ash.Resource,
        domain: unquote(domain),
        data_layer: AshPostgres.DataLayer,
        authorizers: [Ash.Policy.Authorizer]

      @ash_bpmn_kind :process_event

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

        attribute :instance_id, :uuid do
          allow_nil? false
          public? true
        end

        attribute :token_id, :uuid do
          public? true
        end

        attribute :node_id, :string do
          public? true
        end

        attribute :kind, :atom do
          allow_nil? false
          constraints one_of: [
            :instance_started,
            :node_entered,
            :node_completed,
            :gateway_branch_taken,
            :task_created,
            :task_claimed,
            :task_delegated,
            :task_completed,
            :task_cancelled,
            :task_expired,
            :timer_fired,
            :timer_cancelled,
            :action_invoked,
            :action_failed,
            :instance_completed,
            :instance_failed,
            :instance_cancelled,
            :sweep_recovered
          ]
          public? true
        end

        attribute :data, :map do
          default %{}
          public? true
        end

        attribute :recorded_at, :utc_datetime_usec do
          allow_nil? false
          default &DateTime.utc_now/0
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
          destination_attribute :id
        end
      end

      actions do
        read :read do
          primary? true
        end

        create :create do
          accept [:instance_id, :token_id, :node_id, :kind, :data]
        end
      end

      code_interface do
        define :create, action: :create
      end
    end
  end
end
