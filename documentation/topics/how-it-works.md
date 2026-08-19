<!--
SPDX-FileCopyrightText: 2026 Luke Galea
SPDX-License-Identifier: MIT
-->

# How it works

ash_bpmn is one artifact, one compilation, one interpreter, and one set of human
work primitives shared by two layers. This page is the tour.

## One artifact

A process is a BPMN 2.0 XML document with Ash bindings in an `ash:` extension
namespace. That document is the only source of truth. The visual designer edits
it; the compiler verifies it; nothing ever edits it on the compiler's behalf, and
nothing round-trips.

This is a deliberate resolution to the oldest argument in process modelling.
Bidirectional sync between a diagram and code fails structurally — the two models
are not the same model, so every edit needs conflict resolution at the worst
time. Systems that genuinely achieve text-and-diagram duality (Umple, JetBrains
MPS, Blockly) do it by having **one artifact with multiple projections**, never
two artifacts with a sync step. BPMN XML with extension elements is exactly that:
the diagram and the bindings live in one document, and bpmn-js edits both.

## One compilation

Publishing a definition runs `AshBpmn.Compiler.compile/1`:

```
BPMN XML ──parse──> elements ──verify──> errors (fix in the designer)
                                │
                                └──build──> graph snapshot (JSON-able map)
```

The snapshot holds nodes, flows, gateway conditions (as FEEL source text — see
`AshBpmn.Feel` for why text rather than a parsed tree), join definitions,
candidate/exclusion/timer specs, and the instance outcome of each end event. It is stored on the definition row, which is
**immutable once published**.

Verification is why the runtime can be small. Exactly one start event; every node
reachable; every path terminates; exclusive gateways have a default or fully
conditioned branches; parallel gateways fork *or* join, never both; user tasks
declare candidates and outcomes; service tasks declare an action reference;
anything outside the executable subset is rejected with its element id. A diagram
that compiles is a diagram the interpreter cannot get lost in.

Versioning follows from immutability: publishing when version N exists creates
version N+1. A running instance pins the `definition_id` it started with and
finishes on it, even after later versions ship, even after the process is
redesigned, even after the old version is retired. You never migrate in-flight
instances automatically — an explicit, declared migration is a future escape
hatch, not a default (see [what it refuses](what-it-refuses.md)).

## One interpreter

Execution is a token machine, and the durability comes from Postgres and Oban —
the only things in an Ash stack that survive a deploy.

- An **instance** starts with one active **token** at the start node.
- Every token advance is one Oban job. The job claims the token (optimistic
  compare-and-set; the loser of a race is a no-op), loads the *snapshot* — never a
  module — executes the node, and writes the next token(s) in one transaction.
- A **fork** mints sibling tokens sharing a `fork_id`. A **join** consumes
  arrivals and fires once all waited-for branches have arrived.
- A **service task** calls your `ActionInvoker` callback with
  `action`, subject, actor and tenant. It orchestrates; your Ash action decides,
  validates and authorizes.
- A **user task** creates a `HumanTask` plus materialized `TaskCandidate` rows and
  attaches remind/escalate/expire timers as Oban jobs. The token parks at
  `:executing` until someone decides.
- **Completion** (claim → decide, or timer expiry) cancels the remaining timers,
  records the outcome as engine assigns, and advances the token through the
  outgoing gateway with `task.outcome` available to conditions.

Failure semantics are boring on purpose: a node error retries with Oban backoff
until `max_attempts`, then the instance is marked `:failed` and the event log says
which node and why. A reconciliation sweep re-enqueues advances for tokens whose
jobs were lost — the safety net, not the primary driver.

## One set of human-work primitives

The approval layer and the `userTask` node are the same machinery. A standalone
approval (`AshBpmn.Changes.RequireApproval`) is a `HumanTask` with no instance and
no token: candidates resolved and materialized at creation, maker-checker applied
by subtraction during resolution, timers attached, decisions audited, and an
optional `on_complete` action fired through the same invoker the graph uses.
A partial unique index `(subject_type, subject_id, node_id) where status in
(open, claimed)` makes "requires approval before it takes effect" a database
constraint rather than a hopeful check.

See [assignment and maker-checker](assignment-and-maker-checker.md) for the
candidate model and [running processes](running-processes.md) for the worker,
timer and sweep mechanics.
