# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.Test.Resolver do
  @moduledoc """
  Test double for `AshBpmn.AssignmentResolver`.

  Reads the one normalized spec shape both callers produce: `manager_of` a
  subject field resolves to that principal's synthetic manager, and an exclusion
  resolves to the named subject field itself.
  """

  @doc """
  Resolves candidate principals from assignment specs.

  Callback: `candidates(specs :: [map()], ctx :: map()) ::
              {:ok, [%{type: :user | :team, id: Ash.UUID.t()}]} | {:error, term()}`
  """
  def candidates(specs, ctx) do
    record(:candidates, specs)
    subject = Map.get(ctx, :subject)

    result =
      Enum.flat_map(specs, fn spec ->
        resolve_spec(spec, subject)
      end)

    {:ok, result}
  end

  @doc """
  Resolves excluded principal ids from specs.

  Callback: `exclusions(specs :: [map()], ctx :: map()) ::
              {:ok, [Ash.UUID.t()]} | {:error, term()}`
  """
  def exclusions(specs, ctx) do
    record(:exclusions, specs)
    subject = Map.get(ctx, :subject)

    ids =
      Enum.flat_map(specs, fn
        %{"who" => path} -> List.wrap(subject_field(subject, path))
        _ -> []
      end)

    {:ok, ids}
  end

  @doc "The specs the last `candidates/2` call received."
  @spec last_candidate_specs() :: [map()]
  def last_candidate_specs, do: Process.get({__MODULE__, :candidates}, [])

  @doc "The specs the last `exclusions/2` call received."
  @spec last_exclusion_specs() :: [map()]
  def last_exclusion_specs, do: Process.get({__MODULE__, :exclusions}, [])

  # The engine calls the resolver from the caller's process in inline mode, so
  # the process dictionary is enough to let a test see what it was handed.
  defp record(kind, specs), do: Process.put({__MODULE__, kind}, specs)

  @doc """
  The synthetic manager of a principal.

  Derived from the principal id rather than stored, so it is stable across
  calls and — crucially — *different* from the principal itself. A double where
  `manager_of(x) == x` cannot tell a working maker-checker exclusion from a
  broken one: both produce an empty candidate list.
  """
  @spec manager_of(Ash.UUID.t()) :: Ash.UUID.t()
  def manager_of(principal_id) do
    <<a::binary-size(8), b::binary-size(4), c::binary-size(4), d::binary-size(4),
      e::binary-size(12)>> =
      :crypto.hash(:md5, "manager_of:" <> principal_id) |> Base.encode16(case: :lower)

    Enum.join([a, b, c, d, e], "-")
  end

  # Both callers normalize to this one shape before reaching a resolver.
  defp resolve_spec(%{"kind" => "manager_of", "of" => path}, subject) do
    manager_for(path, subject)
  end

  defp resolve_spec(_spec, _subject) do
    []
  end

  defp manager_for(path, subject) do
    case subject_field(subject, path) do
      nil -> []
      id -> [%{type: :user, id: manager_of(id)}]
    end
  end

  defp subject_field(nil, _path), do: nil

  defp subject_field(subject, path) do
    field =
      path
      |> to_string()
      |> String.replace_prefix("subject.", "")
      |> String.to_existing_atom()

    Map.get(subject, field)
  end
end
