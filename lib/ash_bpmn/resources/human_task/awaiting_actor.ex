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

  The narrowing is a filter on the query, so `Ash.read/2`, `Ash.count/2`, a
  page that counts and an aggregate over the read all see the same tasks. The
  filter is the `:awaits_actor?` calculation
  (`AshBpmn.Resources.HumanTask.AwaitsActor`), which Ash builds for the actor
  the query runs as: a query built without an actor and read or counted with
  one still narrows to that actor.
  """

  use Ash.Resource.Preparation

  require Ash.Query

  @impl true
  def prepare(query, _opts, _context) do
    Ash.Query.filter(query, status in [:open, :claimed] and awaits_actor?)
  end
end
