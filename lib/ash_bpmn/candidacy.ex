# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.Candidacy do
  @moduledoc """
  Who may act on a human task.

  `AshBpmn.claim_task/2`, `complete_task/2` and `delegate_task/2` ask this
  module, and so does the generated `HumanTask` candidacy read
  (`:awaiting_actor`). There are two questions:

    * **Candidate.** A `TaskCandidate` row names the person (a `:user` row
      with their id) or one of their teams (a `:team` row with one of the ids
      `c:AshBpmn.AssignmentResolver.team_ids/2` returns), and the person is not
      excluded from the task.
    * **Holder.** The task is `:claimed` and its assignee is the person (a
      `:user` assignee) or one of their teams (a `:team` assignee), and the
      person is not excluded from the task.

  ## Exclusions travel with the task

  Maker-checker subtracts excluded principals from the candidate set before
  the rows are written, and that is still where it happens. Subtracting rows
  is not enough on its own once team rows can be claimed: the requester may
  be a member of a candidate team, and the team's row says nothing about
  them. So a task also records the ids the subtraction removed
  (`excluded_principal_ids`), and a person counts as excluded when their own
  id or any of their team ids is among them. It is the same subtraction,
  recorded once at creation and applied as the candidate set is matched, not
  a deny rule in a policy.
  """

  require Ash.Query
  require Ash.Expr

  alias AshBpmn.{Config, Scope}

  @typedoc "The principals a person acts as: their user id and their team ids."
  @type principals :: %{user_id: Ash.UUID.t() | nil, team_ids: [Ash.UUID.t()]}

  @doc """
  The principals an actor acts as: their id and, through the resolver's
  optional `team_ids/2` (falling back to a `:team_ids` list on the actor),
  their teams. An actor with no id, a system actor among them, acts as nobody.
  """
  @spec for_actor(term(), Scope.t()) :: principals()
  def for_actor(%{id: id} = actor, scope) when not is_nil(id),
    do: %{user_id: id, team_ids: team_ids(actor, scope)}

  def for_actor(_actor, _scope), do: nobody()

  @doc """
  The principals a `%{type: :user | :team, id: id}` principal map acts as, as
  `AshBpmn.delegate_task/2` receives its `:to_principal`. A user is looked up
  as `for_actor/2` looks up an actor; a team is that team alone.
  """
  @spec for_principal(map(), Scope.t()) :: principals()
  def for_principal(%{type: :team, id: id}, _scope) when not is_nil(id),
    do: %{user_id: nil, team_ids: [id]}

  def for_principal(%{type: :user} = principal, scope), do: for_actor(principal, scope)
  def for_principal(_principal, _scope), do: nobody()

  defp nobody, do: %{user_id: nil, team_ids: []}

  @doc "Whether the principals include anyone at all."
  @spec anyone?(principals()) :: boolean()
  def anyone?(%{user_id: nil, team_ids: []}), do: false
  def anyone?(_principals), do: true

  @doc "Every id the principals act as."
  @spec ids(principals()) :: [Ash.UUID.t()]
  def ids(%{user_id: nil, team_ids: team_ids}), do: team_ids
  def ids(%{user_id: user_id, team_ids: team_ids}), do: [user_id | team_ids]

  @doc "Whether the task's recorded exclusions name any of the principals."
  @spec excluded?(map(), principals()) :: boolean()
  def excluded?(task, principals) do
    excluded = Map.get(task, :excluded_principal_ids) || []
    Enum.any?(ids(principals), &(&1 in excluded))
  end

  @doc """
  Whether the principals are candidates for the task: a candidate row names
  them, and the task does not exclude them.

  Reads the task's candidate rows with the engine's authority. Whether someone
  is in a task's candidate set is a fact about the task, not about what the
  person may browse.
  """
  @spec candidate?(map(), map(), principals(), Scope.t()) :: boolean()
  def candidate?(resources, task, principals, scope) do
    anyone?(principals) and not excluded?(task, principals) and
      resources.task_candidate
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(task_id == ^task.id)
      |> Ash.Query.filter(^row_names(principals))
      |> Ash.exists?(Scope.engine(scope))
  end

  @doc """
  Whether the principals hold the task: it is claimed by them (or by one of
  their teams), and the task does not exclude them.
  """
  @spec holds?(map(), principals()) :: boolean()
  def holds?(%{status: :claimed} = task, principals) do
    assigned =
      case {task.assignee_type, task.assignee_id} do
        {_type, nil} -> false
        {:user, id} -> id == principals.user_id
        {:team, id} -> id in principals.team_ids
        _other -> false
      end

    assigned and not excluded?(task, principals)
  end

  def holds?(_task, _principals), do: false

  @doc """
  A filter on a `TaskCandidate` query: the row names the principals.

  `:user` rows match the user id and `:team` rows the team ids, never the
  other way round, so a team that happens to share an id with a user is not
  that user.
  """
  @spec row_names(principals()) :: Ash.Expr.t()
  def row_names(%{user_id: user_id, team_ids: team_ids}) do
    user_ids = if user_id, do: [user_id], else: []

    Ash.Expr.expr(
      (principal_type == :user and principal_id in ^user_ids) or
        (principal_type == :team and principal_id in ^team_ids)
    )
  end

  defp team_ids(person, scope) do
    resolver = Config.assignment_resolver!()

    ids =
      if Code.ensure_loaded?(resolver) and function_exported?(resolver, :team_ids, 2) do
        resolver.team_ids(person, %{tenant: scope.tenant})
      else
        Map.get(person, :team_ids)
      end

    case ids do
      ids when is_list(ids) -> Enum.reject(ids, &is_nil/1)
      _other -> []
    end
  end
end
