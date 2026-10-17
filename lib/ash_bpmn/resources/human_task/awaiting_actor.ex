# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.Resources.HumanTask.AwaitingActor do
  @moduledoc """
  The generated `HumanTask` candidacy read, `:awaiting_actor`: the tasks the
  actor may act on now.

    * **open** tasks with a candidate row for the actor (a `:user` row) or for
      one of their teams (a `:team` row), and
    * **claimed** tasks the actor holds: assigned to them, or to one of their
      teams.

  A task whose recorded exclusions name the actor or one of their teams is in
  neither (see `AshBpmn.Candidacy`). With no actor, or one with no id, the
  read returns nothing rather than everything.

  The actor is read in a `before_action` hook, from the actor the read runs as.
  A UI library may build the query without an actor and pass one only to
  `Ash.read/2`; anything decided when the query is built would see nobody.
  """

  use Ash.Resource.Preparation

  require Ash.Expr
  require Ash.Query

  alias AshBpmn.{Candidacy, Scope}

  @impl true
  def prepare(query, _opts, _context) do
    query
    |> Ash.Query.filter(status in [:open, :claimed])
    |> Ash.Query.before_action(&narrow/1)
  end

  defp narrow(query) do
    actor = get_in(query.context, [:private, :actor])
    scope = %Scope{actor: actor, tenant: query.tenant}
    principals = Candidacy.for_actor(actor, scope)

    if Candidacy.anyone?(principals) do
      Ash.Query.filter(query, ^awaiting(query.resource, principals))
    else
      Ash.Query.filter(query, false)
    end
  end

  defp awaiting(resource, principals) do
    %{user_id: user_id, team_ids: team_ids} = principals
    ids = Candidacy.ids(principals)

    # Unrelated rather than through a `candidates` relationship, so the read works whether or
    # not the host passed `:task_candidate` (or declared the relationship itself).
    candidate_row = %Ash.Query.Exists{
      path: [],
      resource: task_candidate(resource),
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
