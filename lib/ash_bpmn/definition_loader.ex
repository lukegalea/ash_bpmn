# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.DefinitionLoader do
  @moduledoc """
  How the engine loads the definition an instance is pinned to.

  ## Why this is a seam at all

  Everywhere else, "load the row this row points at" needs no explaining. Here it does, and
  the reason is worth stating because it is the one place multitenancy and process reuse pull
  in opposite directions.

  An instance pins `definition_id` for life — that is what makes a published process immutable
  in practice rather than in principle. The engine therefore reads that definition on every
  advance, through the instance's own scope, which for a tenant-scoped install means *the
  instance's tenant*. That is correct whenever the definition and the instance belong to the
  same tenant, which is every single-tenant install and every install where each tenant
  authors its own processes.

  It is wrong the moment a host ships **baseline** processes centrally and lets a tenant run
  them without copying them. The instance is the tenant's; the definition is not. Read through
  the instance's scope, it is simply not there — and the failure is quiet: the viewer renders
  blank, and an advance raises on a nil graph somewhere well downstream of the cause.

  So the load goes through a callback the host may replace:

      config :ash_bpmn, definition_loader: MyApp.Bpmn.Definitions

  The default, `AshBpmn.DefinitionLoader.Default`, does exactly what the engine did before —
  read it in the instance's own scope — so a host that has never heard of this module gets the
  behaviour it already had.

  ## What an implementation must guarantee

  **The definition returned must be the one the instance pinned.** This is a lookup, not a
  resolution: returning "the latest version of that key" instead would silently migrate a
  running instance onto a definition it was never verified against, which is the single thing
  the whole versioning design exists to prevent. Resolution — deciding which definition a
  *new* instance should run — happens once, at `AshBpmn.start_instance/2`, via its
  `:definition` option.
  """

  @doc """
  Loads the definition with `definition_id`, for `instance`.

  The instance is passed as well as the id because a host resolving across tenants needs to
  know whose instance is asking. `scope` is the engine scope the caller was already using.
  """
  @callback load(
              definition_resource :: module(),
              definition_id :: term(),
              instance :: struct(),
              scope :: AshBpmn.Scope.t()
            ) :: {:ok, struct()} | {:error, term()}

  @doc "Loads through the configured loader, or raises with the reason it could not."
  @spec load!(module(), term(), struct(), AshBpmn.Scope.t()) :: struct()
  def load!(definition_resource, definition_id, instance, scope) do
    loader = AshBpmn.Config.definition_loader()

    case loader.load(definition_resource, definition_id, instance, scope) do
      {:ok, definition} ->
        definition

      {:error, reason} ->
        raise """
        ash_bpmn: could not load definition #{inspect(definition_id)} for instance \
        #{inspect(Map.get(instance, :id))}: #{inspect(reason)}

        An instance pins its definition for life, so this is not recoverable by retrying with a
        different one. If the definition lives outside the instance's tenant -- a baseline
        process the host publishes centrally -- configure a loader that can reach it:

            config :ash_bpmn, definition_loader: MyApp.Bpmn.Definitions
        """
    end
  end

  defmodule Default do
    @moduledoc """
    Loads the definition in the instance's own scope.

    What the engine did before the seam existed, and the right answer for every install where
    a tenant's instances run that tenant's own definitions.
    """

    @behaviour AshBpmn.DefinitionLoader

    require Ash.Query

    alias AshBpmn.Scope

    @impl true
    def load(definition_resource, definition_id, _instance, scope) do
      definition_resource
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(id == ^definition_id)
      |> Ash.read_one(Scope.engine(scope))
      |> case do
        {:ok, nil} -> {:error, :not_found}
        {:ok, definition} -> {:ok, definition}
        {:error, reason} -> {:error, reason}
      end
    end
  end
end
