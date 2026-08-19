<!--
SPDX-FileCopyrightText: 2026 Luke Galea
SPDX-License-Identifier: MIT
-->

# What it refuses

A library's promises are only as good as its refusals. These are ash_bpmn's,
so that nobody has to rediscover them in a design review.

## Refused at compile time

The compiler rejects, each with the offending element's id in the error:

- **Anything outside the executable subset.** Of BPMN 2.0's 244
  collaboration-relevant element variants, exactly six appear in more than half
  of 39,695 real-world models surveyed (Compagnucci et al., *BISE* 66(1), 2023):
  sequence flow, end event, start event, task, pool, lane — and the Common
  Executable conformance class is barely larger. ash_bpmn executes that subset:
  start/end events, user/service tasks, exclusive and parallel gateways,
  conditional and default flows. Call activities, ad-hoc and transactional
  sub-processes, the event taxonomy beyond plain start/end, complex and
  event-based gateways, compensation and loop markers: rejected, loudly. A
  notation element a business analyst drew and a system silently ignored is how
  the diagram and the system end up being about different processes.
- **Multiple start events, zero end events, dangling flows, unreachable nodes,
  nodes that cannot reach an end.** The interpreter's smallness depends on the
  graph being total.
- **Exclusive gateways without a decisive structure** — either a declared
  default flow or every outgoing branch conditioned.
- **Mixed parallel gateways** (forking *and* joining) — the token topology these
  create is where join deadlocks are born, and the honest answer is a separate
  fork node and join node, which the subset already provides.
- **Malformed `ash:` bindings** — unknown attributes or elements in the ash
  namespace, user tasks without candidates or outcomes, service tasks without an
  action reference, unparseable conditions. Typo protection: a `candiates`
  element that vanished silently would be indistinguishable from an unassigned
  task until nobody's task list showed it.
- **Non-executable processes** (`isExecutable="false"`).

## Refused at design time

- **A code DSL for processes.** There is no Elixir process DSL and there will
  not be one. The moment two artifacts describe one process, every edit needs
  conflict resolution and the conflicts arrive at the worst time. BPMN XML is
  the single artifact; the graph snapshot is derived, immutable, versioned.
- **Business logic in the graph.** Gateway conditions may route on subject data;
  they may not *enforce* anything. An invariant in a condition is enforced for
  process callers and bypassed by every other caller — the controller-layer
  authorization mistake in a new costume. Decisions, validations and
  authorization live in Ash actions; the graph orchestrates calls to them.
- **Business data in tokens.** Tokens carry node ids and status. Reading the
  subject fresh through Ash at execution time is what keeps the process from
  becoming a second source of truth about the domain.
- **`forbid_if` for maker-checker.** Subtraction belongs in candidate
  construction, not policy evaluation. See
  [assignment and maker-checker](assignment-and-maker-checker.md).
- **Automatic in-flight migration.** Instances finish on their pinned version.
  Redesigning a process while three hundred instances run is exactly the moment
  "we'll just move them to the new graph" is most tempting and most wrong —
  identical node names with changed semantics is the dangerous case, and
  proving graph equivalence is not a check worth automating when the honest
  alternative (drain on the old version) is free.
- **Compensation across nodes** (for now). Cross-node undo is a genuinely hard
  problem with semantics no library should guess at; it is deliberately absent
  rather than half-present. Within a single node, your action — or the Reactor
  it wraps — owns its own compensation.
- **BPMN conformance, and interchange with foreign engines.** Conformance serves
  interchange; we do not interchange. The XML out is the XML in, edited by
  bpmn-js.
- **Message events and external correlation.** Phase 3, if a use case earns it.
- **Lanes.** Lanes are presentation, not execution semantics — an expensive
  misunderstanding the corpus data already prices for you.
- **A second runtime.** No JVM, no gRPC bridge, no engine beside the app. The
  commercial licence changes that made the incumbent engines non-options are
  documented in the source plan; owning the small subset we actually execute was
  cheaper than the bridge alone would have been.

## Refused in the decision seam

- **A decision reference inside a gateway condition.** It looks like a small
  convenience and it is not one. A `conditionExpression` is evaluated in-process
  and is pure; dereferencing a decision there puts a database read, a possible
  failure and a possible timeout inside the one code path that has none of them,
  and it puts the decision back *inside* the graph, which is the line this package
  exists to hold. The BPMN and DMN specifications agree, and so does the
  composition that replaces it: a business rule task promotes a signal and the
  gateway reads `routing.<name>` in ordinary FEEL. One more box on the diagram, and
  the decision is visible on it rather than hidden in a condition.
- **A rule table in the diagram.** The graph carries a decision *reference*. What a
  decision is, where it lives, how it is versioned and who may change it belong to
  the host's `AshBpmn.DecisionResolver`. A rule expressed in the graph is a rule
  every non-process caller bypasses.
- **Promoting anything but declared scalars.** Only signals named in `ash:promote`
  reach the token, each must be a scalar, and names and values are length-bounded.
  A decision's full output goes to the host's own record and to a
  `:decision_evaluated` event. This is what keeps "tokens carry routing, not
  business data" a checkable property rather than a request — a free-form map on
  the token is precisely how that rule erodes.
- **`binding="pinned"` without a version.** It reads as "this will not move under
  me" and would behave as "latest". Refusing it is cheaper than explaining it after
  an incident.

## Refused in the editor

- **Hiding the bpmn.io watermark.** Licence, not styling. See
  [the designer](the-designer.md#the-watermark).
- **Two-way sync with anything.** The designer edits the artifact. The compiler
  reads it. One way, always.
