# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.Checks.AshBpmnInteraction do
  @moduledoc """
  Passes when the engine itself is the caller.

  The engine has to write rows a person is not allowed to write. Advancing a
  token consumes one row and creates another; completing a task records an event
  nobody has an action for; a timer cancels a task whose assignee is on holiday.
  None of that is a user operation, and no host policy should have to enumerate
  it.

  The obvious way to express that is `authorize?: false` on the engine's own
  calls, and that is what this package used to do — at ninety call sites. The
  trouble with ninety of them is not that any one is wrong. It is that
  `authorize?: false` is indistinguishable from a mistake at a glance, it is
  invisible to a host's policies, and adding the ninety-first is a one-line diff
  that nothing reviews.

  So the engine marks its own calls instead:

      Ash.read_one!(query, AshBpmn.Scope.engine(scope))

  which sets `context: %{private: %{ash_bpmn?: true}}`, and every generated
  resource carries one policy that recognises it:

      policies do
        bypass AshBpmn.Checks.AshBpmnInteraction do
          authorize_if always()
        end
      end

  The bypass is one named, greppable, testable thing rather than ninety
  anonymous ones, and a host reading the resource's policies can *see* the engine
  path — which was previously not represented in the policy set at all.

  ## What this is not

  It is not a security boundary against the host application. Anything that can
  set private context could equally have passed `authorize?: false`, so this does
  not make the engine harder to impersonate from inside the same BEAM. What it
  changes is that the engine's authority is now declared in the policy set, where
  it can be read, reasoned about and — if a host disagrees — replaced.

  The bypass can be dropped entirely with `policies?: false` on the resource
  macro, in which case the host owns the whole policy set and must grant the
  engine whatever it needs.

  ## Ordering matters, in one direction

  Ash does not walk policies one at a time; it folds them into a single boolean
  expression and solves it (`Ash.Policy.Policy.expression/2`). The fold is still
  order-sensitive, though, and in exactly the way the DSL documentation implies:
  a bypass contributes a disjunct covering the policies **after** it, so a bypass
  authorizes a request only when the restrictive policies it needs to skip were
  declared later.

  For a resource whose whole policy set comes from the macro that is automatic —
  the bypass is the only policy there is. It matters as soon as a host is
  involved:

    * A host adding `policies do … end` **after** `use AshBpmn.Resources.X`:
      fine, the bypass is already ahead of it.
    * A host using `:base` where the base ships its own policy set: **not** fine.
      `use <base>` expands first, so the base's policies precede this bypass and
      the engine is forbidden. `AshBpmn.Config.engine_actor/0` documents the two
      ways out, and `base_resource_test.exs` pins both behaviours so neither can
      change quietly.
  """

  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_opts), do: "the ash_bpmn engine is the caller"

  @impl true
  def match?(_actor, %{subject: %{context: %{private: %{ash_bpmn?: true}}}}, _opts), do: true
  def match?(_actor, _context, _opts), do: false
end
