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
          # `:errored` is not a flavour of `:failed`, and the distinction is load-bearing --
          # the same call made for `:waiting` on tokens.
          #
          # `:failed` means the engine gave up: retries exhausted, an action that would not
          # complete, something to page somebody about. `:errored` means the process worked
          # exactly as designed and the design says this ends badly -- a declined application,
          # a withdrawn request. Merging them would put "the integration is down" and "the
          # answer was no" in one bucket, and would let `retry_instance/2` offer to retry a
          # decision.
          constraints one_of: [:running, :completed, :failed, :errored, :cancelled]
          default :running
          allow_nil? false
          public? true
        end

        attribute :started_by_id, :uuid do
          public? true
        end

        # A string, not an atom. The value comes from `ash:taskConfig outcome="..."` on an end
        # event -- modeller-authored text in tenant-supplied XML -- and the only two ways to
        # get an atom out of that are `String.to_atom/1`, which is an unbounded atom table fed
        # by anyone who can edit a diagram, and `String.to_existing_atom/1`, which succeeds or
        # fails depending on what happens to have been loaded. Neither is a reasonable thing to
        # hang a process outcome on.
        #
        # This was an `:atom`, and no fixture ever set an outcome, so every definition that
        # declared one would have failed at the moment it completed. Storage is unchanged --
        # Ash writes both to text.
        # How many trigger hops produced this instance. Zero means a person or a host call
        # started it; higher means a chain of subscriptions did.
        #
        # It lives on the instance because the bound has to survive the gap between one event
        # and the next. `Dispatch` carries depth for the hop it records, which is enough while
        # every hop is subscription-to-instance -- but a process that *throws* a signal starts
        # a new event with nothing linking it to the one that started the process, so the
        # count restarted at zero on every lap and the bound never fired. That is precisely
        # the cycle signals make possible.
        # A child instance started by a call activity names the token waiting for it. Direct
        # references rather than a correlation key, because there is nothing to correlate: the
        # parent knows exactly which child it started, and a child has exactly one parent.
        #
        # `parent_token_id` is what the completion wakes. `parent_instance_id` is for the
        # people reading afterwards -- "what did this run as part of?" is the question, and
        # answering it by walking tokens would be needless.
        attribute :parent_instance_id, :uuid do
          public? true
        end

        attribute :parent_token_id, :uuid do
          public? true
        end

        attribute :trigger_depth, :integer do
          default 0
          allow_nil? false
          public? true
        end

        attribute :outcome, :string do
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

        # The instance half of `AshBpmn.StateExport`'s read. `parent_token_ids` is what makes
        # a call activity's child reachable: the parent token is parked with no signature and
        # no correlation key on purpose, so the only link between the two is the child's own
        # `parent_token_id`, and an export that could not follow it would report a token
        # waiting for nothing.
        read :in_flight do
          description "Instances by status, optionally by definition key or by the token that started them."

          argument :statuses, {:array, :atom} do
            constraints items: [one_of: [:running, :completed, :failed, :errored, :cancelled]]
            default [:running]

            description "Which statuses to include. The default is the one that is still in flight."
          end

          argument :definition_key, :string do
            description "Restrict to instances of this process key."
          end

          argument :instance_ids, {:array, :uuid} do
            description "Restrict to these instances."
          end

          argument :parent_token_ids, {:array, :uuid} do
            description "Restrict to children started by these tokens."
          end

          prepare AshBpmn.Resources.Instance.FilterInFlight
        end

        create :create do
          accept [
            :subject_type,
            :subject_id,
            :correlation_id,
            :started_by_id,
            :outcome,
            :definition_id,
            :trigger_depth,
            :parent_instance_id,
            :parent_token_id
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

        update :mark_errored do
          accept [:outcome]
          require_atomic? false

          validate AshBpmn.Resources.Instance.StatusIsRunning
          change set_attribute(:status, :errored)
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
        define :in_flight, action: :in_flight
        define :mark_completed, action: :mark_completed, args: [:outcome]
        define :mark_errored, action: :mark_errored
        define :mark_failed, action: :mark_failed
        define :cancel, action: :cancel
      end
    end
  end
end

defmodule AshBpmn.Resources.Instance.FilterInFlight do
  @moduledoc """
  Narrows an instance read by status and, optionally, by definition key, id or parent token.

  Every argument except `:statuses` is optional and nil means "do not narrow on this", which
  is why each is applied by its own clause rather than folded into one expression: a filter
  built from a nil is a filter that quietly matches nothing.
  """
  use Ash.Resource.Preparation

  require Ash.Query

  @impl true
  def prepare(query, _opts, _context) do
    query
    |> Ash.Query.filter(status in ^(Ash.Query.get_argument(query, :statuses) || []))
    |> filter_key(Ash.Query.get_argument(query, :definition_key))
    |> filter_ids(Ash.Query.get_argument(query, :instance_ids))
    |> filter_parent_tokens(Ash.Query.get_argument(query, :parent_token_ids))
    |> Ash.Query.load(:definition)
    |> Ash.Query.sort(inserted_at: :asc, id: :asc)
  end

  defp filter_key(query, nil), do: query
  defp filter_key(query, key), do: Ash.Query.filter(query, definition.key == ^key)

  defp filter_ids(query, nil), do: query
  defp filter_ids(query, ids) when is_list(ids), do: Ash.Query.filter(query, id in ^ids)

  defp filter_parent_tokens(query, nil), do: query

  defp filter_parent_tokens(query, ids) when is_list(ids),
    do: Ash.Query.filter(query, parent_token_id in ^ids)
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
