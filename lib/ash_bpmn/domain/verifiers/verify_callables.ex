# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.Domain.Verifiers.VerifyCallables do
  @moduledoc """
  Verifies a domain's `callables` block at compile time.

  Three checks, per TRD §3:

    * the resource belongs to the declaring domain,
    * the action exists on the resource,
    * the name is unique within the domain.

  The action check only runs once the resource is known to be registered — an
  unregistered resource may not be compiled yet, and introspecting it would be a
  compiler crash rather than a DSL error.
  """

  use Spark.Dsl.Verifier

  alias AshBpmn.Domain.Callable
  alias Spark.Dsl.Verifier
  alias Spark.Error.DslError

  @impl true
  def verify(dsl) do
    domain = Verifier.get_persisted(dsl, :module)
    callables = Verifier.get_entities(dsl, [:callables])

    resources =
      dsl
      |> Verifier.get_entities([:resources])
      |> Enum.map(& &1.resource)

    errors =
      Enum.flat_map(callables, &errors_for(&1, resources, domain)) ++
        duplicate_name_errors(callables, domain)

    case errors do
      [] -> :ok
      errors -> {:error, errors}
    end
  end

  defp errors_for(%Callable{} = callable, resources, domain) do
    []
    |> add_membership_error(callable, resources, domain)
    |> add_action_error(callable, resources, domain)
  end

  defp add_membership_error(errors, callable, resources, domain) do
    if callable.resource in resources do
      errors
    else
      [
        dsl_error(domain, callable, """
        #{inspect(callable.resource)} is not in this domain's `resources` block, so the \
        callable cannot be verified. Add the resource to the domain, or declare the \
        callable on the domain that owns it.\
        """)
        | errors
      ]
    end
  end

  defp add_action_error(errors, callable, resources, domain) do
    if callable.resource in resources do
      case Code.ensure_compiled(callable.resource) do
        {:module, _module} ->
          add_missing_action_error(errors, callable, domain)

        {:error, reason} ->
          [
            dsl_error(domain, callable, """
            could not load #{inspect(callable.resource)} (#{inspect(reason)}), so its \
            action could not be verified.\
            """)
            | errors
          ]
      end
    else
      errors
    end
  end

  defp add_missing_action_error(errors, callable, domain) do
    if Ash.Resource.Info.action(callable.resource, callable.action) do
      errors
    else
      [
        dsl_error(domain, callable, """
        #{inspect(callable.resource)} has no action :#{callable.action}. Check the \
        spelling, or add the action.\
        """)
        | errors
      ]
    end
  end

  defp duplicate_name_errors(callables, domain) do
    callables
    |> Enum.group_by(& &1.name)
    |> Enum.filter(fn {_name, declared} -> length(declared) > 1 end)
    |> Enum.map(fn {_name, declared} ->
      dsl_error(domain, hd(declared), """
      the name is used #{length(declared)} times in this domain. Callable names must be \
      unique within the domain -- a diagram's `"Domain.name"` ref has to resolve to \
      exactly one action.\
      """)
    end)
  end

  defp dsl_error(domain, %Callable{} = callable, message) do
    DslError.exception(
      module: domain,
      path: [:callables, callable.name],
      message: String.trim_trailing(message)
    )
  end
end
