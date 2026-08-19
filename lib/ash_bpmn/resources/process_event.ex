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
    instance = Keyword.fetch!(opts, :instance)
    table = Keyword.get(opts, :table, "bpmn_process_events")
    tenant? = AshBpmn.Resources.Base.own_tenancy?(opts)
    policies? = Keyword.get(opts, :policies?, true)

    base_use = AshBpmn.Resources.Base.use_call(opts)

    quote do
      unquote(base_use)

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

        # Nullable: standalone approvals (RequireApproval) have no instance.
        attribute :instance_id, :uuid do
          public? true
        end

        attribute :token_id, :uuid do
          public? true
        end

        attribute :node_id, :string do
          public? true
        end

        # Standalone approvals have no instance or node, so the task is the only
        # thing their events can be correlated by.
        attribute :task_id, :uuid do
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
                        :sweep_recovered,
                        # A gateway condition that produced FEEL's `null` rather than a
                        # boolean -- a path the subject does not have, a type mismatch. The
                        # branch is not taken, exactly as for `false`, but the two are recorded
                        # differently because a condition that is silently never true looks
                        # identical to one that is legitimately false and is a far worse bug.
                        :condition_null,
                        # A business rule task invoked a decision. Carries the decision
                        # reference, its version and which rules fired -- never the decision's
                        # full output, which belongs to the decision layer's own record.
                        :decision_evaluated
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
          # Nullable: standalone approvals have no instance to correlate.
          allow_nil? true
          public? true
          destination_attribute :id
        end
      end

      actions do
        read :read do
          primary? true
        end

        create :create do
          accept [:instance_id, :token_id, :node_id, :task_id, :kind, :data]
        end
      end

      code_interface do
        define :create, action: :create
      end
    end
  end
end
