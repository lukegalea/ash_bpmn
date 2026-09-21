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

        custom_indexes do
          # Declared here rather than only in a migration because a host instantiating this
          # resource gets its schema from `mix ash.codegen`, and an index that exists only in
          # ash_bpmn's own test migrations would reach nobody's production database.
          #
          # Partial, on purpose: the correlator asks "which tokens are parked waiting for
          # something like this?" once per matching event. Over the full table that is a scan
          # of every token ever created, nearly all of them consumed; restricted to
          # `status = 'waiting'` it is proportional to the tokens actually parked.
          #
          # Under attribute multitenancy AshPostgres prepends `organization_id` to the key
          # list, so the tenant copy comes out tenant-leading without being written twice.
          index [:subscription_signature, :instance_id],
            where: "status = 'waiting'",
            name: "#{unquote(table)}_waiting_index"
        end
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

        # `:waiting` is not a flavour of `:executing`, and the distinction is load-bearing.
        #
        # A token at a catch node is *parked*: no job is queued for it, nothing will advance it
        # until an event arrives, and that is a correct steady state it may sit in for months.
        # An `:executing` token is mid-flight and its job is either running or lost. Collapsing
        # the two -- which is what parking as `:executing` did -- makes "stuck" and "waiting"
        # indistinguishable, which is why `Runtime.SweepWorker` recovers only `:active` tokens
        # and silently abandons both.
        attribute :status, :atom do
          constraints one_of: [:active, :executing, :waiting, :consumed, :dead]
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

        # Routing signals promoted by a business rule task, and read by the gateways after it
        # as `routing.<name>` in FEEL.
        #
        # This is the one place a token carries anything beyond node ids and status, and the
        # exception is deliberately narrow. Usage rule 5 says tokens carry routing, not
        # business data, and a free-form map on the token is exactly how that rule gets eroded
        # -- so the interpreter enforces the shape rather than the documentation asking for it:
        # scalars only, short names, short values, and few of them. A decision's full output
        # never lands here; it goes to the host's own record and to a process event.
        attribute :routing, :map do
          default %{}
          public? true
        end

        # ── The waiting state ────────────────────────────────────────────────
        #
        # Routing data, not business data: usage rule 5's boundary explicitly includes
        # correlation keys. A parked token records *what it is listening for*, never what the
        # subject said.

        attribute :parked_at, :utc_datetime_usec do
          public? true
          description "When this token began waiting. Diagnostics, and the age of a stuck wait."
        end

        # Frozen at park, on purpose. The key is computed once from the subject as it was when
        # the token arrived, so a subject edited while the token waits cannot silently change
        # what the token is listening for -- which would be a correlation that works or fails
        # depending on when you look.
        attribute :correlation_key, :string do
          public? true
          description "The value an arriving event's key must equal. Computed once, at park."
        end

        # A coarse hash of (kind, resource, action) the correlator filters on before it
        # evaluates anything. Waiting tokens are not indexed in ETS the way subscriptions are
        # -- they are queried per matching event -- so this plus a partial index on
        # `status = :waiting` is what keeps that query bounded by the number of *waiting*
        # tokens rather than by the number of tokens.
        attribute :subscription_signature, :string do
          public? true

          description "Coarse match key the correlator queries on. Not a substitute for the guard."
        end

        attribute :lookback_until, :utc_datetime_usec do
          public? true

          description """
          Watermark for a subscription declaring `lookback`: events at or after this instant are
          eligible to wake this token even though they arrived before it parked. Nil means
          BPMN-strict -- an event that arrived first is missed, which is the default.
          """
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

        # The read behind `AshBpmn.StateExport`, and the only supported way to ask "what is
        # still in flight?" without writing the status list out by hand at each call site --
        # which is how `:waiting` came to be omitted from the sweep's recovery set in the
        # first place. An action owns the definition of "in flight" so there is one.
        read :in_flight do
          description "Live tokens -- active, executing or waiting -- with their instance and definition."

          argument :statuses, {:array, :atom} do
            constraints items: [one_of: [:active, :executing, :waiting, :consumed, :dead]]
            default [:active, :executing, :waiting]

            description "Which statuses count as in flight. The default is every live one."
          end

          argument :instance_ids, {:array, :uuid} do
            description "Restrict to these instances. Nil means every instance."
          end

          prepare AshBpmn.Resources.Token.FilterInFlight
        end

        create :create do
          accept [
            :node_id,
            :status,
            :parent_token_id,
            :fork_id,
            :attempts,
            :instance_id,
            :routing
          ]
        end

        # Promotion is its own action rather than part of `:consume`, because it happens on a
        # token that is still executing and because the audit log records action names:
        # "promote_routing" says what happened where a generic `:update` would not.
        update :promote_routing do
          accept [:routing]
        end

        update :claim do
          accept []
          require_atomic? false

          validate AshBpmn.Resources.Token.StatusIsActive
          change AshBpmn.Resources.Token.EnsureActiveInDb
          change set_attribute(:status, :executing)
          change AshBpmn.Resources.Token.IncrementAttempts
        end

        # Parking is a transition out of `:executing`, like consuming is -- the token has been
        # claimed and processed, and the outcome is "wait" rather than "move on". Guarded for
        # the same reason every other transition is: `changeset.data.status` is the *current*
        # status, and reading it through `get_attribute/2` would return the value this action is
        # about to write and make the guard trivially self-satisfying.
        update :park do
          accept [:correlation_key, :subscription_signature, :lookback_until]
          require_atomic? false

          validate AshBpmn.Resources.Token.StatusIsExecuting
          change set_attribute(:status, :waiting)
          change set_attribute(:parked_at, &DateTime.utc_now/0)
        end

        # The wake. A *distinct* action from `:claim` so an advance worker can never race a
        # normal claim into a parked token: `:claim` admits only `:active`, this admits only
        # `:waiting`, and the two cannot be confused for one another at the call site or in the
        # audit log. First delivery wins; a redelivery of the same event finds the token no
        # longer `:waiting` and loses, which is what makes catch delivery redelivery-safe
        # without a lock.
        update :claim_waiting do
          accept []
          require_atomic? false

          validate AshBpmn.Resources.Token.StatusIsWaiting
          change AshBpmn.Resources.Token.EnsureWaitingInDb
          change set_attribute(:status, :executing)
          change AshBpmn.Resources.Token.ClearWaitingFields
          change AshBpmn.Resources.Token.IncrementAttempts
        end

        update :consume do
          accept []
          require_atomic? false

          validate AshBpmn.Resources.Token.StatusIsExecutingOrWaiting
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
          change AshBpmn.Resources.Token.ClearWaitingFields
        end
      end

      code_interface do
        define :create, action: :create
        define :in_flight, action: :in_flight
        define :claim, action: :claim
        define :park, action: :park
        define :claim_waiting, action: :claim_waiting
        define :consume, action: :consume
        define :kill, action: :kill
        define :reactivate, action: :reactivate
        define :promote_routing, action: :promote_routing
      end
    end
  end
end

defmodule AshBpmn.Resources.Token.FilterInFlight do
  @moduledoc """
  Narrows a token read to the live tokens, with the instance and definition already loaded.

  The load is part of the action rather than left to the caller because every consumer of
  this read needs the same three things — the token, the instance it belongs to and the
  definition the instance pinned — and a caller who forgets the load gets `%Ash.NotLoaded{}`
  where an export expects a definition key. Loading the definition's `graph` is the point:
  the node a token is sitting on only means something against the graph that was published
  with it.

  The sort is not decoration. An export is digested, and a digest over a list whose order
  comes from whatever the planner felt like is a digest that changes for no reason.
  """
  use Ash.Resource.Preparation

  require Ash.Query

  @impl true
  def prepare(query, _opts, _context) do
    statuses = Ash.Query.get_argument(query, :statuses) || []
    instance_ids = Ash.Query.get_argument(query, :instance_ids)

    query
    |> Ash.Query.filter(status in ^statuses)
    |> filter_instances(instance_ids)
    |> AshBpmn.Scope.engine_load(instance: [:definition])
    |> Ash.Query.sort(instance_id: :asc, inserted_at: :asc, id: :asc)
  end

  defp filter_instances(query, nil), do: query

  defp filter_instances(query, ids) when is_list(ids) do
    Ash.Query.filter(query, instance_id in ^ids)
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

defmodule AshBpmn.Resources.Token.StatusIsWaiting do
  @moduledoc false
  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    if changeset.data.status == :waiting do
      :ok
    else
      {:error, field: :status, message: "token must be waiting to be woken by an event"}
    end
  end
end

defmodule AshBpmn.Resources.Token.StatusIsExecutingOrWaiting do
  @moduledoc false
  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    # Waiting is consumable because a parked token is a live branch, and live branches get
    # pruned: an interrupting boundary event kills the activity it is attached to, a
    # terminate end event ends every branch, and a cancelled instance ends all of them. A
    # parked token that could only leave via its own event would make all three impossible.
    if changeset.data.status in [:executing, :waiting] do
      :ok
    else
      {:error, field: :status, message: "token must be executing or waiting to consume"}
    end
  end
end

defmodule AshBpmn.Resources.Token.ClearWaitingFields do
  @moduledoc """
  Blanks the parked-token columns when a token stops waiting.

  Applied on the transitions back into a *running* state -- waking and reactivating -- and
  deliberately not on the terminal ones. A consumed token that still says it waited for
  `invoice-42` is history, and its status says plainly that the wait is over; a token that is
  `:executing` while still advertising a correlation key is a claim about the present that is
  no longer true, and the next person to query the table will believe it.

  What the token waited for, and what woke it, belong in the process event log. The token
  carries routing, not history -- the same line drawn for promoted signals.
  """
  use Ash.Resource.Change

  @fields [:parked_at, :correlation_key, :subscription_signature, :lookback_until]

  @impl true
  def change(changeset, _opts, _context) do
    Enum.reduce(@fields, changeset, &Ash.Changeset.force_change_attribute(&2, &1, nil))
  end

  @impl true
  def atomic(_changeset, _opts, _context) do
    {:atomic, Map.new(@fields, &{&1, nil})}
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

defmodule AshBpmn.Resources.Token.EnsureStatusInDb do
  @moduledoc """
  Before-action check that re-reads the row to guarantee single-winner semantics.

  The validation on `changeset.data` is not enough on its own: `changeset.data` is whatever
  the caller loaded, which may be arbitrarily stale. Two workers can both hold a token they
  read as `:active`, both pass the validation, and both claim it. This closes that window by
  reading the row again inside the action's transaction.

  Takes the required status as an option so claiming an `:active` token and waking a
  `:waiting` one share one implementation -- they are the same check over a different value,
  and keeping them as one module means a fix to the race reaches both.
  """
  use Ash.Resource.Change

  @impl true
  def init(opts) do
    case opts[:status] do
      status when is_atom(status) and not is_nil(status) -> {:ok, opts}
      other -> {:error, "status must be an atom, got: #{inspect(other)}"}
    end
  end

  @impl true
  def change(changeset, opts, _context) do
    required = opts[:status]

    Ash.Changeset.before_action(changeset, fn changeset ->
      pk = Map.get(changeset.data, :id)

      if is_nil(pk) do
        changeset
      else
        scope = AshBpmn.Scope.from_changeset(changeset)

        # Deliberately narrow. The earlier version rescued everything, so a bad tenant, a
        # policy forbid or a connection failure all presented as "could not verify token
        # status" -- three quite different problems wearing one message. Ash's own errors are
        # let through as themselves; only a genuinely absent or moved-on row is a race.
        current =
          changeset.resource
          |> Ash.Query.for_read(:read)
          |> Ash.Query.filter(id == ^pk)
          |> Ash.read_one!(AshBpmn.Scope.engine(scope))

        if current && current.status == required do
          changeset
        else
          Ash.Changeset.add_error(changeset,
            field: :status,
            message:
              "token is no longer #{required} (concurrent modification); found " <>
                inspect(current && current.status)
          )
        end
      end
    end)
  end
end

defmodule AshBpmn.Resources.Token.EnsureActiveInDb do
  @moduledoc false
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, context) do
    AshBpmn.Resources.Token.EnsureStatusInDb.change(changeset, [status: :active], context)
  end
end

defmodule AshBpmn.Resources.Token.EnsureWaitingInDb do
  @moduledoc false
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, context) do
    AshBpmn.Resources.Token.EnsureStatusInDb.change(changeset, [status: :waiting], context)
  end
end
