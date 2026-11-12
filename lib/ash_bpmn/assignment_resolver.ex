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
    * `team_ids/2` — (optional) the teams a person acts for, so a `:team`
      candidate row is matched. See "Team candidates" below.
    * `no_eligible_candidate/2` — (optional) who gets a task when its
      candidates, minus its exclusions, leave nobody. See "A task nobody can
      act on" below.

  ## A task nobody can act on

  A task whose candidates are all excluded is written with no candidate rows,
  and nobody can ever claim or complete it. Without this callback that is what
  happens, silently: the engine cannot tell an empty set the modeller meant
  from one the organization's shape produced (the only administrator granted
  the role a review is about, and excluding the granter leaves nobody).

  A host that implements `no_eligible_candidate/2` is told, at task creation:

      @impl true
      def no_eligible_candidate(_info, ctx),
        do: candidates([%{"kind" => "role", "of" => "Operator"}], ctx)

  `info` carries `:node_id`, `:candidate_specs` and `:exclusion_specs` (as the
  other callbacks receive them), `:candidates` (what `candidates/2` resolved,
  before the exclusions) and `:exclusions` (the excluded ids). Return the
  fallback principals, `{:ok, []}` for none, or `{:error, reason}`.

  The engine subtracts the exclusions from the fallback again, so a fallback
  can widen who may act but never hands the task to someone the diagram
  excluded. It writes the task with what remains and records a
  `:no_eligible_candidate` process event carrying the task id, how many
  candidates there were, the excluded ids, how many fallback principals remain
  and whether the task was escalated, so a host can raise a finding from it in
  the same transaction. A fallback that errors or raises is recorded on that
  event and the task is written with nobody: the escalation failing must not
  stop the task from existing.

  A host that does not implement the callback sees no change.

  ## Team candidates

  A resolver may answer a clause with `%{type: :team, id: team_id}`, and the
  engine writes it as a `:team` candidate row. To match that row when someone
  claims, completes or delegates, or in the `HumanTask` candidacy read, the
  engine has to know which teams the person is in. It asks `team_ids/2`:

      @impl true
      def team_ids(%{id: user_id}, %{tenant: tenant}), do: MyApp.Teams.ids_for(user_id, tenant)

  The first argument is the actor (or, when checking a delegate, the
  `to_principal` map the caller passed). Without the callback the engine reads
  a `:team_ids` list off that map, and anything else counts as no teams.
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

  @doc """
  The team ids a person acts for, matched against `:team` candidate rows.

  `ctx` carries `:tenant`. Never called per row. A claim, completion or
  delegation calls it once. The `HumanTask` candidacy read (`:awaiting_actor`)
  calls it each time Ash builds the read's filter, which is more than once in
  a single read, count or counted page (three times for a read under Ash 3.34),
  and once more for every lane a board counts. Keep it cheap: if it queries
  memberships, work them out once per request and put them on the actor, then
  return them from here.
  """
  @callback team_ids(principal :: map(), ctx :: map()) :: [Ash.UUID.t()]

  @doc """
  Who may act on a task whose candidates, minus its exclusions, left nobody.

  Called once, at task creation, and only when that set is empty. See "A task
  nobody can act on" in the moduledoc for `info` and what the engine does with
  the answer.
  """
  @callback no_eligible_candidate(info :: map(), ctx :: map()) ::
              {:ok, [principal()]} | {:error, term()}

  @optional_callbacks escalate: 2, team_ids: 2, no_eligible_candidate: 2

  @doc """
  The candidates a task is written with, and the `:no_eligible_candidate` event
  data when it had none.

  `eligible` is the candidates minus the exclusions. When it is non-empty, or
  the resolver does not implement `no_eligible_candidate/2`, it is returned
  unchanged with `nil`. Otherwise the resolver's fallback, minus the exclusions,
  is returned with the event data. Both task-creating paths (a diagram's user
  task and `AshBpmn.Changes.RequireApproval`) call this, so they answer an empty
  set the same way.
  """
  @spec settle(module(), [principal()], map(), map()) :: {[principal()], map() | nil}
  def settle(resolver, eligible, info, ctx)

  def settle(_resolver, [_ | _] = eligible, _info, _ctx), do: {eligible, nil}

  def settle(resolver, [], info, ctx) do
    if Code.ensure_loaded?(resolver) and function_exported?(resolver, :no_eligible_candidate, 2) do
      exclusions = info |> Map.get(:exclusions, []) |> Enum.reject(&is_nil/1) |> Enum.uniq()
      {fallback, error} = fallback(resolver, info, ctx)

      # The engine's guarantee, not the host's: an excluded person never comes back in
      # through the fallback, whatever the fallback returned.
      remaining =
        fallback
        |> Enum.reject(fn principal -> principal.id in exclusions end)
        |> Enum.uniq_by(&{&1.type, &1.id})

      data =
        %{
          "candidates" => length(Map.get(info, :candidates, [])),
          "excluded" => exclusions,
          "fallback" => length(remaining),
          "escalated" => remaining != []
        }
        |> then(&if(error, do: Map.put(&1, "error", error), else: &1))

      {remaining, data}
    else
      {[], nil}
    end
  end

  defp fallback(resolver, info, ctx) do
    case resolver.no_eligible_candidate(info, ctx) do
      {:ok, principals} when is_list(principals) ->
        {principals, nil}

      {:error, reason} ->
        {[], inspect(reason, limit: 5)}

      other ->
        {[], "no_eligible_candidate/2 returned an undeclared shape: #{inspect(other, limit: 5)}"}
    end
  rescue
    exception -> {[], Exception.message(exception)}
  end

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
