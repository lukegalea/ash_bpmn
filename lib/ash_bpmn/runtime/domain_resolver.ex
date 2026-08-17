# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.Runtime.DomainResolver do
  @moduledoc """
  Resolves the BPMN resource modules from the configured domains.

  Looks at `config :ash_bpmn, ash_domains: [...]` first, then falls back to the
  application-wide `config :ash, ash_domains: [...]`, and picks the first domain
  that has all six BPMN resource kinds registered.
  """

  @doc "Returns the resource mapping %{definition: mod, instance: mod, ...} or raises."
  @spec resolve!() :: map()
  def resolve! do
    domains =
      case Application.get_env(:ash_bpmn, :ash_domains, []) do
        [] -> Application.get_env(:ash, :ash_domains, [])
        domains -> domains
      end

    result =
      Enum.find_value(domains, fn domain ->
        try do
          case AshBpmn.Resources.for_domain(domain) do
            {:ok, mapping} -> mapping
            {:error, _, _} -> nil
          end
        rescue
          _ -> nil
        end
      end)

    case result do
      nil ->
        raise """
        ash_bpmn: no configured domain has all six BPMN resources.

        Add your BPMN domain to config:

            config :ash_bpmn, ash_domains: [MyApp.Bpmn]
        """

      mapping ->
        mapping
    end
  end
end
