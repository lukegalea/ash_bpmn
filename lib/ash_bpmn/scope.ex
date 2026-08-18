# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.Scope do
  @moduledoc """
  Who is acting, and in which tenant — carried through every engine call.

  Two things had gone missing from the engine's calls into Ash, and they had gone
  missing for the same reason: nothing carried them.

  **The tenant.** `AshBpmn.start_instance/2` accepted a `:tenant` option and threw
  it away, so an instance started for one organization created its tokens, its
  work items and its events outside any tenant at all. The resource macros could
  generate an `organization_id` multitenancy strategy — that part worked — but
  nothing ever set it.

  **The actor.** Every call passed `authorize?: false`, so the question of who was
  acting never reached the resource. Attribution survived only where the engine
  wrote it into a column by hand (`started_by_id`, `decided_by_id`), and a host
  base resource that derives ownership or an audit entry from the actor got
  nothing.

  A scope is the smallest thing that fixes both: an actor and a tenant, resolved
  once at the boundary of a public function and threaded down.

      scope = AshBpmn.Scope.from_opts(opts)
      Ash.read_one!(query, AshBpmn.Scope.engine(scope))

  ## Where a scope comes from

    * `from_opts/1` — a caller's `:actor` and `:tenant`, at a facade entry point.
    * `from_record/2` — a record already in hand. The tenant is read off the
      record's `organization_id`, which is the point of attribute multitenancy:
      the row knows which tenant it is in, so an operation on it does not need to
      be told again.
    * `from_job/1` — an Oban job's args, where the tenant travelled as JSON and
      there is no human, so the actor is an `AshBpmn.SystemActor`.

  ## Why the actor is the human, not the system actor

  `engine/2` sets a private context flag rather than substituting a system actor,
  so the real person stays in `actor:` for the whole call. That matters under a
  host base resource, where ownership, provenance and the audit entry are all
  derived from the actor — completing a task has to be attributable to the person
  who completed it, not to the engine that carried the write. The engine's
  authority to make the write travels separately, in the context flag that
  `AshBpmn.Checks.AshBpmnInteraction` recognises.

  Only work with genuinely nobody behind it — a timer, a sweep, an advance
  running long after the request that triggered it — carries a system actor, and
  it carries a *named* one for the same reason.
  """

  alias AshBpmn.SystemActor

  @type t :: %__MODULE__{actor: term(), tenant: term(), domain: module() | nil}

  defstruct [:actor, :tenant, :domain]

  @doc """
  A scope from a caller's options: `:actor` and `:tenant`, both optional.
  """
  @spec from_opts(keyword()) :: t()
  def from_opts(opts) do
    %__MODULE__{
      actor: Keyword.get(opts, :actor),
      tenant: Keyword.get(opts, :tenant),
      domain: Keyword.get(opts, :domain)
    }
  end

  @doc """
  A scope for an operation on a record already loaded.

  An explicit `:tenant` in `opts` wins; otherwise the tenant is the record's own
  `organization_id`, which is `nil` on a resource that is not tenant-scoped and
  therefore harmless there.
  """
  @spec from_record(map(), keyword()) :: t()
  def from_record(record, opts \\ []) do
    %__MODULE__{
      actor: Keyword.get(opts, :actor),
      tenant: Keyword.get(opts, :tenant) || tenant_of(record),
      domain: Keyword.get(opts, :domain) || domain_of(record)
    }
  end

  @doc """
  A scope for background work, from an Oban job's args.

  The tenant travels in the job payload under `"tenant"` because a job outlives
  the process that enqueued it — there is nothing else for it to be read from by
  the time the worker runs. `name` selects which `AshBpmn.SystemActor` is
  recorded as responsible.
  """
  @spec from_job(map(), SystemActor.name()) :: t()
  def from_job(args, name \\ :engine) when is_map(args) do
    %__MODULE__{
      actor: apply(SystemActor, name, []),
      tenant: args["tenant"],
      domain: args["domain"]
    }
  end

  @doc "A scope with no tenant, acting as the named system actor."
  @spec system(SystemActor.name()) :: t()
  def system(name \\ :engine), do: %__MODULE__{actor: apply(SystemActor, name, [])}

  @doc """
  The options every engine-internal Ash call passes.

  `extra` is appended, so a caller can add `:load`, `:action` and the like:

      Ash.read!(query, AshBpmn.Scope.engine(scope, load: [:instance]))

  `AshBpmn.Config.engine_actor/0` overrides the actor when a host has configured
  one; see there for the case that needs it. Otherwise see
  `AshBpmn.Checks.AshBpmnInteraction` for what the context flag buys and, just as
  importantly, what it does not.
  """
  @spec engine(t(), keyword()) :: keyword()
  def engine(%__MODULE__{} = scope, extra \\ []) do
    [
      actor: AshBpmn.Config.engine_actor() || scope.actor,
      tenant: scope.tenant,
      context: %{private: %{ash_bpmn?: true}}
    ] ++ extra
  end

  @doc """
  A scope from a changeset already in flight.

  For the reads a change or validation makes against its own resource. The
  changeset knows both answers already — it was built with an actor and, if the
  resource is tenant-scoped, a tenant — and taking them from there is what stops
  a uniqueness check from consulting every tenant's rows.
  """
  @spec from_changeset(Ash.Changeset.t()) :: t()
  def from_changeset(%Ash.Changeset{} = changeset) do
    # Deliberately no `:domain`. In `AshBpmn.Changes.RequireApproval` the
    # changeset belongs to the *host's* resource -- the purchase order being
    # approved -- and its domain is not the BPMN domain. The caller sets that
    # from the resolved BPMN resources instead.
    %__MODULE__{
      actor: changeset.context[:private][:actor] || changeset.context[:actor],
      tenant: changeset.tenant
    }
  end

  @doc """
  A scope from a LiveView's assigns.

  The generated surfaces have no authentication of their own — that is the host's
  job, and every Phoenix application already does it. So this reads the two
  assigns a host is overwhelmingly likely to have already set, `:current_user`
  and `:current_tenant`, and takes `nil` for either when it has not.

  Nothing breaks when both are `nil`: the engine bypass is what authorizes these
  reads. What a host gains by assigning them is that its *own* policies, and its
  own tenant scoping, apply to the task list — which is the difference between a
  work queue and a list of every work item in the database.
  """
  @spec from_assigns(map()) :: t()
  def from_assigns(assigns) when is_map(assigns) do
    %__MODULE__{
      actor: Map.get(assigns, :current_user),
      tenant: Map.get(assigns, :current_tenant)
    }
  end

  @doc """
  Options for reading the *subject* — a host resource, not one of ours.

  A process instance points at something in the host application: the purchase
  order being approved, the account being closed. The engine loads it to evaluate
  gateway conditions and to hand to an action invoker, and it is the one read the
  engine makes outside its own resources.

  `engine/2` is no use here. The context flag it sets is recognised by the policy
  the resource macros generate, and a host's own resource has no such policy — so
  an engine scope on a subject read is simply a denied read, silently swallowed
  by the `rescue` around it and surfacing much later as a gateway that took the
  wrong branch.

  So this keeps `authorize?: false`, and says why rather than leaving it looking
  like the ninety that were removed. The actor and tenant still travel, so a host
  that wants to observe them in a preparation can. Making this authorized needs a
  host-supplied way to load a subject — the `:subject_loader` behaviour that does
  not exist yet — not a different option here.
  """
  @spec subject(t(), keyword()) :: keyword()
  def subject(%__MODULE__{} = scope, extra \\ []) do
    [actor: scope.actor, tenant: scope.tenant, authorize?: false] ++ extra
  end

  @doc """
  The tenant as it travels in an Oban job payload.

  Merged into the args map rather than passed alongside it, because Oban args are
  JSON and a keyword list is not.
  """
  @spec to_job_args(t(), map()) :: map()
  def to_job_args(%__MODULE__{} = scope, args) do
    args
    |> put_unless_nil("tenant", scope.tenant)
    |> put_unless_nil("domain", scope.domain && to_string(scope.domain))
  end

  defp put_unless_nil(map, _key, nil), do: map
  defp put_unless_nil(map, key, value), do: Map.put(map, key, value)

  defp tenant_of(record) when is_map(record), do: Map.get(record, :organization_id)
  defp tenant_of(_), do: nil

  defp domain_of(%{__struct__: resource}) do
    Ash.Resource.Info.domain(resource)
  rescue
    _ -> nil
  end

  defp domain_of(_), do: nil
end
