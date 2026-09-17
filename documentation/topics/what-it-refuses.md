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
  start events, end events — including terminate end events — user, service,
  send and business rule tasks, intermediate catch events carrying a timer,
  timer boundary events on user tasks, interrupting or not, message catch
  events, conditional catch events, signal
  throw and catch events, error end events, exclusive and parallel gateways,
  conditional and default flows. Call activities, ad-hoc and
  transactional sub-processes, throw events,
  the rest of the event-definition taxonomy (message on anything but an
  intermediate catch event, signal on anything but an intermediate throw or
  catch, conditional on anything but an intermediate catch, error on anything
  but an end event,
  escalation, conditional, compensation, cancel, link), complex and
  event-based gateways, loop and multi-instance markers: rejected, loudly. A
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
- **An event definition on a node type it is not supported on** — a
  `timerEventDefinition` anywhere but an intermediate catch event or a
  boundary event, a
  `terminateEventDefinition` anywhere but an end event. Accepting it would let a
  diagram carry a marker the engine ignores, executing the node as though it
  were not drawn — the silent-divergence failure the unsupported-element check
  exists to prevent, arriving through the door marked "supported". The error
  says where the definition *is* supported rather than ruling on whether the
  drawing is legal BPMN: a timer start event is perfectly good BPMN this engine
  does not implement, a terminate marker on a start event is not BPMN at all,
  and the compiler has no business pretending to tell them apart.
- **A catch event with nothing to catch** — an `intermediateCatchEvent` with no
  event definition, or with more than one. The first parks a token that nothing
  will ever wake: a deadlock, compiled and published. The compiler will not ship
  a hang it can see in the document.
- **Timer cycles and absolute dates** (`timeCycle`, `timeDate`). A catch event's
  delay is `timeDuration` and nothing else. Both are named in the error rather
  than falling through as unrecognized elements, because a modeller who drew a
  cycle needs to be told that *cycles* are not supported, not that BPMN contains
  no such element. Neither has an honest single-shot reading to approximate to: a
  cycle says the node fires repeatedly and the nearest approximation fires once,
  and an absolute date on a definition published months before the token arrives
  is a deadline that may already be in the past. A timer that means something
  other than what the diagram says is worse than one that will not compile.
- **ISO 8601 durations measured in months or years.** `P1M` and `P1Y` are legal
  ISO 8601 and are rejected anyway, because their length depends on when you
  start counting: two instances that park a day apart fire a day and a bit apart,
  and neither the diagram nor the event log says why. A modeller who wants a
  month writes `P30D` and means it. A duration of zero is refused on the same
  principle — a timer that waits for no time is a node drawn to do something it
  does not do.
- **Boundary events on anything but a user task.** Both interrupting and
  non-interrupting boundaries are supported; the attachment is what is
  restricted. A service task's token is
  executing inside a running job. Oban cannot interrupt a running job and an Ash
  action that has already committed cannot be un-run — that is compensation,
  which this library refuses outright. "Interrupting" such an activity would
  mean killing the token while the work carried on, which is a lie the diagram
  would be telling on the engine's behalf. Also refused: a boundary attached to
  an id that is not in the process, one with an incoming sequence flow (a
  boundary is entered by its activity being interrupted, never by a flow), and
  one with zero or several outgoing flows — zero is an interruption with nowhere
  to go, and several make the boundary an implicit gateway whose branch is
  chosen by flow-id sort order.
- **A user task carrying both an `ash:timer kind="expire"` and an interrupting
  timer boundary.** Both answer "what happens when this runs out of time" and
  they route to different places: expire leaves down the task's own flow with
  `outcome: :expired` for a following gateway to read, the boundary leaves down
  its own flow with no outcome at all. Whichever fired first would win, and
  neither can be silently preferred over the other, so carrying both is refused
  rather than resolved.
- **Error *boundary* events**, while error *end* events are supported. Catching
  requires telling a modelled business error apart from an infrastructure
  failure, and `ActionInvoker.invoke/2` returns `{:error, term()}` with no error
  code — so nothing distinguishes "the applicant was declined" from "Postgres is
  unreachable". A catch would route a transient outage down the declined branch
  and the process would end having decided something nobody decided. Also
  refused: an error thrown with no `errorRef`, since an anonymous error tells
  nothing downstream which error was thrown; an `errorRef` with no matching
  `bpmn:error` declaration beside the process; and an end event carrying both a
  terminate and an error marker, which are two different endings where one would
  be ignored.
- **Promoting `ash:timer kind="expire"` into a boundary event automatically.**
  The roadmap proposed it and it cannot be done wholesale: `RequireApproval`
  schedules expire timers for standalone approvals, which have no process
  instance and no graph to draw a boundary on, so expire has to survive
  regardless. Where a graph does exist, rewriting would change routing
  silently — expire leaves down the task's own flow with `outcome: :expired`
  for a following gateway to read, a boundary leaves down its own flow with no
  outcome — so the same picture would mean something different after an
  upgrade. The two are made mutually exclusive on a user task instead.
- **Event sub-processes**, and this one is a deferral with a date rather than a
  principled refusal. An event sub-process is a scoped set of catch events with
  a body — very nearly a boundary event attached to the whole process, on
  machinery that now exists. What is missing is nesting: the node collector
  gathers every supported element by `//` descendant search, so a sub-process's
  children are hoisted and compiled as though they sat at process level with the
  boundary erased. Supporting containers properly means scoping collection,
  giving the graph a notion of scope, teaching reachability about it, and
  letting the runtime spawn a token into one — together, not in slices. The
  half version, built on the collector as it is, would silently erase the
  sub-process boundary, which is precisely the defect the bare-name refusal
  exists to prevent; reintroducing it deliberately to claim the feature would be
  worse than not having it.
- **A conditional catch with no condition, or none naming the resource it
  watches.** The first would park a token waiting for nothing to become true.
  The second is refused even though the subject's type is known at run time,
  because the correlator has to *find* parked tokens before it loads anything —
  the declared resource is what makes that a partial-index lookup instead of
  evaluating every parked condition against every write in the system.
- **A signal event with no `signalRef`, or a ref with no declaration.** A catch
  with no name would hear every signal thrown anywhere, which is not listening.
  A `bpmn:signal` is declared beside the process, like `bpmn:error`, and the
  *name* on that declaration is what travels — a catch in another diagram has
  its own declaration with its own id, so only the names can agree. A
  declaration with no name is refused for the same reason.
- **A message catch that does not say what it is waiting for.** A
  `messageEventDefinition` says only *that* the token waits; the `ash:subscribe`
  element says what for, because BPMN's own message plumbing describes messages
  between pools and has nothing to say about an Ash resource and action. Refused
  without one, and refused without both a `correlate` and a `match` expression:
  without them every event of that kind would wake every token waiting for one,
  which is not correlation, it is a broadcast. A `correlate` that answers null
  is also refused at run time rather than parked, because a null key matches
  every other null key — the token would have no address.
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
- **An `ash:load` that loads nothing** — one declaring no `ash:path`, or a path
  with no name. Loading is otherwise strict and stays that way: a node declares
  what its expressions need on the subject, and a path it did not declare reads
  as `null`, exactly as it would have without the feature. That is deliberate.
  The alternative — loading whatever any node asked for — would make a
  condition's answer depend on which other nodes happened to be in the diagram.
- **Business data in tokens.** A token carries node ids, status, the scalars a
  node explicitly promoted for routing, and — while parked — what it is
  listening for. Never what the subject said. Reading the subject fresh through
  Ash at execution time is what keeps the process from becoming a second source
  of truth about the domain.
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
