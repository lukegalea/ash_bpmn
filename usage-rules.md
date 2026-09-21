<!--
SPDX-FileCopyrightText: 2026 Luke Galea
SPDX-License-Identifier: MIT
-->

# ash_bpmn usage rules

_Rules for working with the ash_bpmn library, for humans and agents alike._

## The two layers

ash_bpmn ships an approval layer (`AshBpmn.Changes.RequireApproval`, human tasks,
candidates, timers) and a process layer (BPMN definitions, instances, tokens, the
interpreter). The approval layer stands alone — never require a process graph where
a single gate on an action will do. Most approval requests are single-gate
requests; reach for the designer only when routing, parallelism or joins exist.

## The architectural line

> **The process graph orchestrates. It never decides, never validates, and never
> authorizes.**

Every node resolves to a host callback (`AshBpmn.ActionInvoker` for service tasks,
your Ash actions for mutations). If a process definition contains a business
invariant, that invariant is now enforced in one place and bypassed by every other
caller. Business rules belong in Ash actions, changes and validations — never in
gateway conditions, never in resolver specs, never in the invoker.

## Rules

1. **Never `forbid_if` for maker-checker.** Segregation of duties is expressed as
   `excluding:` on the approval/task config, applied when candidates are resolved.
   The subtraction happens in data construction, not policy evaluation.
2. **Candidates are rows.** Human task candidate lists are materialized into
   `TaskCandidate` rows at task creation. Task lists are one indexed query joined
   on principal ids. Do not add per-row policy evaluation on top.
3. **BPMN XML is the single artifact.** There is no code DSL for processes and
   there will not be one. Do not generate XML from code, do not parse the graph
   back into domain structures, do not keep a second copy of the process anywhere.
   Edit in the designer (or in the XML), publish, done.
4. **Definitions are immutable and versioned.** `publish` is one-way. Instances pin
   their definition for life; never migrate in-flight instances automatically.
   A changed process is a new version (or a new key if token topology changes).
5. **Tokens carry routing, not business data.** A token row holds node ids and
   status. Everything else is read from the subject through Ash at execution time.
6. **Timers must be cancellable.** Task completion cancels the task's outstanding
   timer jobs. If you add a new completion path, cancel the timers — an escalation
   email for a task approved four days ago is the canonical incident.
7. **The interpreter reads the snapshot, never a module.** The engine loads
   `definition.graph`. Do not introduce compile-time module references into
   execution paths.
8. **Keep the bpmn.io watermark.** The embedded bpmn-js designer renders a
   "Powered by bpmn.io" logo. The bpmn.io licence requires it to stay visible and
   unmodified. Do not hide, move or restyle it.
9. **Conditions are FEEL, and there is only one expression language.** Gateway
   conditions are FEEL — the DMN expression language — validated at publish time and
   stored in the snapshot as **source text**, not as a parsed tree, so an in-flight
   instance keeps evaluating across engine upgrades. Equality is `=`, not `==`.
   A missing path under an ordering comparison is `null`, not `false`, and a gateway
   records it as a `:condition_null` event; a missing path under `=` is plain `false`
   and is *not* recorded — that asymmetry is FEEL to spec and is a real diagnostic gap
   worth knowing about. Go through `AshBpmn.Feel` and never call the engine directly,
   and in particular put every context value through `AshBpmn.Feel.to_feel_value/2`:
   FEEL numbers are decimal, so a plain Elixir integer in the context makes every
   numeric comparison a type error, which becomes `null`, which becomes a silently
   wrong branch.
10. **A business rule task asks; it never decides.** `businessRuleTask` resolves to
    the host's `AshBpmn.DecisionResolver`, the third seam beside `ActionInvoker` and
    `AssignmentResolver`. The graph carries a decision *reference*, declared FEEL
    inputs, and the named scalar signals to promote onto the token -- and nothing
    else. Never put a rule table in the diagram: a rule in the graph is a rule every
    other caller bypasses, which is the defect the architectural line exists to
    prevent. The reference is verified at publish time, so a diagram cannot ship
    against a decision that does not exist.
11. **A gateway condition is FEEL, never a decision reference.** The composition is
    business rule task -> promote a signal -> gateway reads `routing.<name>`. A
    gateway that dereferenced a decision would do I/O inside a code path that is
    otherwise pure and in-process, and would put the decision back inside the graph.
12. **One binding vocabulary for every call a node makes.** Declared FEEL inputs
    (`ash:inputs`) and promoted signals (`ash:promote`) mean the same thing on a
    `businessRuleTask`, a `serviceTask` and a `sendTask`, and are extracted,
    validated and gated by the same code on all three: inputs are evaluated with
    FEEL against `subject`/`task`/`routing`/`assigns`, and only declared scalars
    reach the token. A `sendTask` is a `serviceTask` with a different icon --
    same config, same dispatch. Do not fork the shapes per node kind, and do not
    add a second way to hand a callee its arguments.
13. **The catalogue is the allowlist.** The designer's decision and action
    catalogues come from the host, as code (`AshBpmn.Catalogue.AshActions` is one
    way to build them). They make authoring honest -- a select, not a guess --
    but they are not the runtime source of truth: the XML is, and invoking is
    still the only contract. When the host's `ActionInvoker` exports
    `exists?(ref) :: boolean`, the compiler verifies every service/send action at
    publish time, the same promise the decision resolver's `exists?/1` makes; a
    catalogue crash degrades the *panel* to free text, never the engine.
14. **Actions are idempotent under redelivery.** Node execution may run twice
    (Oban redelivery). The token claim gate makes double-advance safe; your
    `ActionInvoker` callbacks must tolerate a second invocation.
15. **Engine calls go through `AshBpmn.Scope`, never `authorize?: false`.** Every
    internal call passes `AshBpmn.Scope.engine/2`, which carries the actor and the
    tenant and marks the call for the bypass each generated resource declares on
    `AshBpmn.Checks.AshBpmnInteraction`. There is exactly one exception —
    `AshBpmn.Scope.subject/2`, for reading the *host's* subject, which no ash_bpmn
    policy governs — and a test fails the build if a second one appears.
16. **Pass the tenant, and pass it explicitly.** `AshBpmn.start_instance/2` takes
    `:tenant`; operations on a record already loaded infer it from that record.
    Background jobs carry the tenant and the domain in their args, because a job
    outlives the process that enqueued it and has nothing else to read them from.
17. **A work item can sit on your base resource.** Every resource macro takes
    `:base` and `:base_opts`, so a human task inherits whatever your application
    arranged for every other record it owns. One ordering rule comes with it: a
    bypass in Ash short-circuits only the policies declared *after* it, and a base
    resource's policies are emitted first — so either put
    `AshBpmn.Checks.AshBpmnInteraction` at the top of the base's policy set or set
    `config :ash_bpmn, engine_actor:`. See `AshBpmn.Config.engine_actor/0`.

18. **Ask the export, not the tables, what is in flight.** `AshBpmn.StateExport.export/2`
    produces a stable JSON document of every live instance, its tokens, what each
    parked token is listening for, and a digest of the DSL element it is standing on.
    It is digest-only by construction: routing values and correlation keys are
    hashed, never emitted, so the document is safe to store, send and keep. The reads
    behind it are ordinary actions — `:in_flight` on the instance and token resources
    — so narrow it with arguments rather than by querying the tables.
19. **Classify before you migrate in-flight instances.** An instance pins its
    definition version for life, so publishing a new one changes nothing until
    somebody moves the running instances onto it.
    `AshBpmn.Migration.Classifier.classify/3` takes an export and the target
    definitions and answers, per instance, `safe_to_continue`, `needs_restart`,
    `needs_manual_attention` or `unknown` — the last with the reason attached. Treat
    `unknown` as work to do, not as a pass: it means the artefacts did not decide,
    and the two common causes (a target that was not supplied, a FEEL engine change
    under a conditional gateway) are both real.
20. **A restart supersedes; it does not resume.** `AshBpmn.restart_instance/2` is
    what a `needs_restart` verdict is for. The old instance moves to `:superseded` —
    its own status, not `:cancelled` — keeps its tokens and events, and gains
    `superseded_by_instance_id`; a new instance of the target starts at that
    definition's start node. **Nothing about how far the old run had got crosses**,
    and not for want of trying: carrying the tokens the classifier called safe would
    produce a marking the target can never reach by running, which is the process
    running twice in a sequential diagram and a starved join in a parallel one. What
    crosses is identity — subject, correlation id, accountability, the parent link,
    and `trigger_depth`, which is carried rather than reset because it is the bound
    that stops a subscription cycle. Everything abandoned is written into an
    `:instance_restarted` event on the successor and an `:instance_superseded` event
    on the predecessor, per token, including the parked waits that nothing will now
    wake and the call-activity children left with nobody to return to. Read that
    record; it is the only place those say anything.

## Testing

- Engine tests run against real Postgres with the Oban shim in `:inline` mode
  (`config :ash_bpmn, oban_testing: :inline`): advance jobs execute synchronously;
  timers are stored, never fire themselves — fire them explicitly with
  `AshBpmn.Runtime.Oban.TestJobs.fire!/2`.
- Approve the negative paths: expiry, cancellation, lost claim races, join
  starvation, instance failure after max attempts. A process suite that only tests
  the happy path is testing a distributed system for the absence of its defining
  property.

## The iron laws and the judge

Agent work here is also governed by the **26 Iron Laws** — adapted from the
phxagents project (phxagents.dev/iron-laws, MIT), codified in the
`ash_agent_tools` package with a deterministic judge (`mix ash_agent.laws`).
This package adds **no dependency** for that: run the judge from any checkout
that has it, or judge a snippet in-VM with `AshAgentTools.judge_laws/1`.

    mix ash_agent.laws                            # the law registry as JSON
    mix ash_agent.laws FILE [FILE...]             # judge files
    mix ash_agent.laws --code 'SNIPPET'           # judge a snippet
    git diff main | mix ash_agent.laws - --diff   # judge only added lines

The laws with the most teeth *for this codebase*:

- **#7 — jobs are idempotent.** The engine's workers run at-least-once
  (`advance` allows ten attempts; the timers allow three). Double-advance is
  made safe by the token claim gate (rule 14), not by job uniqueness — the
  runtime workers deliberately declare no `unique:` because a uniqueness window
  would suppress a legitimate redelivery, and the trigger sweeps declare
  uniqueness at the insert site instead. Do not "fix" the missing `unique:` on
  a runtime worker. And remember the inline test shim reads `unique:` differently
  from production (`AshBpmn.Runtime.Oban`).
- **#8 — Oban args are string-keyed.** Job args serialize through JSON, so a
  worker reads `args["instance_id"]`, `args["tenant"]`, `args["kind"]`. An
  atom-keyed read matches nothing and fails silently, and the failure is a
  parked token, not an error. This is also why a timer kind arriving from args
  is mapped explicitly rather than through `String.to_existing_atom/1`.
- **#9 — store IDs, not structs.** Job args carry `instance_id` and
  `token_id`; the worker re-reads the rows through Ash under
  `AshBpmn.Scope.from_job/2`. Freezing state at enqueue time is wrong here by
  more than the usual staleness: between enqueue and run the instance may have
  been superseded (rule 20), and the only honest move is to read it fresh and
  fail the claim.
- **#10 — no `String.to_atom` on anything a diagram or a form can produce.**
  This is a scar, not a style preference: the bespoke expression engine this
  package deleted called `String.to_atom/1` on FEEL path segments from
  tenant-authored XML, and task outcomes were stored as atoms until a
  completed task could not be read back — which is why they are strings now.
  Runtime names resolve through `String.to_existing_atom/1` (subject,
  subscription, interpreter, domain resolver) or fixed allow-lists. A new
  conversion of a diagram- or form-derived string to a fresh atom is a bug.
- **#20 — wrap third-party surfaces once.** FEEL goes through `AshBpmn.Feel`
  and nowhere else (rule 9); the bpmn-js designer is embedded in one module;
  Oban is reached through `AshBpmn.Runtime.Oban` so the inline test shim and
  production share one seam. A second call site is where the decimal-number
  rule and the watermark get forgotten.
- **#22 — verify before claiming done.** Compile, run the suite against real
  Postgres with the inline Oban shim, and show the output — on the negative
  paths, per Testing above: expiry, cancellation, lost claim races, join
  starvation.
