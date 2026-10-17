# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.Resources.HumanTask.AwaitsActor do
  @moduledoc """
  The candidacy test behind the generated `HumanTask`'s `:awaiting_actor`
  read, as an expression calculation: true for a task the actor may act on
  now.

    * an **open** task with a candidate row for the actor (a `:user` row) or
      for one of their teams (a `:team` row), or
    * a **claimed** task the actor holds: assigned to them, or to one of
      their teams,

  and in neither case a task whose recorded exclusions name the actor or one
  of their teams (see `AshBpmn.Candidacy`). With no actor, or one with no id,
  the expression is `false`.

  An expression, so it becomes part of the query's SQL: a read, a count, a
  page with a count and an aggregate over the read all filter on it. It is
  a calculation rather than a filter written when the query is prepared
  because Ash fills a calculation's context with the actor the query runs as.
  A UI library may build the query without an actor and pass one only to
  `Ash.read/2` or `Ash.count/2`; the expression is built for that actor.

  The candidate rows are matched with an `exists` over the TaskCandidate
  resource that is not authorized: TaskCandidate read policies do not apply
  to it. It only decides which tasks match, scoped to the task
  (`task_id == parent(id)`) and the actor's own ids.
  """

  use Ash.Resource.Calculation

  require Ash.Expr

  alias AshBpmn.{Candidacy, Scope}

  @impl true
  def expression(opts, context) do
    actor = context.actor
    principals = Candidacy.for_actor(actor, %Scope{actor: actor, tenant: context.tenant})

    if Candidacy.anyone?(principals) do
      awaiting(task_candidate(opts[:resource]), principals)
    else
      Ash.Expr.expr(false)
    end
  end

  defp awaiting(task_candidate, principals) do
    %{user_id: user_id, team_ids: team_ids} = principals
    ids = Candidacy.ids(principals)

    # Unrelated rather than through a `candidates` relationship, so the read works whether or
    # not the host passed `:task_candidate` to the HumanTask macro or declared the
    # relationship itself.
    candidate_row = %Ash.Query.Exists{
      path: [],
      resource: task_candidate,
      at_path: [],
      related?: false,
      expr:
        Ash.Expr.expr(
          task_id == parent(id) and
            ^Candidacy.row_names(principals)
        )
    }

    Ash.Expr.expr(
      not fragment("? && ?", excluded_principal_ids, type(^ids, {:array, :uuid})) and
        ((status == :open and ^candidate_row) or
           (status == :claimed and
              ((assignee_type == :user and assignee_id == ^user_id) or
                 (assignee_type == :team and assignee_id in ^team_ids))))
    )
  end

  defp task_candidate(resource) do
    {:ok, resources} = resource |> Ash.Resource.Info.domain() |> AshBpmn.Resources.for_domain()
    resources.task_candidate
  end
end
