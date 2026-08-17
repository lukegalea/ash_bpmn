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

`AshBpmn.Web.TaskListLive` is that query rendered:

![The task list showing one open task and one claimed task with its decision form](../assets/task-list.png)

Open tasks the actor is a candidate for offer Claim; claimed ones offer the
decision — an outcome, a comment, or a delegation. Both sections come from the
same join against `TaskCandidate`, which is why the list costs one query no
matter how large the org chart behind the candidate clauses is.

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

Delegation (`AshBpmn.delegate_task!/2`) adds the delegate as a candidate and
reassigns, recording `delegated_from_id` on the task and a `:task_delegated`
event naming both parties. The audit distinction is the one your event log
already draws elsewhere: the delegate *acted*; the delegator is *accountable*.
Out-of-office and workload rebalancing therefore cost nothing structural — a
row and an event — and the process event log reconstructs who decided, through
whom, on whose behalf.

## Escalation

`escalate` timers call the resolver's optional `escalate/2` callback — the
library again refusing to know what an escalation means (reassign to the
manager? page the on-call? notify the BU head?) while providing the durable
trigger, the cancellation bookkeeping, and the audit event.
