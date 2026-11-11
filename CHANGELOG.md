<!--
SPDX-FileCopyrightText: 2026 Luke Galea
SPDX-License-Identifier: MIT
-->

# Change Log

All notable changes to this project will be documented in this file.
See [Conventional Commits](https://conventionalcommits.org) for commit guidelines.

<!-- changelog -->

## [Unreleased]

Requires Elixir 1.20 or later.

Nothing has been released yet. Everything below is the initial body of work.

### Bug Fixes:

- **The dialyzer job gates again.** CI reported 59 calls to missing
  functions (`Enum.__in__/2`, `:elixir_quote.validate_quote/1` and
  `unquote/1`) because the PLT cache key had no Elixir version in it: the
  step read the second line of `elixir --version`, which is blank, so a PLT
  built under an earlier Elixir was restored as an exact hit. The key now
  takes `System.version()` and the step fails if it comes out empty. With a
  fresh PLT, `mix dialyzer --format short` reports nothing, so the job is no
  longer advisory and fails the build on new warnings.

- **A reconnect no longer replaces unsaved edits in the designer.** Entering
  the route pushes `load_xml` again on every reconnect, and the hook imported
  it over whatever was on the canvas. That push now carries `route_key`, and
  the hook keeps a canvas with unsaved edits to the same key. It also skips
  the second import of the same document on connect, and importing no longer
  reports the canvas as modified. Revert, Customize and Discard still replace
  the canvas.

### Features:

- **A call activity's child is accountable to whoever started the parent.**
  The child instance's `started_by_id` is its parent's, as its subject and
  trigger depth already were, so work a person started still names that person
  when it is broken out into a child process (and a grandchild). Before, the
  child was started under the engine's system actor and named nobody. A
  parent that names nobody passes nobody on; an instance started directly
  keeps the `started_by_id` (or actor) it is given.

- **Call activities can pin their child's version.** `ash:process` takes the
  `ash:decision` vocabulary: `binding="latest"` (the default) starts whatever
  is published under the key when the token arrives, `binding="pinned"
  version="N"` starts version N for as long as it stays published. A pin with
  no version, a version with `latest`, and a version that is not a positive
  integer are refused at compile time. `start_instance/2` takes `:version`
  beside `:process`, and `:child_started` events record the child's
  `child_definition_id`. Snapshots of diagrams that say nothing are unchanged.
- **Timer boundaries on receive tasks and call activities.** A deadline on a
  wait for a message or for a child process, interrupting or not, with the
  same semantics as on a user task. The wait stays a parked token and a
  scheduled job; whichever of the deadline and the wake claims the token first
  wins. An interrupting boundary on a call activity cancels the child instance
  and its own call tree in the same step, each with an `:instance_cancelled`
  event whose data names the boundary. A boundary on an intermediate message
  catch event is refused with a pointer to the receive task, since BPMN
  attaches boundary events to activities only.
- **Business errors and error boundary events.** A service or send task's
  callee can now throw a business error by name: an `ActionInvoker` returns
  `{:error, {:bpmn_error, code, details}}`, an `ash:call` callable returns an
  `AshBpmn.BpmnError`. An error boundary on the task whose `bpmn:error` has
  that `errorCode` catches it and the process leaves by the boundary's flow; a
  call activity's error boundary catches a child that reached an error end
  event with that code. A business error nothing catches fails the instance
  at the task at once, without retrying (`:action_failed`, reason
  `"unhandled_error"`). Any other `{:error, term}` is a fault and is retried
  as before. Error boundaries attach to service, send and call activity
  nodes, always interrupt, and must name a declared error with an
  `errorCode`. A parent whose child ends in an error end event no longer
  waits forever when nothing catches it: it fails at the call activity.
- **A stable invocation key for service and send tasks.** Both bindings now
  receive `{instance_id, token_id, node_id}`: the `ActionInvoker` at
  `ctx[:invocation_key]`, an `ash:call` callable in its action context at
  `context.ash_bpmn.invocation_key`. A redelivery of the advance job (a retry, a
  recovered claim, `retry_instance/2`) carries the same key; the next execution
  of the node carries a new one. A host records an invocation's result under
  the key to make a redelivery return it rather than redo the work.
- **Who acts on a human task is checked by the engine.** `claim_task/2`,
  `complete_task/2` and `delegate_task/2` check candidacy and holding (see
  Breaking changes), team candidates included: a resolver's optional
  `team_ids/2` callback (or a `:team_ids` list on the actor) tells the engine
  which teams a person is in. The checks live in `AshBpmn.Candidacy`. Both
  reference hosts had rebuilt them; they no longer need to.
- **A candidacy read on the generated `HumanTask`.** `:awaiting_actor` returns
  the open tasks the actor or one of their teams is a candidate for and the
  claimed tasks they hold, leaves out tasks that exclude them, and returns
  nothing with no actor. The narrowing is a filter on the query, so
  `Ash.count/2`, `Ash.aggregate/3` and counted pages on an `:awaiting_actor`
  query agree with it (a relationship aggregate naming it as `read_action`
  does not narrow), and the read
  paginates (offset or keyset, optional). It uses the actor the query runs as,
  so a query built without one and read or counted with one still narrows.
- **`has_many :candidates`** on the generated `HumanTask` when the macro is
  given `task_candidate: MyApp.TaskCandidate`.
- **`HumanTask.outcomes`**, a calculation: the outcomes the task's BPMN step
  declares, read from the definition its instance pinned, for an outcome
  picker. `nil` for a standalone approval, whose outcomes are not stored.
- **Discarding a draft.** Definitions gain a `:discard` destroy action (code
  interface `discard/2`) that removes a draft and refuses everything else: the
  validation names the problem, and a `status = 'draft'` filter on the delete
  makes the rule hold at the database, so a stale struct cannot take a row that
  has been published since. The designer offers "Discard draft" on a stored
  draft and falls back to the scope's published definition, the baseline, or
  the template.
- **The live process flight view.** `AshBpmn.FlightView` gives hosts the three
  pieces a live process view is built from: `mermaid/2` renders a published
  definition as a mermaid flowchart whose node ids are the definition's own
  element ids (so overlays positioned by mermaid node id land on the element
  the token is standing on); `token_positions/2` reports one entry per live
  token across a definition's instances, carrying the node id, the token
  status, and the instance's subject passthrough (`subject_type`/`subject_id`
  — join keys the host resolves into records itself); and the subscription
  contract broadcasts every token transition — create, claim, park, wake,
  consume, kill, reactivate — on `bpmn:tokens:definition:<id>` and
  `bpmn:tokens:instance:<id>` PubSub topics after the write commits. Set
  `config :ash_bpmn, pubsub_server: MyApp.PubSub`; with none configured the
  broadcasts are no-ops and the documented fallback is polling the query, which
  is what the built-in viewer LiveView already does. See
  [the flight view](documentation/topics/flight-view.md).
- **Authorization and tenancy are wired, not merely declared.** The engine's own
  writes carry `AshBpmn.Scope.engine/2` — actor, tenant, and a private context
  flag — instead of `authorize?: false` at ninety call sites, and every generated
  resource declares one bypass on `AshBpmn.Checks.AshBpmnInteraction` so the
  engine's authority is visible in the policy set rather than routed around it.
  `AshBpmn.start_instance/2` now honours the `:tenant` option it always
  documented, and background jobs carry the tenant and the BPMN domain in their
  args. Resource macros take `:base`/`:base_opts`, so a human task can inherit a
  host's base resource. See
  [authorization and tenancy](documentation/topics/authorization-and-tenancy.md).
- **In-flight instances can be moved onto a new definition.**
  `AshBpmn.StateExport` writes down what is running, `AshBpmn.Migration.Classifier`
  says per instance whether it can continue, and `AshBpmn.restart_instance/2` acts
  on the `needs_restart` verdict: the old instance moves to `:superseded` — its own
  status, keeping its tokens and events and naming its successor — while a new
  instance of the target definition starts at that definition's start node. Nothing
  about how far the old run had got crosses, deliberately; everything abandoned,
  down to the parked waits nothing will now wake, is written into the process event
  log. See `AshBpmn.Migration.Restart`.
- Six host-instantiated resources for process definitions, instances, tokens,
  human tasks, task candidates and process events.
- A BPMN XML compiler (Common Executable subset) producing an immutable,
  JSON-able graph snapshot with precise compile errors.
- A durable token interpreter: Oban-driven node execution, parallel fork/join,
  exclusive gateways with an `ash` expression language, human tasks with
  materialized candidates and maker-checker exclusion, cancellable timers.
- An embedded bpmn-js designer (LiveView hook + server-rendered config panel)
  and read-only instance viewer.
- A runnable demo application under `dev/` — a real Phoenix server mounting the
  designer and viewer against Postgres — plus the screenshot script
  that produces the images in the documentation.

### Fixes:

- **A receive task's lookback scan delivers only the events the wait
  subscribed to.** The scan read every event in its window and woke the token
  on any whose `match` expression carried the token's key, whatever its
  resource or action, so an earlier event of another action on the same
  record could stand in for the reply. `Correlator.deliver_one/4` now checks
  the event against the token's `subscription_signature` first, as the live
  path's query does: the subscribed resource and action, or any action when
  the subscription names none. A token with no signature is never woken by it.
- **A receive task's lookback scan reads the event source as its contract says.**
  `AshBpmn.EventSource.stream/3` returns `{:ok, {events, last_sequence}}`. The
  scan a token with a `lookback` window makes as it parks treated the answer as
  a bare list and raised on any conforming adapter, so a window never delivered
  an event that came first. The scan now reads the tuple; the test source that
  returned a bare list (and hid it) returns the contract's shape.
- **Parallel joins wait for every incoming branch, however long it is.** A
  join used to look only at its immediate source nodes, and only for `:active`
  and `:executing` tokens. A sibling branch two or more nodes long, or one
  parked (`:waiting`) on a user task, receive task, timer or call activity,
  looked as if it would never arrive: the join fired at the first arrival and
  again when that branch arrived, so the node after the join ran twice, the
  first time early. A join inside a loop also counted every earlier pass's
  arrivals as this pass's. Behaviour change: a join now fires exactly once,
  when no live token can still reach it — none on any node with a path to it
  (boundary events included), none at the join with its advance still to run,
  and no other join upstream still holding arrivals. Each arrival is recorded
  as a `:node_entered` event with `"join" => "arrived"`, and each firing as a
  `:node_completed` event whose `"arrived_token_ids"` names the arrivals it
  used, so each pass through a join uses that pass's arrivals only. A branch
  taken somewhere else after its sibling arrived (an exclusive gateway
  choosing the other path, an error boundary leading to an end) still releases
  the join, now from whichever step took it away. A user task completed
  straight into a join now enters the join like any other node instead of
  judging it by a rule of its own. A join in an instance that is not
  `:running` waits. No schema change.
- **`FlightView.token_positions/2` reads as the actor it is given.** The
  instance and token reads were marked as engine work even with an `:actor`,
  so `AshBpmn.Checks.AshBpmnInteraction` bypassed the host's policies and a
  flight view drawn for a signed-in person showed every instance's tokens.
  With an actor the reads are now that actor's and the host's policies filter
  them. A pinned definition the actor may not read leaves the definition key,
  version and node metadata nil. With no actor nothing changes: the read is the
  engine's own.

- **Concurrent claims: exactly one wins.** `:claim` validated the status of the
  struct it was given and nothing else, so two people claiming one task at once
  both succeeded, and the second overwrote the first's assignee. The claim's
  UPDATE now matches only an `:open` row, and `claim_task/2` writes the claim
  and its `:task_claimed` event in one transaction. `delegate_task/2` writes the
  delegation and its event in one transaction too.
- **Counting `:awaiting_actor` counts the actor's tasks.** The read narrowed
  in a `before_action` hook, which `Ash.count/2`, a page's count and query
  aggregates never run, so they counted every open or claimed task in the
  tenant: a board in the clinic demo showed "Open 288" above one card. The
  candidacy test is now the private `:awaits_actor?` expression calculation,
  which the read's preparation filters on and Ash builds for the actor the
  query runs as.
- **Team candidates can claim.** `claim_task/2` gathered the actor's team ids
  and then matched only `:user` rows; `my_tasks/2` had the same filter.
- **The demo app's migrations match its resources.** `mix dev.setup` failed in
  the seeds on a fresh database (`column b0.parent_instance_id does not
  exist`) and `/instances` returned 500.
- **A failed service task no longer wedges its instance.** The advance job
  claimed the token, the node raised, and nothing handed the claim back: every
  Oban retry found no `:active` token and crashed on it (`BadMapError` /
  `KeyError` on `nil`), and the instance stayed `:running` forever because the
  `max_attempts` check sat behind a claim no retry could make. A node failure
  now releases the token (new `:release` action, attempts kept) so the retry
  claims it; the last attempt -- the engine's `max_attempts` or the job's own,
  whichever comes first -- kills the token, marks the instance `:failed` and
  records `:action_failed` with the node, token, attempts and error. A job
  whose token is gone skips. A retry that finds its own token still
  `:executing` (the node died mid-job) takes it back once the claim is older
  than `config :ash_bpmn, claim_timeout:` (seconds, default 300) and snoozes
  until then; a first attempt finding it `:executing` is a redelivery and
  skips. A failure on the far side of a parallel join hands the new token to a
  job of its own. `AshBpmn.retry_instance/2` now resumes a `:failed` instance
  (new instance `:resume` action), reactivates only the tokens the engine gave
  up on, and gives them a fresh attempt budget.
- **A node step is atomic.** Advancing a token through a node -- the token's
  transition, its successors, the instance's status, the process events, tasks,
  candidates, timer ledger rows and the Oban jobs for the next steps -- now
  commits as one transaction (`AshBpmn.Runtime.Step`), so a crash between two
  of those writes leaves none of them. Oban jobs are inserted inside the
  transaction and dropped with it on rollback, provided the host's Oban uses the
  same repo as the BPMN resources. The host's own work (a service task's action,
  a business rule, an `ash:call`) still runs outside, between the claim and the
  step. Each step takes its instance's row `FOR UPDATE`, so two branches
  finishing at once can no longer each miss the other at a join or an end event.
  The same holds for starting an instance, completing a task, and the timer,
  boundary and catch-timer wakes, whose claim out of `:waiting` is now inside
  the step and rolls back with it. Because a failed step leaves nothing behind,
  a failure applying effects now takes the failed-node path (handed back, then
  `:action_failed`) instead of propagating. The node past a parallel join now
  runs in an advance job of its own instead of inline in the arriving branch's
  job. Inline test mode runs a job a step enqueued once the step commits, as
  production does; flight-view broadcasts are likewise sent after commit. A
  step goes ahead only while its job's claim is still current (status and
  attempt count, re-read under a row lock), so a worker that outlived its claim
  writes nothing and ends `{:ok, :claim_lost}`. `:claim`, `:claim_waiting` and
  `:release` are now compare-and-set in the `UPDATE` itself, so two concurrent
  claims can no longer both win under `READ COMMITTED`.
- **A call activity whose child cannot start no longer leaves its parent
  waiting forever.** The call activity parked its token, then started the child;
  when the start failed the park had already committed, so every retry found
  the token `:waiting` and skipped. The start is now part of the call
  activity's step, so its failure rolls the park back, and it resolves like a
  failed service task: handed back for Oban's retry, and on the last attempt the
  instance `:failed` with an `:action_failed` event naming the call activity and
  why the child could not start. (The subset has no error boundary on a call
  activity to route to instead.)
- **The sweep recovers tokens whose worker died holding the claim.**
  `AshBpmn.Runtime.SweepWorker` looked at `:active` and `:waiting` tokens only,
  so a token whose worker was killed after claiming it stayed `:executing`
  forever. A claim older than `claim_timeout` is now taken back with the new
  token `:recover` action -- a compare-and-set on the status and attempt count
  the sweep read -- recorded as `:sweep_recovered` (`"problem" =>
  "stale_claim"`) and its advance re-enqueued, in one step. The attempt count
  survives, so a node that kills its worker every time still exhausts
  `max_attempts` and fails its instance. A worker that was merely slow cannot
  advance the token twice: its step re-reads the token under a row lock and
  writes nothing unless the attempt count is still the one it claimed at (the
  job ends `{:ok, :claim_lost}`); its host action can run twice, which is why
  `claim_timeout` must exceed the slowest service task.

- Opening the designer writes nothing. It used to create a draft row the moment
  it was opened on a key with no draft, seeded from a starter template whenever
  the scope had nothing published -- so merely viewing a key that a host serves
  from somewhere else (a centrally shipped baseline) left a blank draft over it.
  The draft is now created by the first save, from the XML being saved. The new
  `:baseline` option lets a host say what a key runs when the scope has stored
  nothing for it; the designer shows that read-only, with a Customize button
  wired to the new `:customize` option.
- The starter template (`AshBpmn.Web.DesignerLive.template_xml/1`) carries a
  `bpmndi:BPMNDiagram`. Without one bpmn-js has nothing to draw and reports "no
  diagram to display". The key it is built from is escaped for the attribute
  it lands in.
- A service task or decision whose callee returns a struct no longer crashes
  promotion with `Protocol.UndefinedError`. Results are normalised to plain maps
  before promotion — recursively, leaving `Decimal`/`Date`/`DateTime` alone — and
  `ash:promote` names may be dotted paths (`from="urgent.probability"`), resolved
  through string and then atom keys at each level. Promoting a non-scalar now
  fails with an error naming the node, the path and the value's type, rather than
  raising. The gate is one module, `AshBpmn.Runtime.Promotion`, shared by every
  node kind that promotes; its atom-key fallback also no longer reports an
  output of `false` or `nil` as absent.
- `AshBpmn.Runtime.DomainResolver.resolve!/1` takes the domain a job names.
  Workers used to search the configured domains and take the first with all six
  resource kinds, which in an application with two BPMN domains advanced the
  second domain's instances against the first domain's tables.
- Token consumption reads its table from the resource rather than the literal
  `"bpmn_tokens"`, so the `table:` option every resource macro advertises is
  honoured. On a renamed table it previously updated nothing and surfaced as a
  match error.

### Breaking changes:

- **Cancelling an instance cancels its call-activity children, in one step.**
  `AshBpmn.cancel_instance/2` now runs under the instance's lock as one
  transaction, and cancels every running instance below it in the call tree.
  Before, the children kept running, and a failure part-way left tokens
  killed on an instance still marked `:running`. It takes `:reason`, and the
  `:instance_cancelled` event's data, which was `%{}`, is now
  `%{"cancelled_by_id" => ..., "reason" => ...}` (plus
  `"cascaded_from_instance_id"` on a descendant). An instance that is not
  `:running` is refused before anything is written, where before its live
  tokens were killed and then the refusal returned. `cancel_instance!/2`
  raises the refusal instead of a `MatchError`.
- **`AshBpmn.complete_task/2` and `decide/2` check who is completing.** On an
  open task the actor must be a candidate (a candidate row for them or one of
  their teams, and not excluded); on a claimed task they must hold it. Before,
  anyone passed as `actor:` could decide any task, the requester included. A
  task with no candidate rows can now be decided by nobody through these
  functions. Refusals are `{:error, %ArgumentError{}}` and write nothing.
- **`AshBpmn.delegate_task/2` checks the holder and the delegate.** The actor
  must hold the task, and the delegate must be a candidate (for a `:team`
  delegate, a `:team` row for that team) whom the task does not exclude.
  Before, it checked neither, so delegating was a way around the candidate set,
  maker-checker exclusion included.
- **`HumanTask` gains `excluded_principal_ids`** (`{:array, :uuid}`, not null,
  default `[]`): the principals maker-checker subtracted when the task was
  created, kept so an excluded person cannot act through a candidate team.
  Hosts need the column: run `mix ash.codegen` (or add it by hand,
  `uuid[] NOT NULL DEFAULT '{}'`). Tasks created before have `[]`, which
  means their exclusions were not recorded: on an open or claimed task created
  before the upgrade, a requester who belongs to a candidate team can still
  claim, decide or be delegated their own request. If you have team
  candidates, let those tasks finish before you upgrade, or backfill the
  column for them from your resolver's maker-checker exclusions.
- **`HumanTask`'s `:claim`, `:complete` and `:delegate` actions are
  engine-only.** They refuse any call not made with `AshBpmn.Scope.engine/2`
  (`Ash.Error.Invalid`, "run by the engine"), whatever the host's policies
  allow. They take the assignee and the decider as inputs and check nobody, so
  a policy that let a person run them could get around maker-checker. Call
  `AshBpmn.claim_task/2`, `complete_task/2` and `delegate_task/2` instead.
- **`:complete` and `:delegate` refuse a task whose holder has changed.** Their
  UPDATE also matches on the assignee the action started from, so a completion
  racing a delegation fails once the task has passed to someone else, rather
  than recording the old holder as the decider on the new holder's task.
- **`:claim` and `:delegate` refuse a row that has moved on.** `:claim` now
  re-reads the row and filters its UPDATE on `status = 'open'`, and `:delegate`
  on `status = 'claimed'`; `:complete`, `:cancel` and `:force_complete` filter
  their UPDATE the same way as well as re-reading. A write from a stale struct
  that used to succeed now fails (`Ash.Error.Changes.StaleRecord`, or a "no
  longer open" validation error).
- **`AshBpmn.my_tasks/2` options.** `:principal_ids` is still matched against
  `:user` rows; team ids go in the new `:team_ids` option (matched against
  `:team` rows), or pass `:actor` instead of either. Tasks that exclude any of
  the ids are left out.
- **`AshBpmn.Web.TaskListLive` is removed**, with `AshBpmn.Web.TaskActions` and
  `AshBpmn.Web.DefaultTaskActions`, which existed only to serve it, and the
  stylesheet rules only it used (`.ash-bpmn-page`, `-section`, `-card`,
  `-card__title`, `-overline`, `-heading--lg`, `-form-row`, `-input--sm`). It
  read every task with the engine's authority and claimed, completed and
  delegated through the resource's own update actions with no actor, not
  through `AshBpmn.claim_task/2` and friends: no process event recorded who
  acted, and a completion cancelled no timers and never advanced the token.
  Both reference hosts had already replaced it.
  Present tasks from your own `HumanTask` instead: a candidacy read for the
  lanes, and claim/complete/delegate actions run as the person, calling
  `AshBpmn.claim_task/2`, `complete_task/2` and `delegate_task/2`. ash_bpmn
  takes no UI dependency for this. See
  [presenting tasks to people](documentation/topics/assignment-and-maker-checker.md#presenting-tasks-to-people)
  for the pattern and the checks the engine leaves to the host.
- `cancel_instance/1`, `cancel_instance!/1`, `retry_instance/1`,
  `retry_instance!/1` and `instance_report/1` take an options keyword as a second
  argument, for `:actor` and `:tenant`. Nothing has been released, so these
  change outright rather than growing a compatibility shim.
