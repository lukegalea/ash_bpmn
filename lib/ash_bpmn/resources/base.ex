# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.Resources.Base do
  @moduledoc """
  Resolves what the six resource macros should `use`.

  By default each generated resource is `use Ash.Resource` with the Postgres
  data layer and the policy authorizer — a self-contained resource that needs no
  host scaffolding. That is the right default for a library, and it is the wrong
  one for an application that has a **base resource**: a module every resource in
  the application goes through so that ownership, provenance, audit, soft delete,
  tenancy and the policy set arrive by inheritance rather than by remembering.

  A work item is exactly the kind of record such an application wants inside that
  net. "Who approved this, on whose behalf, in which tenant, and can I still see
  it after the row is deleted" are questions the host has already answered once,
  and a process engine that answers them a second way answers them differently.

  So each macro takes `:base`:

      defmodule MyApp.Bpmn.HumanTask do
        use AshBpmn.Resources.HumanTask,
          domain: MyApp.Bpmn,
          repo: MyApp.Repo,
          instance: MyApp.Bpmn.Instance,
          token: MyApp.Bpmn.Token,
          base: MyApp.Platform.Resource,
          base_opts: [ownership: :organization_owned, cdm_entity: "Task"]
      end

  `:base_opts` is passed to the base module's `__using__/1` verbatim, with
  `:domain` filled in. Nothing else is assumed about it — this package does not
  know what options your base resource takes.

  ## What the macro stops emitting

  With `:base` set, the macro no longer emits `data_layer:` or `authorizers:`.
  Those are the base's decision, and passing them here would either duplicate or
  silently override it.

  It also stops emitting the `multitenancy` block and the `organization_id`
  attribute, because a base resource that is worth having already owns tenancy —
  emitting a second strategy would conflict with the first. Combining `:base`
  with `tenant?: true` therefore raises at compile time rather than producing a
  resource with two opinions about which column scopes it; put the option in
  `:base_opts` instead, where the base can act on it.
  """

  @doc """
  Returns the AST for the `use` call at the top of a generated resource.

  Raises `ArgumentError` when `:base` is combined with `tenant?: true` — see the
  moduledoc for why those two cannot both be honoured.
  """
  @spec use_call(keyword()) :: Macro.t()
  def use_call(opts) do
    domain = Keyword.fetch!(opts, :domain)

    case Keyword.get(opts, :base) do
      nil ->
        quote do
          use Ash.Resource,
            domain: unquote(domain),
            data_layer: AshPostgres.DataLayer,
            authorizers: [Ash.Policy.Authorizer]
        end

      base ->
        if Keyword.get(opts, :tenant?, false) do
          raise ArgumentError, """
          `:base` and `tenant?: true` cannot be combined.

          A base resource owns multitenancy for every resource that goes through
          it, so ash_bpmn emitting its own `multitenancy` block on top would give
          the resource two strategies. Pass the option to the base instead:

              base: #{Macro.to_string(base)},
              base_opts: [tenant?: true]

          — assuming your base resource takes that option. What `:base_opts`
          means is entirely up to the base module; this package passes it through
          untouched.
          """
        end

        base_opts = Keyword.put_new(Keyword.get(opts, :base_opts, []), :domain, domain)

        quote do
          use unquote(base), unquote(base_opts)
        end
    end
  end

  @doc """
  Whether the macro should emit its own tenancy DSL.

  False whenever a `:base` is set — the base owns tenancy. See `use_call/1`.
  """
  @spec own_tenancy?(keyword()) :: boolean()
  def own_tenancy?(opts) do
    is_nil(Keyword.get(opts, :base)) and Keyword.get(opts, :tenant?, false)
  end
end
