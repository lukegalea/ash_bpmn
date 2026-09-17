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

  @doc """
  Handles an escalation, recording that it happened.

  Implemented here on purpose, and its absence was a real bug rather than an omission: while
  this module had no `escalate/2`, every escalation in the suite raised
  `UndefinedFunctionError` inside `TimerWorker`'s clause-level rescue and reported success.
  The test named "escalation timer fires" passed throughout, because all it asserted was that
  the task was still open -- which is exactly what happens when nothing happens.

  `set_escalate_result/1` stages a failure so the unhappy paths are reachable too. A double
  that can only succeed tests only half of a contract whose interesting half is failure.

  Callback: `escalate(task :: map(), ctx :: map()) :: :ok | {:ok, map()} | {:error, term()}`
  """
  def escalate(task, _ctx) do
    Process.put({__MODULE__, :escalations}, escalations() ++ [task.id])

    case Process.get({__MODULE__, :escalate_result}, :ok) do
      {:__raise__, message} -> raise message
      result -> result
    end
  end

  @doc "Stages what `escalate/2` returns. `{:__raise__, msg}` makes it raise."
  def set_escalate_result(result), do: Process.put({__MODULE__, :escalate_result}, result)

  @doc "Task ids `escalate/2` has been called with, in order."
  @spec escalations() :: [Ash.UUID.t()]
  def escalations, do: Process.get({__MODULE__, :escalations}, [])

  @doc "Forgets staged results and recorded escalations."
  def clear_escalations do
    Process.delete({__MODULE__, :escalations})
    Process.delete({__MODULE__, :escalate_result})
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

defmodule AshBpmn.Test.NoEscalateResolver do
  @moduledoc """
  A resolver that implements the required callbacks and declines the optional one.

  It exists so "the host did not implement escalation" is a state the suite can actually
  reach. Before `AshBpmn.Test.Resolver` grew an `escalate/2`, *every* resolver in the suite
  was this one by accident, and nothing noticed.
  """

  defdelegate candidates(specs, ctx), to: AshBpmn.Test.Resolver
  defdelegate exclusions(specs, ctx), to: AshBpmn.Test.Resolver
end
