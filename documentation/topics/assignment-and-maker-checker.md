<!--
SPDX-FileCopyrightText: 2026 Luke Galea
SPDX-License-Identifier: MIT
-->

# Assignment and maker-checker

"Who has to approve this?" looks like an authorization question and is actually a
*work distribution* question, and treating it as authorization is where most
workflow systems tie themselves in knots. This page is ash_bpmn's answer, and the
reasoning behind it.

## Candidates are rows

When a human task (or a standalone approval) is created, the engine asks your
`AshBpmn.AssignmentResolver` to turn the declared candidate clauses into a set of
principals, and writes them as `TaskCandidate` rows — one per user or team —
before anyone sees the task. Three consequences, each of which solves a named
problem:

**The task list is one indexed query.** "My tasks" joins tasks to candidates on
the actor's principal ids (their user id plus their team ids). No policy
evaluation per row, no per-request org-chart traversal. The host's precomputed
actor context — the thing that makes the rest of its authorization cheap — stays
exactly as cheap as it was before processes existed.

**Assignment inverts an authorization model, once.** An actor context answers
"what can this actor reach?" — forward-only by design. "Who may act on this
task?" is the inverse question, and answering it per task-list render is the
per-row query cost the forward-only design exists to avoid. Materializing at
creation pays for the inversion once per task instead of once per render.

**The candidate display is real.** Because the set exists as data, "these five
people can claim this" is a query — not an estimate a support engineer gives
with hedging words.

`AshBpmn.my_tasks/2` is that query, and a host's own task board is the same
join written as a read action on its `HumanTask` — see
[presenting tasks to people](#presenting-tasks-to-people).

## Maker-checker without a deny rule

Segregation of duties — the person who raised the request may not approve it —
is inherently subtractive: *everyone in the candidate set, except the requester.*

In an additive authorization model (grants union; no `forbid_if`; order
independence), a subtraction is a structural violation: one deny rule
reintroduces order-dependence and quietly makes every other grant conditional on
where the deny sits. So ash_bpmn never subtracts during policy evaluation. It
subtracts during **data construction**: the exclusion list is applied to the
candidate set *before the rows are written*, and the policy guarding "claim this
task" remains a pure grant — is the actor in the candidate rows?

The same principle runs through both layers: `excluding:` on
`RequireApproval`, `<ash:exclusion who="..."/>` on a user task. The subtraction
happens exactly once, at resolution, in the one place subtraction is allowed.

## One resolver, both layers

A resolver receives the same normalized, string-keyed maps whichever layer asked:

```elixir
# from <ash:candidate kind="manager_of" of="subject.created_by_id"/>
# and from candidates: [{:manager_of, "subject.created_by_id"}]
%{"kind" => "manager_of", "of" => "subject.created_by_id"}

# from <ash:exclusion who="subject.created_by_id"/>
# and from excluding: ["subject.created_by_id"]
%{"who" => "subject.created_by_id"}
```

`AshBpmn.Changes.RequireApproval` runs its options through
`AshBpmn.AssignmentResolver.normalize_candidate_spec/1` and
`normalize_exclusion_spec/1` first, so the diagram layer and the approval layer
cannot drift into two different shapes that a host has to handle separately.

Normalization converts shape only. The values are passed through verbatim,
because `of` is not always a subject path — `kind="team" of="security"` is a
perfectly good clause — and a library that rewrote those strings would be
deciding what a clause means. Write the same spelling in the diagram and in the
change options, and one resolver clause serves both.

## Resolution and re-checking

Your resolver interprets those opaque specs against a live org chart. The rows
it produces are an **index**, not the authority:

- **Claim re-checks candidacy.** Claiming a task requires the actor's principal
  to appear in the task's candidate rows. The rows are what makes that check one
  `MapSet` lookup.
- **Staleness is visible, not silent.** A Monday candidate set does not know
  about Tuesday's reorganisation. The claim path treats the rows as truth; the
  host may re-materialize a task's candidates at any time (destroy + recreate
  the rows, which the set-shaped resource makes natural), and a discrepancy
  between rows and the resolver's rule is exactly the kind of thing a re-check
  should surface rather than smooth over.

## Delegation with accountability

Delegation (`AshBpmn.delegate_task!/2`) reassigns a claimed task to the
delegate, recording `delegated_from_id` on the task and a `:task_delegated`
event naming both parties. It writes no candidate row and checks none, so the
delegate's eligibility is the host's check — see
[presenting tasks to people](#presenting-tasks-to-people). The audit
distinction is the one your event log already draws elsewhere: the delegate
*acted*; the delegator is *accountable*. Out-of-office and workload
rebalancing therefore cost nothing structural — a row and an event — and the
process event log reconstructs who decided, through whom, on whose behalf.

## Presenting tasks to people

ash_bpmn ships no task list screen. A human task is a row on your own
`HumanTask` resource, so your application presents it the way it presents
every other record: in its own layout, under its own policies, as the person
looking at it. ash_bpmn gives you the rows and the operations —
`AshBpmn.claim_task/2`, `complete_task/2` and `delegate_task/2`, which write
the process events and move the token — and leaves the screen to you.

Both reference hosts present tasks as an [ash_a2ui](https://github.com/lukegalea/ash_a2ui)
board over their `HumanTask`. ash_bpmn does not depend on ash_a2ui; any UI
that can run an Ash action as the signed-in person will do. The shape is the
same either way.

**Lanes come from a candidacy read.** Add a read to your `HumanTask` that
returns what the person may act on: open tasks with a candidate row for them
(or for one of their teams), and claimed tasks they hold. The board's lanes
are the task's `status`, narrowed to `:open` and `:claimed`. With nobody
acting, read nothing rather than everything:

```elixir
relationships do
  has_many :candidates, MyApp.Bpmn.TaskCandidate do
    destination_attribute :task_id
  end
end

actions do
  read :awaiting_me do
    prepare MyApp.Bpmn.Preparations.AwaitingMe
  end
end
```

```elixir
def prepare(query, _opts, %{actor: %{id: id}}) when not is_nil(id) do
  Ash.Query.filter(
    query,
    (status == :open and
       exists(candidates, principal_type == :user and principal_id == ^id)) or
      (status == :claimed and assignee_id == ^id)
  )
end

def prepare(query, _opts, _context), do: Ash.Query.filter(query, false)
```

Add team candidates by matching `principal_type == :team` against the team
ids your actor already carries; it is still one indexed query.

**Claim, complete and delegate are row actions run as the person.** Make each
one a generic action on your `HumanTask` that reads the task as the actor and
then calls the engine function with `actor:` (and `tenant:` on a tenant-scoped
install). The engine writes with its own authority, so the decision about
whether *this person* may do *this* to *this task* is your action's.

**The engine leaves these checks to you.** Both reference hosts ran into
them; ash_enterprise's action makes all four, clinic-demo's the first two:

- **The actor on every call.** Pass the person doing it, never a service
  account. The process event log records the `actor:` you give it as the
  person who claimed, decided or delegated.
- **Candidacy beyond an explicit claim.** `claim_task/2` checks the actor
  against the task's `:user` candidate rows only, so a team candidate cannot
  claim through it. `complete_task/2` on an open task claims it on the way
  without checking candidacy, and on a claimed task it does not check that the
  actor is the assignee. Check both before calling it.
- **The delegate is a candidate.** `delegate_task/2` does not check that the
  actor holds the task, or that the delegate is one of its candidates. The
  delegate becomes the assignee and can then complete the task, so an
  unchecked delegation is a way around the candidate set, maker-checker
  exclusion included. Refuse a delegate who is not a candidate.
- **A claim guarded in the database.** The `:claim` action validates the
  status of the struct it was given, so two people claiming at once can both
  succeed. Filter the claim's update on `status == :open`
  (`Ash.Changeset.filter/2`) so exactly one wins, and write the claim and its
  `:task_claimed` event in one transaction.

Worked examples, both public:

- **ash_enterprise** — [`AshEnterpriseWeb.A2ui.TaskBoardUI`](https://github.com/lukegalea/ash_enterprise/blob/main/lib/ash_enterprise_web/a2ui/task_board_ui.ex),
  a board over `HumanTask.awaiting_me` with team candidacy. Its row actions
  run [`AshEnterprise.Bpmn.Actions.WorkTask`](https://github.com/lukegalea/ash_enterprise/blob/main/lib/ash_enterprise/bpmn/actions/work_task.ex),
  which makes all four checks above, including the guarded claim.
- **clinic-demo** — [`ClinicDemoWeb.A2ui.WorklistUI`](https://github.com/lukegalea/clinic-demo/blob/main/lib/clinic_demo_web/a2ui/worklist_ui.ex),
  a board over a `:worklist` read
  ([`ClinicDemo.Visits.Preparations.Worklist`](https://github.com/lukegalea/clinic-demo/blob/main/lib/clinic_demo/visits/preparations/worklist.ex)).
  Its row actions run
  [`ClinicDemo.Visits.TaskDesk`](https://github.com/lukegalea/clinic-demo/blob/main/lib/clinic_demo/visits/task_desk.ex),
  which passes the actor, checks candidacy and holding, and checks that the
  person delegating holds the task.

## Escalation

`escalate` timers call the resolver's optional `escalate/2` callback — the
library again refusing to know what an escalation means (reassign to the
manager? page the on-call? notify the BU head?) while providing the durable
trigger, the cancellation bookkeeping, and the audit event.
