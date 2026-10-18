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

`AshBpmn.my_tasks/2` is that query (user ids against `:user` rows, team ids
against `:team` rows), and the generated `HumanTask` read `:awaiting_actor` is
the same join run as the person; see
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

**The task keeps what was subtracted.** Removing the requester's row is not
enough once team rows can be claimed: the requester may belong to a candidate
team, and the team's row says nothing about who is in it. So the task also
records the ids the subtraction removed, as `excluded_principal_ids`, and the
engine treats a person as excluded when their own id or any of their team ids
is among them. A team member who raised the request can neither claim it,
complete it nor be handed it by delegation. This is still the subtraction made
at resolution, written down with the task; no policy carries a deny rule.
A task created before the column existed has `[]` there and relies on its
rows alone.

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

- **Claim re-checks candidacy.** Claiming a task requires a candidate row for
  the actor (a `:user` row) or for one of their teams (a `:team` row), and the
  actor must not be excluded. The rows are what makes that check one indexed
  query. The engine learns an actor's teams from your resolver's optional
  `team_ids/2` callback, or from a `:team_ids` list on the actor:

  ```elixir
  @impl true
  def team_ids(%{id: user_id}, %{tenant: tenant}), do: MyApp.Teams.ids_for(user_id, tenant)
  ```
- **Staleness is visible, not silent.** A Monday candidate set does not know
  about Tuesday's reorganisation. The claim path treats the rows as truth; the
  host may re-materialize a task's candidates at any time (destroy + recreate
  the rows, which the set-shaped resource makes natural), and a discrepancy
  between rows and the resolver's rule is exactly the kind of thing a re-check
  should surface rather than smooth over.

## Delegation with accountability

Delegation (`AshBpmn.delegate_task!/2`) reassigns a claimed task to the
delegate, recording `delegated_from_id` on the task and a `:task_delegated`
event naming both parties. Only the person holding the task may delegate it,
and the delegate must be one of its candidates: a `:user` delegate needs a
candidate row for them or one of their teams, a `:team` delegate a `:team` row
for that team, and an excluded delegate is refused either way. Delegation
writes no candidate row, because the delegate becomes the assignee and an
assignee completes the task without a further candidacy check; delegating to
anyone else would be a way around the candidate set. The audit distinction is
the one your event log already draws elsewhere: the delegate *acted*; the
delegator is *accountable*. Out-of-office and workload rebalancing therefore
cost nothing structural (a row and an event), and the process event log
reconstructs who decided, through whom, on whose behalf.

## Presenting tasks to people

ash_bpmn ships no task list screen. A human task is a row on your own
`HumanTask` resource, so your application presents it the way it presents
every other record: in its own layout, under its own policies, as the person
looking at it. ash_bpmn gives you the rows, a candidacy read, and the
operations: `AshBpmn.claim_task/2`, `complete_task/2` and `delegate_task/2`,
which check who is acting, write the process events and move the token.

Both reference hosts present tasks as an [ash_a2ui](https://github.com/lukegalea/ash_a2ui)
board over their `HumanTask`. ash_bpmn does not depend on ash_a2ui; any UI
that can run an Ash action as the signed-in person will do. The shape is the
same either way.

**Lanes come from the candidacy read.** The generated `HumanTask` has a read
action, `:awaiting_actor`, that returns what the person may act on: open tasks
with a candidate row for them or one of their teams, and claimed tasks they
hold (assigned to them, or to one of their teams). Neither includes a task
that excludes them. With nobody acting it reads nothing rather than
everything. The narrowing is a filter on the query, so a lane total from
`Ash.count/2`, `Ash.aggregate/3` or a page with `count: true` on an
`:awaiting_actor` query counts the same tasks the read returns. The read
paginates (offset or keyset, not required). The filter uses the actor the
query runs as, so a query built without one and read or counted with one still
narrows. The board's lanes are the task's `status`.

Two limits. A relationship aggregate that names the read, such as
`count :awaiting, :tasks, read_action: :awaiting_actor`, does not narrow: Ash
does not run a read action's preparations for a relationship aggregate, so it
counts tasks that do not await the person. Count the lane on an
`:awaiting_actor` query instead. And the resolver's `team_ids/2` runs each
time Ash builds the filter, several times per read or count, so keep it cheap
(work the person's teams out once per request and return them from the actor).

```elixir
MyApp.Bpmn.HumanTask
|> Ash.Query.for_read(:awaiting_actor)
|> Ash.Query.sort(inserted_at: :asc)
|> Ash.read!(actor: current_user)

# A lane total: the same tasks, counted.
MyApp.Bpmn.HumanTask
|> Ash.Query.for_read(:awaiting_actor)
|> Ash.Query.filter(status == :open)
|> Ash.count!(actor: current_user)
```

The candidate rows are matched with an `exists` over your `TaskCandidate`
that is not authorized: your `TaskCandidate` read policies do not apply to it.
It only decides which tasks come back, matched on the task and the person's
own ids, and returns no candidate row. Your `HumanTask` read policies apply to
the read as usual. Pass `task_candidate: MyApp.Bpmn.TaskCandidate` to the `HumanTask` macro
to get a `has_many :candidates` relationship as well (leave it out if your
resource already declares one). For an outcome picker, load the `:outcomes`
calculation: the outcomes the task's BPMN step declares, read from the
definition its instance pinned. It is `nil` for a standalone approval, whose
outcomes are not stored on the task.

**Claim, complete and delegate are row actions run as the person.** Make each
one a generic action on your `HumanTask` that reads the task as the actor and
then calls the engine function with `actor:` (and `tenant:` on a tenant-scoped
install). Pass the person doing it, never a service account: the engine
checks who may act against the `actor:` you give it, and the process event
log records that actor as the person who claimed, decided or delegated.

**Do not let people run `HumanTask`'s `:claim`, `:complete` or `:delegate`
actions themselves.** Those actions take the assignee and the decider as plain
inputs and check nobody; the checks below are in the engine functions. They
refuse any caller but the engine, whatever your policies say, so a policy such
as `policy action_type(:update)` cannot open them to people by accident. Grant
people your own generic actions instead. `:force_complete` writes an outcome
with no decider and checks nobody either; it is left open for an
administrator's override, so authorize it for administrators only.

**What the engine checks.** Each function refuses with an `ArgumentError`
(returned as `{:error, exception}`) and writes nothing when:

- **Claim:** the actor is not a candidate (a `:user` row for them or a `:team`
  row for one of their teams), or the task excludes them.
- **Complete:** the task is open and the actor is not a candidate (a
  candidate's completion claims it on the way, with its event), or the task is
  claimed and the actor does not hold it.
- **Delegate:** the actor does not hold the task, or the delegate is not a
  candidate, or the task excludes the delegate.

A claim is also guarded in the database: its UPDATE matches only a row that is
still `:open`, so of two people claiming at once exactly one wins and the other
gets an error, and the claim and its `:task_claimed` event commit together.
Completion and delegation of a claimed task are guarded the same way, on
`:claimed` and on the holder the engine checked, so a completion that races a
delegation is refused once the task has passed to someone else.

What stays yours: whether the person may see the task at all (your read
policies), how a delegate is named and found (an email they typed, a picker),
and any check of your own, such as refusing to delegate to someone who cannot
read the task.

Worked examples, both public. Both were written before the engine made these
checks, so each makes them itself as well:

- **ash_enterprise**: [`AshEnterpriseWeb.A2ui.TaskBoardUI`](https://github.com/lukegalea/ash_enterprise/blob/main/lib/ash_enterprise_web/a2ui/task_board_ui.ex),
  a board over `HumanTask.awaiting_me` with team candidacy. Its row actions
  run [`AshEnterprise.Bpmn.Actions.WorkTask`](https://github.com/lukegalea/ash_enterprise/blob/main/lib/ash_enterprise/bpmn/actions/work_task.ex).
- **clinic-demo**: [`ClinicDemoWeb.A2ui.WorklistUI`](https://github.com/lukegalea/clinic-demo/blob/main/lib/clinic_demo_web/a2ui/worklist_ui.ex),
  a board over a `:worklist` read
  ([`ClinicDemo.Visits.Preparations.Worklist`](https://github.com/lukegalea/clinic-demo/blob/main/lib/clinic_demo/visits/preparations/worklist.ex)).
  Its row actions run
  [`ClinicDemo.Visits.TaskDesk`](https://github.com/lukegalea/clinic-demo/blob/main/lib/clinic_demo/visits/task_desk.ex).

## Escalation

`escalate` timers call the resolver's optional `escalate/2` callback — the
library again refusing to know what an escalation means (reassign to the
manager? page the on-call? notify the BU head?) while providing the durable
trigger, the cancellation bookkeeping, and the audit event.
