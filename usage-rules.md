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
9. **Expressions are data.** Gateway conditions use `AshBpmn.Expr` (parsed at
   compile time, stored in the snapshot, JSON-able). Missing paths compare false.
   Do not invent a second expression language in gateway conditions or resolvers.
10. **Actions are idempotent under redelivery.** Node execution may run twice
    (Oban redelivery). The token claim gate makes double-advance safe; your
    `ActionInvoker` callbacks must tolerate a second invocation.
11. **Engine calls go through `AshBpmn.Scope`, never `authorize?: false`.** Every
    internal call passes `AshBpmn.Scope.engine/2`, which carries the actor and the
    tenant and marks the call for the bypass each generated resource declares on
    `AshBpmn.Checks.AshBpmnInteraction`. There is exactly one exception —
    `AshBpmn.Scope.subject/2`, for reading the *host's* subject, which no ash_bpmn
    policy governs — and a test fails the build if a second one appears.
12. **Pass the tenant, and pass it explicitly.** `AshBpmn.start_instance/2` takes
    `:tenant`; operations on a record already loaded infer it from that record.
    Background jobs carry the tenant and the domain in their args, because a job
    outlives the process that enqueued it and has nothing else to read them from.
13. **A work item can sit on your base resource.** Every resource macro takes
    `:base` and `:base_opts`, so a human task inherits whatever your application
    arranged for every other record it owns. One ordering rule comes with it: a
    bypass in Ash short-circuits only the policies declared *after* it, and a base
    resource's policies are emitted first — so either put
    `AshBpmn.Checks.AshBpmnInteraction` at the top of the base's policy set or set
    `config :ash_bpmn, engine_actor:`. See `AshBpmn.Config.engine_actor/0`.

## Testing

- Engine tests run against real Postgres with the Oban shim in `:inline` mode
  (`config :ash_bpmn, oban_testing: :inline`): advance jobs execute synchronously;
  timers are stored, never fire themselves — fire them explicitly with
  `AshBpmn.Runtime.Oban.TestJobs.fire!/2`.
- Approve the negative paths: expiry, cancellation, lost claim races, join
  starvation, instance failure after max attempts. A process suite that only tests
  the happy path is testing a distributed system for the absence of its defining
  property.
