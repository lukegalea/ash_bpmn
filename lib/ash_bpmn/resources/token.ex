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
    table = Keyword.get(opts, :table, "bpmn_tokens")
    tenant? = AshBpmn.Resources.Base.own_tenancy?(opts)
    policies? = Keyword.get(opts, :policies?, true)

    base_use = AshBpmn.Resources.Base.use_call(opts)

    quote do
      unquote(base_use)

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
          require_atomic? false

          validate AshBpmn.Resources.Token.StatusIsActive
          change AshBpmn.Resources.Token.EnsureActiveInDb
          change set_attribute(:status, :executing)
          change AshBpmn.Resources.Token.IncrementAttempts
        end

        update :consume do
          accept []
          require_atomic? false

          validate AshBpmn.Resources.Token.StatusIsExecuting
          change set_attribute(:status, :consumed)
        end

        update :kill do
          accept []
          change set_attribute(:status, :dead)
        end

        update :reactivate do
          accept []
          require_atomic? false

          validate AshBpmn.Resources.Token.StatusIsDeadOrExecuting
          change set_attribute(:status, :active)
        end
      end

      code_interface do
        define :create, action: :create
        define :claim, action: :claim
        define :consume, action: :consume
        define :kill, action: :kill
        define :reactivate, action: :reactivate
      end
    end
  end
end

defmodule AshBpmn.Resources.Token.StatusIsActive do
  @moduledoc false
  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    # The *current* status is on changeset.data. `get_attribute/2` would return
    # the value the action's own `set_attribute` is about to write, which makes
    # a transition guard trivially self-satisfying.
    if changeset.data.status == :active do
      :ok
    else
      {:error, field: :status, message: "token must be active to claim"}
    end
  end
end

defmodule AshBpmn.Resources.Token.StatusIsExecuting do
  @moduledoc false
  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    if changeset.data.status == :executing do
      :ok
    else
      {:error, field: :status, message: "token must be executing to consume"}
    end
  end
end

defmodule AshBpmn.Resources.Token.StatusIsDeadOrExecuting do
  @moduledoc false
  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    if changeset.data.status in [:dead, :executing] do
      :ok
    else
      {:error, field: :status, message: "token must be dead or executing to reactivate"}
    end
  end
end

defmodule AshBpmn.Resources.Token.IncrementAttempts do
  @moduledoc false
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    current = Ash.Changeset.get_attribute(changeset, :attempts) || 0
    Ash.Changeset.change_attribute(changeset, :attempts, current + 1)
  end
end

defmodule AshBpmn.Resources.Token.EnsureActiveInDb do
  @moduledoc """
  Before-action check that reads the actual DB state to guarantee single-winner
  claim semantics.  Prevents stale-data race where two processes both see
  :active and both succeed.  If the record is no longer :active in the DB,
  the claim is rejected with an error.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      pk = Map.get(changeset.data, :id)

      if is_nil(pk) do
        changeset
      else
        scope = AshBpmn.Scope.from_changeset(changeset)

        try do
          current =
            changeset.resource
            |> Ash.Query.for_read(:read)
            |> Ash.Query.filter(id == ^pk)
            |> Ash.read_one!(AshBpmn.Scope.engine(scope))

          if current && current.status == :active do
            changeset
          else
            Ash.Changeset.add_error(changeset,
              field: :status,
              message: "token is no longer active (concurrent modification)"
            )
          end
        rescue
          _ ->
            Ash.Changeset.add_error(changeset,
              field: :status,
              message: "could not verify token status"
            )
        end
      end
    end)
  end
end
