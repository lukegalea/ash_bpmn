<!--
SPDX-FileCopyrightText: 2026 Luke Galea
SPDX-License-Identifier: MIT
-->

# Change Log

All notable changes to this project will be documented in this file.
See [Conventional Commits](https://conventionalcommits.org) for commit guidelines.

<!-- changelog -->

## [Unreleased]

Nothing has been released yet. Everything below is the initial body of work.

### Features:

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
  designer, viewer and task list against Postgres — plus the screenshot script
  that produces the images in the documentation.

### Fixes:

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

- `cancel_instance/1`, `cancel_instance!/1`, `retry_instance/1`,
  `retry_instance!/1` and `instance_report/1` take an options keyword as a second
  argument, for `:actor` and `:tenant`. Nothing has been released, so these
  change outright rather than growing a compatibility shim.
