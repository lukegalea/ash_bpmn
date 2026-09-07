# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.Resources.Dispatch do
  @moduledoc """
  Resource macro for the dispatch ledger — what the sweep did with one event,
  for one subscription (TRD §4.3).

  Append-only: `create` and `read`, no update, no destroy. Not a convention —
  the macro simply generates no other actions, so there is nothing to call. A
  record of why a process started that can be edited afterwards is not evidence
  of anything. This is the same shape `AshDecisions.Resources.Evaluation` uses,
  for the same reason.

  ## Two jobs, and the second is the valuable one

  The identities make duplicate starts *provably* impossible under a partial
  failure. The cursor already makes them impossible in the ordinary case, but a
  sweep that crashes mid-batch replays it, and the identity here turns the
  replay into a refusal rather than a second process:

    * `:once_per_event` on `(subscription_id, event_id)` — the start/signal
      side.
    * `:once_per_token_event` on `(waiting_token_id, event_id)` — the catch
      side, where the "who" is a waiting token rather than a subscription.

  Both are partial unique indexes, because Postgres treats NULLs as distinct:
  an unqualified unique index would happily dedupe nothing on the side that is
  nil. Together they are both halves of the G-1 guarantee.

  More usefully, a dispatch answers **"why did this process start?"** — the
  question anyone asks first when a process appears that nobody remembers
  requesting. It records the subscription, the event, the decision and the rule
  that fired, and the instance that resulted. `depth` travels the cycle bound
  (G-5): a subscription may legitimately hear `AshBpmn.Resources.Signal` — the
  one exception to the cycle refusal — and `depth` is what bounds the loop that
  path makes possible.

  ## Failures are rows, not exceptions

  A subscription that could not dispatch records `:failed` (or `:skipped`) with
  a `reason`, and the cursor advances past it. That is deliberate: a broken
  subscription must never wedge a tenant's event stream, and a failure that is
  queryable is one somebody can find.

  ## Not audited, by refusal

  Setting `audit?: true` on a dispatch (or any host-base equivalent) is
  **refused** — a dispatch is already the record of an event; auditing it is a
  cycle with extra steps, and two logs describing the same fact will eventually
  disagree.

  ## Options

    * `:domain` — **required**.  The Ash domain this resource belongs to.
    * `:repo` — **required**.  The `AshPostgres.Repo` for this resource.
    * `:subscription` — optional. Supply the Subscription resource module to
      get a `belongs_to :subscription` relationship for loading; the row
      carries `subscription_id` regardless.
    * `:token` — optional. Supply the Token resource module to get a
      `belongs_to :waiting_token` relationship; the row carries
      `waiting_token_id` regardless.
    * `:table` — table name (default `"bpmn_dispatches"`).
    * `:tenant?` — set `true` to add `organization_id` multitenancy (default `false`).
    * `:base` — the module to `use` in place of `Ash.Resource`. See
      `AshBpmn.Resources.Base`.
    * `:base_opts` — options passed to `:base` verbatim, with `:domain` filled
      in. Ignored unless `:base` is set.
    * `:policies?` — emit the engine bypass policy (default `true`). See
      `AshBpmn.Checks.AshBpmnInteraction`.
  """

  defmacro __using__(opts) do
    repo = Keyword.fetch!(opts, :repo)
    subscription = Keyword.get(opts, :subscription)
    token = Keyword.get(opts, :token)
    table = Keyword.get(opts, :table, "bpmn_dispatches")
    tenant? = AshBpmn.Resources.Base.own_tenancy?(opts)
    policies? = Keyword.get(opts, :policies?, true)

    base_use = AshBpmn.Resources.Base.use_call(opts)

    quote do
      unquote(base_use)

      @ash_bpmn_kind :dispatch

      def ash_bpmn_kind, do: @ash_bpmn_kind

      postgres do
        table unquote(table)
        repo unquote(repo)

        custom_indexes do
          # Both sides of G-1, as partial unique indexes: the nil side must not
          # participate, or a unique index would dedupe nothing where Postgres
          # treats NULLs as distinct.
          index [:subscription_id, :event_id],
            unique: true,
            where: "subscription_id IS NOT NULL"

          index [:waiting_token_id, :event_id],
            unique: true,
            where: "waiting_token_id IS NOT NULL"

          # The "what" side, indexed: the sweep and any forensic query locate a
          # dispatch by position in the tenant's chain without a join.
          index [:event_sequence]
        end
      end

      if unquote(tenant?) do
        multitenancy do
          strategy :attribute
          attribute :organization_id
          global? true
        end
      end

      # The engine's own writes. See `AshBpmn.Checks.AshBpmnInteraction` for
      # what this replaces and what it deliberately does not claim to be.
      if unquote(policies?) do
        policies do
          bypass AshBpmn.Checks.AshBpmnInteraction do
            authorize_if always()
          end
        end
      end

      attributes do
        uuid_primary_key :id

        attribute :subscription_id, :uuid do
          public? true
          description "The subscription this dispatch belongs to. Nil for catch delivery."
        end

        attribute :waiting_token_id, :uuid do
          public? true

          description "The waiting token this catch delivery belongs to. Nil for start/signal delivery."
        end

        attribute :event_id, :uuid do
          allow_nil? false
          public? true
          description "The event this dispatch was decided from."
        end

        attribute :event_sequence, :integer do
          allow_nil? false
          public? true

          description "Its position in the tenant's chain, so a dispatch can be located without a join."
        end

        attribute :event_occurred_at, :utc_datetime_usec do
          allow_nil? false
          public? true

          description "When the event happened -- the watermark lookback windows are measured against."
        end

        attribute :kind, :atom do
          constraints one_of: [:start, :catch, :signal]
          allow_nil? false
          public? true
        end

        attribute :status, :atom do
          constraints one_of: [:started, :delivered, :skipped, :failed]
          allow_nil? false
          public? true
        end

        attribute :reason, :atom do
          constraints one_of: [
                        # The guard produced FEEL null -- "this guard did not produce an
                        # answer". Not the same row as a plain false, and deliberately not
                        # folded into it: a guard that is silently never true is the bug
                        # you want to see.
                        :guard_null,
                        :guard_false,
                        :guard_error,
                        :no_rule_fired,
                        :decision_error,
                        :no_definition,
                        :instance_not_waiting,
                        :fan_out_exceeded,
                        :disabled,
                        :already_dispatched,
                        :depth_exceeded
                      ]

          public? true
          description "Why a dispatch was skipped or failed. Nil when it started."
        end

        attribute :process_key, :string do
          public? true

          description "The process this dispatch named, static or decided. Provenance for auditors."
        end

        attribute :instance_id, :uuid do
          public? true
          description "The process instance this started. Nil unless status is :started."
        end

        attribute :decision_key, :string do
          public? true
          description "The decision consulted, when route_kind was :decision."
        end

        attribute :fired_rule, :string do
          public? true
          description "Which rule of the routing decision matched, when the engine can say."
        end

        attribute :correlation_id, :string do
          public? true
          description "Carried from the originating event, so the process joins its cause."
        end

        attribute :depth, :integer do
          default 0
          allow_nil? false
          public? true

          description """
          How many dispatch hops led here. Zero for an event a person caused.

          Subscriptions may hear the Signal resource -- the one exception to the
          cycle refusal -- so a cycle is structurally possible. The direct paths
          are closed at publish time; this bounds the indirect one, so a cycle is
          *bounded* rather than merely improbable.
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

      if unquote(subscription) do
        relationships do
          belongs_to :subscription, unquote(subscription) do
            define_attribute? false
            allow_nil? true
            public? true
          end
        end
      end

      if unquote(token) do
        relationships do
          belongs_to :waiting_token, unquote(token) do
            define_attribute? false
            allow_nil? true
            public? true
          end
        end
      end

      # Create and read. There is deliberately no update and no destroy: see
      # the moduledoc on why a record of why a process started must not be
      # editable.
      actions do
        read :read do
          primary? true
        end

        create :create do
          accept [
            :subscription_id,
            :waiting_token_id,
            :event_id,
            :event_sequence,
            :event_occurred_at,
            :kind,
            :status,
            :reason,
            :process_key,
            :instance_id,
            :decision_key,
            :fired_rule,
            :correlation_id,
            :depth
          ]

          validate AshBpmn.Resources.Dispatch.RequiresTarget
        end
      end

      code_interface do
        define :create, action: :create
      end
    end
  end
end

defmodule AshBpmn.Resources.Dispatch.RequiresTarget do
  @moduledoc """
  Every dispatch names who it was for: a `subscription_id` on the start/signal
  side, or a `waiting_token_id` on the catch side. A row with neither has no
  "who", and a "what" without a "who" is not a dispatch, it is an orphan.
  """

  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    subscription = Ash.Changeset.get_attribute(changeset, :subscription_id)
    token = Ash.Changeset.get_attribute(changeset, :waiting_token_id)

    if is_nil(subscription) and is_nil(token) do
      {:error,
       fields: [:subscription_id, :waiting_token_id],
       message: "a dispatch needs a subscription_id or a waiting_token_id"}
    else
      :ok
    end
  end
end
