# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.AssignmentResolver do
  @moduledoc """
  Behaviour for resolving task candidates and exclusions.

  The host application implements this to translate opaque candidate specs —
  from a diagram's `ash:taskConfig` or from a `RequireApproval` change — into
  concrete principal ids. The engine passes a context map with `:subject`,
  `:actor`, `:instance`, `:task`, and `:assigns`.

  ## One spec shape

  Both callers hand the resolver the **same** normalized, string-keyed maps, so
  a resolver is written once:

      # candidate spec
      %{"kind" => "manager_of", "of" => "subject.created_by_id"}

      # exclusion spec
      %{"who" => "subject.created_by_id"}

  A diagram produces those directly (`<ash:candidate kind="manager_of"
  of="subject.created_by_id"/>`). `AshBpmn.Changes.RequireApproval` accepts the
  friendlier Elixir forms — `{:manager_of, "subject.created_by_id"}` for a
  candidate, `"subject.created_by_id"` for an exclusion — and normalizes them
  through `normalize_candidate_spec/1` and `normalize_exclusion_spec/1` before
  calling you.

  Normalization converts the *shape* and nothing else. The values stay opaque
  and verbatim: `"manager_of"` means whatever your resolver decides it means,
  and `"of"` is not assumed to be a subject path — `kind="team" of="security"`
  is just as valid. The library refuses to know what a manager is, so it also
  refuses to rewrite the string that names one. Write the same spelling in the
  diagram and in the change options and one resolver clause serves both.

  ## Callbacks

    * `candidates/2` — resolve specs into principal records.
    * `exclusions/2` — resolve exclusion specs into principal ids to remove.
    * `escalate/2` — (optional) handle escalation for a task.
  """

  @typedoc "A candidate clause, as the resolver receives it."
  @type candidate_spec :: %{required(String.t()) => String.t()}

  @typedoc "An exclusion clause, as the resolver receives it."
  @type exclusion_spec :: %{required(String.t()) => String.t()}

  @typedoc "A resolved principal."
  @type principal :: %{type: :user | :team, id: Ash.UUID.t()}

  @doc "Resolves candidate principals from assignment specs."
  @callback candidates(specs :: [candidate_spec()], ctx :: map()) ::
              {:ok, [principal()]} | {:error, term()}

  @doc "Resolves excluded principal ids from exclusion specs."
  @callback exclusions(specs :: [exclusion_spec()], ctx :: map()) ::
              {:ok, [Ash.UUID.t()]} | {:error, term()}

  @doc "Handles escalation for a task (e.g. notify manager's manager)."
  @callback escalate(task :: map(), ctx :: map()) :: :ok | {:ok, map()} | {:error, term()}

  @optional_callbacks escalate: 2

  @doc """
  Normalizes a candidate spec into the string-keyed map resolvers receive.

  Accepts what a host may write in a `RequireApproval` change:

      iex> AshBpmn.AssignmentResolver.normalize_candidate_spec({:manager_of, "subject.created_by_id"})
      %{"kind" => "manager_of", "of" => "subject.created_by_id"}

  and passes an already-normalized spec (what the compiler emits) through
  unchanged.
  """
  @spec normalize_candidate_spec(term()) :: candidate_spec()
  def normalize_candidate_spec(%{"kind" => _} = spec), do: stringify(spec)

  def normalize_candidate_spec(%{kind: kind} = spec) do
    %{"kind" => to_string(kind), "of" => value(Map.get(spec, :of))}
  end

  def normalize_candidate_spec({kind, of}) do
    %{"kind" => to_string(kind), "of" => value(of)}
  end

  def normalize_candidate_spec(kind) when is_atom(kind) or is_binary(kind) do
    %{"kind" => to_string(kind), "of" => ""}
  end

  @doc """
  Normalizes an exclusion spec into the string-keyed map resolvers receive.

      iex> AshBpmn.AssignmentResolver.normalize_exclusion_spec("subject.created_by_id")
      %{"who" => "subject.created_by_id"}
  """
  @spec normalize_exclusion_spec(term()) :: exclusion_spec()
  def normalize_exclusion_spec(%{"who" => _} = spec), do: stringify(spec)
  def normalize_exclusion_spec(%{who: who}), do: %{"who" => value(who)}

  def normalize_exclusion_spec(who) when is_atom(who) or is_binary(who) do
    %{"who" => value(who)}
  end

  # Verbatim, aside from stringifying an atom written for convenience.
  defp value(nil), do: ""
  defp value(v), do: to_string(v)

  defp stringify(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)
end
