# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.Subject do
  @moduledoc """
  Loads the host record a process or a work item is about.

  The subject is the one read the engine makes outside its own resources — the requisition
  being approved, the account being closed — and it happens in three places: the advance
  worker before it dispatches a node, the facade when a standalone approval completes, and the
  facade again when routing after a human task. All three had their own copy; this is the one
  they now share, so the `authorize?: false` that `AshBpmn.Scope.subject/2` carries is written
  down once and can be found by grep.

  ## Why the module name is resolved with `to_existing_atom`

  `Instance.subject_type` is a module name stored as a string. Resolving it with
  `String.to_atom/1` creates an atom that is never collected, from a value read out of the
  database — and while the engine is the only writer of that column today, a table is a wider
  attack surface than a code path. A module that can be loaded has already been an atom, so
  `to_existing_atom/1` resolves every legitimate value and refuses the rest.
  """

  require Ash.Query

  alias AshBpmn.Scope

  @doc """
  Loads the subject named by a record carrying `subject_type` and `subject_id`.

  Returns `nil` when there is no subject, when the module no longer exists, or when the read
  fails. A nil subject is a normal state — a process need not be about anything — and it makes
  every FEEL path over it `null`, which is the correct answer rather than a crash.
  """
  @spec load(map(), Scope.t(), [String.t()]) :: struct() | nil
  def load(record, scope, paths \\ [])

  def load(%{subject_type: type, subject_id: id}, %Scope{} = scope, paths)
      when is_binary(type) and not is_nil(id) do
    case resolve(type) do
      {:ok, mod} ->
        mod
        |> Ash.Query.for_read(:read)
        |> Ash.Query.filter(id == ^id)
        |> load_paths(paths)
        |> Ash.read_one!(Scope.subject(scope))

      :error ->
        nil
    end
  rescue
    _ -> nil
  end

  def load(_record, _scope, _paths), do: nil

  @doc """
  Turns the dotted paths a node declares into an Ash load statement.

  `["customer", "invoices.total"]` becomes `[customer: [], invoices: [:total]]`. Public so the
  compiler's shape and the runtime's reading of it are pinned by one test rather than two
  descriptions that can drift.
  """
  @spec load_statement([String.t()]) :: keyword()
  def load_statement(paths) do
    paths
    |> Enum.map(&String.split(&1, "."))
    |> Enum.reduce(%{}, fn segments, acc -> merge_path(acc, segments) end)
    |> to_load()
  end

  defp merge_path(acc, [leaf]), do: Map.put_new(acc, leaf, %{})

  defp merge_path(acc, [head | rest]) do
    Map.update(acc, head, merge_path(%{}, rest), &merge_path(&1, rest))
  end

  defp to_load(map) do
    Enum.map(map, fn {key, nested} ->
      # `to_existing_atom`, for the reason the module name is resolved that way: these come
      # from tenant-authored XML, and `String.to_atom/1` on one is an atom table fed by
      # anyone who can edit a diagram. A field that exists is already an atom.
      {String.to_existing_atom(key), to_load(nested)}
    end)
  end

  defp load_paths(query, []), do: query

  defp load_paths(query, paths) do
    Ash.Query.load(query, load_statement(paths))
  rescue
    # A path naming something the resource does not have is a modelling error, and it must not
    # take down the advance: FEEL already answers a missing path as null, which is the same
    # answer the node would get if the load had simply not been declared. The alternative --
    # crashing every instance of a published definition -- is worse than an unanswered
    # condition, and the condition being unanswerable is visible either way.
    _ -> query
  end

  defp resolve(type) do
    {:ok, String.to_existing_atom(type)}
  rescue
    ArgumentError -> :error
  end
end
