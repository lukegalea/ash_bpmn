# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.Test.Resolver do
  @moduledoc """
  Test double for `AshBpmn.AssignmentResolver`.

  Resolves candidates from specs.  For specs with `"kind" => "manager_of"` and
  `"of" => "subject.created_by_id"`, returns the subject's `created_by_id`
  as a `:user` principal.  Falls back to returning the subject's id as a user.

  Implements the `AshBpmn.AssignmentResolver` callback signatures (without
  the `@behaviour` annotation, which requires Lane C's module to be compiled).
  """

  @doc """
  Resolves candidate principals from assignment specs.

  Callback: `candidates(specs :: [map()], ctx :: map()) ::
              {:ok, [%{type: :user | :team, id: Ash.UUID.t()}]} | {:error, term()}`
  """
  def candidates(specs, ctx) do
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
  def exclusions(_specs, ctx) do
    subject = Map.get(ctx, :subject)

    ids =
      if subject do
        case Map.get(subject, :created_by_id) do
          nil -> []
          id -> [id]
        end
      else
        []
      end

    {:ok, ids}
  end

  defp resolve_spec(%{"kind" => "manager_of", "of" => "subject.created_by_id"}, subject) do
    if subject do
      case Map.get(subject, :created_by_id) do
        nil -> []
        id -> [%{type: :user, id: id}]
      end
    else
      []
    end
  end

  defp resolve_spec(%{"kind" => "manager_of", "of" => _path}, _subject) do
    []
  end

  defp resolve_spec(_spec, _subject) do
    []
  end
end
