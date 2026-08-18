# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.Runtime.DomainResolver do
  @moduledoc """
  Resolves the BPMN resource modules from the configured domains.

  Looks at `config :ash_bpmn, ash_domains: [...]` first, then falls back to the
  application-wide `config :ash, ash_domains: [...]`, and picks the first domain
  that has all six BPMN resource kinds registered.
  """

  @doc """
  Returns the resource mapping `%{definition: mod, instance: mod, ...}` or raises.

  With a `domain`, that domain is used directly. This matters more than it looks:
  a background job outlives the request that enqueued it, and without being told
  which domain it belongs to it fell back to *the first configured domain with
  all six resources*. In an application with one BPMN domain that is always the
  right answer; in an application with two it is a coin toss that lands the same
  way every time, so the second domain's instances get advanced against the
  first's tables.

  So every job this package enqueues now carries its domain, and workers pass it
  here. `nil` keeps the old search, which is what a host calling
  `AshBpmn.Web.DefaultTaskActions` without a domain still relies on.
  """
  @spec resolve!(module() | String.t() | nil) :: map()
  def resolve!(domain \\ nil)

  def resolve!(nil) do
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

  def resolve!(domain) when is_binary(domain) do
    resolve!(existing_module!(domain))
  end

  def resolve!(domain) when is_atom(domain) do
    case AshBpmn.Resources.for_domain(domain) do
      {:ok, mapping} ->
        mapping

      {:error, :missing_resources, missing} ->
        raise ArgumentError,
              "ash_bpmn: #{inspect(domain)} is missing #{inspect(missing)}"
    end
  end

  # Job args are JSON, so the domain arrives as a string. `to_existing_atom`
  # rather than `to_atom`: the module is compiled into the release running this
  # job, and if it is not -- a stale job naming a domain that has since been
  # deleted -- that should fail loudly rather than leak an atom.
  defp existing_module!(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError ->
      reraise ArgumentError.exception("ash_bpmn: no such domain #{inspect(name)}"),
              __STACKTRACE__
  end
end
