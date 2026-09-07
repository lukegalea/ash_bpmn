# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.Resources.Cursor do
  @moduledoc """
  Resource macro for the event sweep's cursor — how far the dispatcher has read
  into one tenant's event chain (TRD §4.2).

  One row per tenant, holding the highest event `sequence` that has been
  dispatched. Within a tenant, sequence order is commit order — a guarantee the
  configured `AshBpmn.EventSource` declares per chain via `order_guarantee/1`,
  not one this resource assumes — so a high-water mark cannot skip an event.

  ## Options

    * `:domain` — **required**.  The Ash domain this resource belongs to.
    * `:repo` — **required**.  The `AshPostgres.Repo` for this resource.
    * `:table` — table name (default `"bpmn_cursors"`).
    * `:tenant?` — set `true` to add `organization_id` multitenancy (default
      `false`). The one-row-per-tenant identity is enforced by the database
      rather than by the sweeper remembering.
    * `:base` — the module to `use` in place of `Ash.Resource`. See
      `AshBpmn.Resources.Base`.
    * `:base_opts` — options passed to `:base` verbatim, with `:domain` filled
      in. Ignored unless `:base` is set.
    * `:policies?` — emit the engine bypass policy (default `true`). See
      `AshBpmn.Checks.AshBpmnInteraction`.

  ## On a host base resource

  A cursor is bookkeeping, not a record a person owns. A host whose base
  resource supports it should opt the cursor out of ownership, lifecycle and
  audit — on the reference application that is
  `base_opts: [ownership: :none, lifecycle?: false, audit?: false]` (or your
  base's own spelling of those choices). The reasoning, so the options are not
  just cargo-culted:

    * **Not audited.** A cursor changes once per sweep and says nothing an
      auditor wants that `Dispatch` does not say better — and two logs
      describing the same fact will eventually disagree.
    * **No lifecycle.** There is no draft cursor to approve and no cursor to
      retire; the row exists the first time a tenant's chain is read and never
      means anything else.

  ## `lag_seconds` is a calculation, not a column

  A stalled dispatcher should be a detected condition rather than a support
  ticket. This is what a health check reads; it is calculated rather than
  stored because a stored staleness would itself go stale.
  """

  defmacro __using__(opts) do
    repo = Keyword.fetch!(opts, :repo)
    table = Keyword.get(opts, :table, "bpmn_cursors")
    tenant? = AshBpmn.Resources.Base.own_tenancy?(opts)
    policies? = Keyword.get(opts, :policies?, true)

    base_use = AshBpmn.Resources.Base.use_call(opts)

    quote do
      unquote(base_use)

      @ash_bpmn_kind :cursor

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

        attribute :last_sequence, :integer do
          default 0
          allow_nil? false
          public? true
          description "The highest event sequence dispatched for this tenant."
        end

        attribute :last_dispatched_at, :utc_datetime_usec do
          public? true
          description "When the sweep last advanced this cursor. Nil until the first advance."
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

      calculations do
        calculate :lag_seconds, :integer, AshBpmn.Resources.Cursor.LagSeconds do
          public? true

          description "Seconds since this tenant's cursor last advanced. Nil before the first advance."
        end
      end

      if unquote(tenant?) do
        identities do
          # One cursor per tenant, enforced by the database rather than by the
          # sweeper remembering. `all_tenants? true` with `organization_id`
          # listed explicitly, rather than an empty key list scoped per tenant:
          # an identity defaults to `all_tenants? false`, which makes
          # AshPostgres *prepend* the multitenancy attribute to the index -- so
          # the tenant-scoped form would want no keys at all, which the DSL
          # rejects. Saying it the other way round gives exactly the same index
          # and is the only spelling the DSL accepts.
          identity :one_per_tenant, [:organization_id] do
            all_tenants? true
          end
        end
      end

      actions do
        read :read do
          primary? true
        end

        if unquote(tenant?) do
          create :create do
            # The sweep's entry point: create the tenant's cursor at the
            # current high-water mark, or hand back the one that is already
            # there. An upsert because "ensure it exists" is the operation,
            # and because a cursor created at zero would walk the whole
            # history and start a process for every matching event that ever
            # happened -- the caller stamps `last_sequence` with where the
            # chain stands now.
            accept [:last_sequence, :last_dispatched_at]
            upsert? true
            upsert_identity :one_per_tenant
          end
        else
          create :create do
            accept [:last_sequence, :last_dispatched_at]
          end
        end

        update :advance do
          accept [:last_sequence]
          require_atomic? false

          # A wall-clock stamp cannot be expressed atomically; this is the
          # same waiver the sweep's other writes carry. The function form (as
          # the reference application's cursor uses) rather than `expr(now())`,
          # which does not survive being written inside a resource macro.
          change set_attribute(:last_dispatched_at, &DateTime.utc_now/0)
        end
      end

      code_interface do
        define :create, action: :create
        define :advance, action: :advance, args: [:last_sequence]
      end
    end
  end
end

defmodule AshBpmn.Resources.Cursor.LagSeconds do
  @moduledoc """
  Seconds since this cursor last advanced, computed at read time.

  A stored staleness would itself go stale, so this is a calculation rather
  than a column -- and an Elixir calculation rather than an Ash expression,
  deliberately: the expression vocabulary (`date_diff`) is not something this
  package's Ash version can build inside a resource macro, and what a health
  check needs is a value, not a predicate the data layer can push down.
  """

  use Ash.Resource.Calculation

  @impl true
  def load(_query, _opts, _context), do: []

  @impl true
  def calculate(records, _opts, _context) do
    now = DateTime.utc_now()

    Enum.map(records, fn record ->
      case record.last_dispatched_at do
        nil -> nil
        advanced_at -> DateTime.diff(now, advanced_at, :second)
      end
    end)
  end
end
