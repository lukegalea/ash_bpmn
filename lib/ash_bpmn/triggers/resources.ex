# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.Triggers.Resources do
  @moduledoc """
  Resolves the trigger resources (`Subscription`, `Cursor`, `Dispatch`) and the
  BPMN domain they live in.

  The triggers extension's resource kinds are **optional** in a domain mapping
  (`AshBpmn.Resources.for_domain/1` demands only the core six), so the sweep
  cannot use `AshBpmn.Runtime.DomainResolver.resolve!/0`'s fallback — it picks
  the first domain with all six *core* resources, which may have none of the
  trigger three. This module scans the same configured domain list for the
  first domain that has all three trigger kinds installed, and treats finding
  none as the configuration error it is.

  The sweep's job args may carry `"domain"` (the same convention every other
  engine job follows, because a job outlives the process that enqueued it and
  cannot be allowed to guess between two configured domains). An explicit
  domain wins; `nil` falls back to the scan.
  """

  @doc """
  Returns `{domain, resource_mapping}` for a domain with the trigger resources
  installed.

  Accepts a module, its name as a string (job args are JSON), or `nil` to scan
  the configured domains for the first that qualifies.
  """
  @spec resolve!(module() | String.t() | nil) :: {module(), map()}
  def resolve!(domain)

  def resolve!(nil) do
    case Enum.find_value(domains_with_triggers(), fn {domain, mapping} ->
           {domain, mapping}
         end) do
      nil ->
        raise """
        ash_bpmn: no configured domain has the trigger resources installed.

        Add `AshBpmn.Resources.Subscription`, `AshBpmn.Resources.Cursor` and
        `AshBpmn.Resources.Dispatch` to your BPMN domain, and the domain to:

            config :ash_bpmn, ash_domains: [MyApp.Bpmn]

        The event sweep cannot run without them.
        """

      result ->
        result
    end
  end

  def resolve!(domain) when is_binary(domain) do
    resolve!(existing_module!(domain))
  end

  def resolve!(domain) when is_atom(domain) do
    case AshBpmn.Resources.for_domain(domain) do
      {:ok, mapping} ->
        missing =
          for kind <- AshBpmn.Resources.trigger_kinds(),
              is_nil(Map.fetch!(mapping, kind)),
              do: kind

        case missing do
          [] ->
            {domain, mapping}

          missing ->
            raise ArgumentError,
                  "ash_bpmn: #{inspect(domain)} has no trigger resources for " <>
                    "#{inspect(missing)}"
        end

      {:error, :missing_resources, missing} ->
        raise ArgumentError,
              "ash_bpmn: #{inspect(domain)} is missing #{inspect(missing)}"
    end
  end

  defp domains_with_triggers do
    Enum.flat_map(AshBpmn.Runtime.DomainResolver.domains(), fn domain ->
      case AshBpmn.Resources.for_domain(domain) do
        {:ok, mapping} ->
          installed? =
            Enum.all?(AshBpmn.Resources.trigger_kinds(), fn kind ->
              not is_nil(Map.fetch!(mapping, kind))
            end)

          if installed?, do: [{domain, mapping}], else: []

        {:error, _, _} ->
          []
      end
    end)
  rescue
    _ -> []
  end

  # Job args are JSON, so the domain arrives as a string. `to_existing_atom`
  # rather than `to_atom`: the module is compiled into the release running this
  # job, and if it is not — a stale job naming a domain that has since been
  # deleted — that should fail loudly rather than leak an atom.
  defp existing_module!(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError ->
      reraise ArgumentError.exception("ash_bpmn: no such domain #{inspect(name)}"),
              __STACKTRACE__
  end
end
