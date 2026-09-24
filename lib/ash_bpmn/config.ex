# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.Config do
  @moduledoc """
  Runtime configuration for the ash_bpmn library.

  Reads from `Application.get_env(:ash_bpmn, ...)`.  Required settings raise
  an instructive error when accessed but unset; optional settings return
  documented defaults.
  """

  @doc "Returns the configured `AshBpmn.AssignmentResolver` module.  Raises if unset."
  @spec assignment_resolver!() :: module()
  def assignment_resolver! do
    case Application.get_env(:ash_bpmn, :assignment_resolver) do
      nil ->
        raise """
        ash_bpmn: :assignment_resolver is not configured.

        Add to your config:

            config :ash_bpmn,
              assignment_resolver: MyApp.Bpmn.Resolver

        The module must implement the `AshBpmn.AssignmentResolver` behaviour.
        """

      mod when is_atom(mod) ->
        mod
    end
  end

  @doc "Returns the configured `AshBpmn.ActionInvoker` module.  Raises if unset."
  @spec action_invoker!() :: module()
  def action_invoker! do
    case Application.get_env(:ash_bpmn, :action_invoker) do
      nil ->
        raise """
        ash_bpmn: :action_invoker is not configured.

        Add to your config:

            config :ash_bpmn,
              action_invoker: MyApp.Bpmn.Invoker

        The module must implement the `AshBpmn.ActionInvoker` behaviour.
        """

      mod when is_atom(mod) ->
        mod
    end
  end

  @doc """
  The configured event source, or `nil`.

  `event_source!/0` raises because the sweep must not start without one. This one exists for
  callers doing bookkeeping *after* a durable state change, where an unconfigured host is a
  reason to do nothing rather than a reason to fail.
  """
  @spec event_source() :: module() | nil
  def event_source, do: Application.get_env(:ash_bpmn, :event_source)

  @doc """
  Returns the configured `AshBpmn.EventSource` module.  Raises if unset.
  """
  @spec event_source!() :: module()
  def event_source! do
    case Application.get_env(:ash_bpmn, :event_source) do
      nil ->
        raise """
        ash_bpmn: :event_source is not configured.

        Add to your config:

            config :ash_bpmn,
              event_source: MyApp.Audit.EventSource

        The module must implement the `AshBpmn.EventSource` behaviour. The event sweep
        refuses to start without one: every coupling to the host's event log lives in the
        adapter, and the engine never sees the log's own types.
        """

      mod when is_atom(mod) ->
        mod
    end
  end

  @doc """
  The configured `AshBpmn.DecisionResolver`, or a raise explaining what to set.

  Unlike the invoker and the assignment resolver, this one is only needed by documents that
  contain a `businessRuleTask` — so it is looked up lazily and, more importantly, checked at
  **publish** time by the compiler. A process with a decision node and no resolver is a compile
  error naming this key, rather than an instance that fails when it first reaches the node.
  """
  @spec decision_resolver!() :: module()
  def decision_resolver! do
    case decision_resolver() do
      nil ->
        raise """
        ash_bpmn: :decision_resolver is not configured, but this process contains a
        businessRuleTask.

        Add to your config:

            config :ash_bpmn,
              decision_resolver: MyApp.Bpmn.Decisions

        The module must implement the `AshBpmn.DecisionResolver` behaviour. `ash_decisions` is
        the intended implementation, but any module answering `decide/3` and `exists?/1` will
        do -- the engine deliberately does not know what a decision is.
        """

      module ->
        module
    end
  end

  @doc "The configured decision resolver, or nil. Use when absence is a legitimate state."
  @spec decision_resolver() :: module() | nil
  def decision_resolver, do: Application.get_env(:ash_bpmn, :decision_resolver)

  @doc """
  The configured `AshBpmn.DefinitionLoader`.

  Defaults to `AshBpmn.DefinitionLoader.Default`, which reads the definition in the instance's
  own scope -- exactly what the engine did before this was configurable. A host only needs to
  set it when an instance's definition can live outside the instance's tenant.
  """
  @spec definition_loader() :: module()
  def definition_loader do
    get(:definition_loader, AshBpmn.DefinitionLoader.Default)
  end

  @doc "Returns the Oban queue name for BPMN jobs (default `:bpmn`)."
  @spec queue() :: atom()
  def queue do
    get(:queue, :bpmn)
  end

  @doc "Returns the max retry attempts for advance jobs (default `5`)."
  @spec max_attempts() :: pos_integer()
  def max_attempts do
    get(:max_attempts, 5)
  end

  @doc """
  Returns the actor the engine acts as, or `nil` to keep the caller's own.

  By default the engine keeps whoever was really acting — the person who
  completed the task, or an `AshBpmn.SystemActor` for background work — and its
  authority to write travels separately, in the private context flag
  `AshBpmn.Checks.AshBpmnInteraction` recognises. That is the right default,
  because it is what lets a host's ownership, provenance and audit derive from
  the person rather than from the engine.

  It stops working in one specific case, and it is worth stating precisely. Ash
  builds one expression over a resource's policies in which a bypass
  short-circuits only the policies declared **after** it. A host base resource
  emits its policy set from `use`, which runs before anything the ash_bpmn
  resource macro adds — so on a based resource, the host's policies come first
  and the engine's bypass never gets the chance to skip them.

  A host in that position has two ways out. Either put the engine's bypass at the
  top of the base's own policy set:

      policies do
        bypass AshBpmn.Checks.AshBpmnInteraction do
          authorize_if always()
        end

        # … the rest of the base's policies
      end

  or, if changing the base is not an option, tell the engine to act as an actor
  the base already admits:

      config :ash_bpmn,
        engine_actor: {MyApp.Platform.SystemActor, :system, []}

  The MFA is evaluated per call. The cost of the second option is the reason it
  is not the default: every engine write is then attributed to that system actor,
  and the human survives only in the columns the engine writes explicitly —
  `started_by_id`, `decided_by_id`, `assignee_id`.
  """
  @spec engine_actor() :: term() | nil
  def engine_actor do
    case Application.get_env(:ash_bpmn, :engine_actor) do
      nil -> nil
      {m, f, a} -> apply(m, f, a)
      actor -> actor
    end
  end

  @doc """
  Returns the Oban testing mode: `nil` (production) or `:inline`.

  When `:inline`, the runtime's Oban shim executes workers synchronously
  instead of enqueueing.
  """
  @spec oban_testing() :: nil | :inline
  def oban_testing do
    Application.get_env(:ash_bpmn, :oban_testing)
  end

  @doc """
  The `Phoenix.PubSub` server token movement is broadcast on, or `nil`.

  `AshBpmn.FlightView` broadcasts on this server every time a token changes
  state, which is what the live process flight view — and any per-instance side
  panel — subscribes to. `nil` (the default) is the documented no-PubSub
  configuration: broadcasts become no-ops and hosts poll
  `AshBpmn.FlightView.token_positions/2` instead, which is exactly what the
  built-in viewer LiveView already does. A configured server that is not
  *running* is treated the same way: a viewer that misses an update can
  re-query, so an unstarted PubSub is a reason to skip, never a crash inside an
  engine write.

      config :ash_bpmn, pubsub_server: MyApp.PubSub
  """
  @spec pubsub_server() :: module() | nil
  def pubsub_server do
    Application.get_env(:ash_bpmn, :pubsub_server)
  end

  # ── Triggers extension ────────────────────────────────────────────────────

  @doc """
  The tenants the trigger sweep fans out to, as a list or `{m, f, a}`.

  A list is used as-is; the MFA is applied per call (the `ash_oban`
  `list_tenants` pattern), so a host whose tenant list lives in its own tables
  plugs its loader in:

      config :ash_bpmn, trigger_tenants: {MyApp.Organizations, :all_tenant_ids, []}

  Default `[]`. Read by `AshBpmn.Triggers.SweepWorker.enqueue_all/0`, which the
  cron fan-out (`AshBpmn.Triggers.CronSweep`) calls every minute — the ordering
  guarantee the cursor relies on holds *within* a tenant, so there is one sweep
  job per tenant and no global sweep.

  A host that prefers to derive the list from its own data (for example "every
  tenant with a published subscription", the reference application's choice)
  does it inside the MFA — the library does not read the host's resources.
  """
  @spec trigger_tenants() :: [term()]
  def trigger_tenants do
    case get(:trigger_tenants, []) do
      {m, f, a} when is_atom(m) and is_atom(f) and is_list(a) -> apply(m, f, a)
      tenants when is_list(tenants) -> tenants
    end
  end

  @doc """
  The dispatch depth past which a trigger refuses to start another process
  (default `5`).

  Subscriptions may not match `ash_bpmn` resources, which closes the direct
  cycle; a cycle through `AshBpmn.Resources.Signal` remains structurally
  possible, and this is the bound that keeps it *bounded* rather than merely
  improbable. A refused dispatch records `:depth_exceeded` and starts nothing.
  """
  @spec trigger_max_depth() :: pos_integer()
  def trigger_max_depth do
    get(:trigger_max_depth, 5)
  end

  @doc """
  The field `AshBpmn.Triggers.Nudge` reads the event's resource from on the
  host's event-log row (default `:resource`).

  A module atom or a string in either spelling is normalized to the short form
  the index is keyed on.
  """
  @spec nudge_resource_field() :: atom()
  def nudge_resource_field do
    get(:nudge_resource_field, :resource)
  end

  @doc """
  The field `AshBpmn.Triggers.Nudge` reads the event's tenant from on the
  host's event-log row (default `:organization_id`).

  The sweep's job args carry the tenant under `"tenant"`, and every trigger
  resource under attribute multitenancy stores it in `organization_id` — but
  the *log* is the host's, so the field name is the host's to correct.
  """
  @spec nudge_tenant_field() :: atom()
  def nudge_tenant_field do
    get(:nudge_tenant_field, :organization_id)
  end

  # Every defaulted read goes through here, and the reason is narrow and real.
  #
  # `Application.get_env/3`'s default does not fire for a key that is *present with a nil
  # value*, and `Application.put_env(key, nil)` makes it present. So a caller that captures
  # configuration before setting it and restores what it captured writes a present nil back --
  # and every later reader gets `nil` where it had every reason to expect the default. It is a
  # test-cleanup idiom rather than an exotic mistake, and a host can write the same nil in a
  # config file just as easily.
  #
  # Found after it did exactly that here: eighteen tests failed in a file about something else
  # entirely, with `nil.read/2`, because one test restored a nil it had captured as unset.
  # Unset and nil mean the same thing to every caller of this module, so they are made to mean
  # the same thing in one place rather than at fifteen call sites that each look correct.
  #
  # The sharper framing, which is the other session's: the question is not whether a read has
  # a default but *where the default is applied*. `get_env(app, key, default)` applies it
  # inside a function that distinguishes unset from present-nil, and fires only for unset.
  # `value || default` applies it at the point of use, where both are falsy and neither needs
  # telling apart. The pattern that looks lazier is the correct one, and this is it with a
  # name.
  defp get(key, default) do
    case Application.get_env(:ash_bpmn, key) do
      nil -> default
      value -> value
    end
  end
end
