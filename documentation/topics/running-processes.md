<!--
SPDX-FileCopyrightText: 2026 Luke Galea
SPDX-License-Identifier: MIT
-->

# Running processes

The engine is a token interpreter whose durability comes from Postgres and whose
scheduling comes from Oban. Nothing about a running process lives in memory.

## The advance loop

```elixir
AshBpmn.start_instance!(MyApp.Bpmn,
  process: "access_request",
  subject: request,
  actor: user,
  tenant: org_id
)
```

Starting an instance pins the latest published definition, creates the instance
row with one active token at the start node, and enqueues the first advance job.
From there, every token transition is the same job:

1. **Load and claim.** The job loads token + instance. A token not in `:active`
   state is a redelivery — skip. Claiming flips `:active → :executing` with an
   optimistic update; if another job won, the loser exits `{:ok, :lost_race}`.
   This claim gate is the idempotency anchor for the whole engine.
2. **Read the snapshot.** Node lookup comes from `definition.graph` — never from a
   module. A definition whose source has been replaced still executes.
3. **Execute the node** (dispatch table below).
4. **Write, once.** Consume the token, create the next token(s), append process
   events, and insert the next advance job — all in one transaction, so a crash
   between steps is impossible rather than handled.

### Node dispatch

| Node | Behaviour |
|---|---|
| startEvent | follow outgoing flows |
| serviceTask | call `action_invoker.invoke(action, ctx)`; retry with backoff on error |
| userTask | create `HumanTask` + candidate rows + timers; token parks as `:waiting` |
| intermediateCatchEvent | park the token as `:waiting` and schedule its wake; see [timer catch events](#timer-catch-events) |
| exclusiveGateway | evaluate outgoing conditions (first match wins), else the declared default; branch taken is recorded as an event |
| parallelGateway (fork) | mint one child token per outgoing flow, sharing a `fork_id` |
| join | see below |
| endEvent | mark instance `:completed` with the end event's configured outcome |
| endEvent with `terminateEventDefinition` | kill every other live token first, then complete; see [terminating an instance](#terminating-an-instance) |

## The token lifecycle

A token is one live branch of one instance, and it is in exactly one of five
states:

| Status | Means |
|---|---|
| `active` | minted, with an advance job queued for it and nobody holding it |
| `executing` | an advance job has claimed it and is running the node |
| `waiting` | parked at a node that waits for something outside the engine |
| `consumed` | the branch moved on — the work at this node finished and the next token carries it |
| `dead` | the branch was cut off: attempts exhausted, the instance cancelled, or a terminate end event |

Every transition is its own action on the token resource, guarded on the status
the row has *in the database* rather than the one the caller happened to read, so
a redelivery or a racing worker loses at the transition instead of halfway
through the node.

### Why waiting is not a kind of executing

An `:executing` token is mid-flight: its job is either running right now or it is
lost, those are the only two possibilities, and both are the engine's problem to
solve. A `:waiting` token correctly has no job at all. It is parked because the
node it reached waits for something the engine does not control — a person, a
date — and sitting there for months is a healthy steady state, not a symptom.

Parking as `:executing`, which is what user tasks used to do, makes those two
indistinguishable. "Stuck" and "waiting" then look identical in the token table,
in an operator's query, and to the reconciliation sweep, which is why the sweep
can only afford to recover `:active` tokens: anything it found in `:executing`
was either a job to re-enqueue or an approval nobody had got to yet, with nothing
in the row to say which. A separate status is what makes "what is this instance
waiting for, and for how long?" a question Postgres answers.

Four columns come with the state, and they record what the token is *listening
for*, never what the subject said — the same line drawn for promoted signals:

- `parked_at` — when the wait began, which is the age of a wait somebody is now
  asking about.
- `subscription_signature` — the coarse key a wake is matched against. A timer
  catch sets `timer:<node_id>`; a user task leaves it nil, because nothing
  correlates to a user task — completing it names the token directly.
- `correlation_key` — the value an arriving event's key must equal, computed once
  at park so a subject edited during the wait cannot silently change what the
  token is listening for. Nil for both of today's waits.
- `lookback_until` — how far back a wake may reach for an event that arrived
  before the token parked. Nil means BPMN-strict, which is the default.

### Leaving the waiting state

A parked token leaves in one of two ways, and neither of them is a timeout on the
token itself:

- **It is woken.** A user task's completion (or its expiry timer) claims the
  token out of `:waiting` by id; a timer catch event's Oban job claims its own.
  Waking is a different action from the ordinary claim, and admits only
  `:waiting` where the ordinary one admits only `:active`, so an advance worker
  can never race a normal claim into a parked token. The claim re-reads the row
  inside the transaction and one caller wins, so a redelivered completion or a
  re-run job loses there rather than routing the branch twice. Waking clears the
  four columns, because a running token still advertising a correlation key is a
  claim about the present that is no longer true, and whoever queries the table
  next will believe it.
- **It is pruned.** A terminate end event kills every other live branch of the
  instance, parked ones included.

`:waiting` is deliberately a status a token can be consumed and killed out of,
rather than one it can only leave through the event it was waiting for. A parked
branch has no job to cancel and no worker to interrupt, so if its own event were
the only exit, a terminate end event would complete an instance that still had a
branch waiting forever, and an interrupting boundary event — when the subset
grows one — would have nothing it could interrupt. Waking and pruning stay
separate actions for the same reason the statuses are separate: the audit log
records action names, and "woken by its event" and "killed by a terminate" are
not the same thing happening to a branch.

## Joins

A join node waits for all branches named in its `waits_for`. Each arriving token
is consumed and counted; when the count of consumed arrivals for a `fork_id`
reaches the expected arity, one fresh token is minted at the join and the process
continues. All of this happens in one transaction per arrival, so two branches
finishing simultaneously cannot double-fire: the counter arithmetic is the lock.

A dead sibling branch means the join can never fire — the compiler rejects the
mixed-gateway patterns that create this shape, and the reconciliation sweep
reports any join that has been waiting with dead siblings as a stuck condition
(an event an operator can query), because converting a hang into a different
wrong answer via join timeouts is a choice, and it is not this library's default.

## Terminating an instance

An ordinary end event ends *its own branch*. Under a fork, the instance is only
finished when the last branch reaches one, and completing is idempotent about
that.

An end event carrying a `terminateEventDefinition` ends the *process*. Every
other live token of the instance — `:active`, `:executing` or `:waiting` — is
killed where it stands, whatever it was doing, and then the instance completes
with that end event's outcome. The kill is recorded as its own event carrying the
token ids and the node ids they died on, because "the instance completed" and
"four branches were cut off to make that happen" are different facts and an
auditor asks about the second one.

Killing the parked branches is the case that makes the construct work at all: a
branch waiting on an approval has no job to cancel and no worker to interrupt, so
a terminate that could not reach it would leave a token waiting forever on an
instance that had already finished — precisely the shape a terminate end event
exists to prevent.

The marker is read straight off the diagram at compile time and stored on the
node in the snapshot. That is deliberate: the difference between ending a branch
and ending a process has to be visible on the canvas an analyst signed off, not a
property of how the engine happened to run.

## Timers

Human tasks may declare three timers, each an Oban job with `scheduled_at` and its
id recorded on the task row:

- **remind** — records a `:timer_fired` event; your notifier reads the log.
- **escalate** — calls your resolver's optional `escalate/2` callback and records
  the event; typical use: reassign to the assignee's manager.
- **expire** — force-completes the task with outcome `:expired` and advances the
  token so the graph's expiry path (often a rejection route) runs.

When a task completes, the engine cancels its outstanding timer jobs. This
bookkeeping is not optional in either direction: completing without cancelling
produces escalation emails for decided work, and expiring without advancing
produces a zombie token. If you add a completion path in a host extension,
cancel the timers.

## Timer catch events

An `intermediateCatchEvent` carrying a `timerEventDefinition` is a node whose
whole behaviour is to wait — a cool-off period, a notice period, a grace window
before the next step runs:

```xml
<bpmn2:intermediateCatchEvent id="CoolOff" name="Cool-off period">
  <bpmn2:timerEventDefinition>
    <bpmn2:timeDuration>P2D</bpmn2:timeDuration>
  </bpmn2:timerEventDefinition>
</bpmn2:intermediateCatchEvent>
```

The delay is an ISO 8601 duration read straight out of `bpmn:timeDuration`,
because that is what BPMN specifies and what every modelling tool already writes
there. An `ash:` attribute spelling the same thing — `hours="48"` — would mean a
diagram drawn in Camunda or bpmn.io carries a delay this compiler cannot see,
which is the one-artifact rule turned inside out. It is parsed at publish time,
so a duration nobody can read is a compile error naming the node rather than an
instance that parks at three in the morning and never wakes. `timeCycle`,
`timeDate`, and months or years inside a duration are refused; see
[what it refuses](what-it-refuses.md#refused-at-compile-time).

When the token arrives, the advance job parks it as `:waiting` and inserts one
Oban job whose `scheduled_at` is *now* plus the duration. Now, not publish time:
computing the instant when the definition was compiled would make every instance
of a published version fire at the same moment.

Oban does the waiting, and that is the whole design. Holding the wake durably,
promoting it when it comes due and never before, retrying it if the node dies
mid-wake: all of that is `Oban.Stager` and a row in `oban_jobs`, and none of it
is reimplemented here. A fortnight-long wait is a database row, so it survives a
restart, a deploy, and the machine that scheduled it being replaced. An
in-memory timer is a wait a deploy silently cancels, and you find out on the
Thursday the process did not resume.

When the job runs it claims the token out of `:waiting`, records a
`:timer_fired` event and advances along the catch event's outgoing flow. One
flow: a catch event is a point on a path, not a decision, and a second flow out
of it is a gateway drawn without a gateway — put the box on the diagram, where
the routing is something an analyst can read. Losing that claim — a terminate
end event killed the branch, or the job is a redelivery of one that already ran —
ends the wake with no error. It is the ordinary way for a timer whose branch is
gone to finish, not a failure to retry.

## Failure semantics

A service task error propagates the error to Oban, which retries with backoff up
to `max_attempts` (config, default 5). When attempts are exhausted, the worker
marks the instance `:failed`, records an `:action_failed` event naming the node
and reason, and stops retrying. `AshBpmn.retry_instance!/1` reactivates dead
tokens and re-enqueues them — the operator's button after fixing the underlying
problem.

Human tasks never fail the instance by themselves: they wait. Expiry is the
declared alternative to waiting forever, and it is opt-in per task.

## Watching an instance run

`AshBpmn.Web.ViewerLive` renders an instance against the graph it pinned, with
its live tokens marked on the diagram:

![The instance viewer showing a running instance parked on two parallel reviews](../assets/viewer-running.png)

Everything on the right is a row in Postgres, not a reconstruction: the token
table is the branch state (`consumed` for the path already taken, `waiting` for
the two parallel reviews this instance is parked on), the task table is the
human work those tokens parked at, and the event list is the audit trail in
reverse order. Nothing here is derived from an in-memory process.

The same view of a finished instance is the audit trail an approver's manager
actually gets asked for:

![The viewer showing a completed instance with every token consumed](../assets/viewer.png)

Every token is `consumed`, and the event list reads end to end: started, routed
at the gateway, task created, claimed, completed, the action invoked, instance
completed. Because the viewer renders the *pinned* version, this is what the
instance executed, not what the process looks like today.

The nodes an instance is currently on are marked with the `ash-bpmn-highlight`
class, styled by `priv/js/ash_bpmn.css` — which the hook imports, so you get it
by importing the hook.

## The reconciliation sweep

`AshBpmn.Runtime.SweepWorker` is a plain Oban worker you may put on a cron
schedule. It finds running instances whose active tokens have no live job —
lost to a deploy, a cancelled queue, a bug — and re-enqueues their advances
(idempotent by the claim gate), and reports stuck joins. The sweep is a safety
net, not the primary driver; the engine is push-based, and the sweep exists so
"stuck instance" is a detected condition rather than a support ticket.

It considers `:active` tokens only, and leaves `:waiting` ones alone. A parked
token is not missing a job — it correctly has none — so re-enqueuing an advance
for it would push a branch past an approval nobody has given or a date that has
not arrived. That distinction is only available to the sweep because parking has
its own status; back when parked tokens sat in `:executing`, the sweep could not
tell a lost job from a patient one and so recovered neither.

## Testing the engine

`config :ash_bpmn, oban_testing: :inline` swaps the Oban boundary for a
deterministic shim: advance jobs execute synchronously at insert, timers are
stored and never self-fire — tests fire them explicitly via
`AshBpmn.Runtime.Oban.TestJobs.fire!/2`. There is no clock, no polling, and no
sleep in the engine's test suite, and your host tests get the same determinism.

## Cancellation

`AshBpmn.cancel_instance!/1` marks the instance `:cancelled`, kills its active
tokens and cancels open human tasks (with events). It does not compensate
completed work — compensation is a phase-3 concern this library deliberately does
not ship (see [what it refuses](what-it-refuses.md)).
