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
  @spec load(map(), Scope.t()) :: struct() | nil
  def load(%{subject_type: type, subject_id: id}, %Scope{} = scope)
      when is_binary(type) and not is_nil(id) do
    with {:ok, mod} <- resolve(type) do
      mod
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(id == ^id)
      |> Ash.read_one!(Scope.subject(scope))
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  def load(_record, _scope), do: nil

  defp resolve(type) do
    {:ok, String.to_existing_atom(type)}
  rescue
    ArgumentError -> :error
  end
end
