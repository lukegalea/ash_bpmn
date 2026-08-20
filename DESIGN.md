# ash_bpmn — design contract

<!--
SPDX-FileCopyrightText: 2026 Luke Galea
SPDX-License-Identifier: MIT
-->

This file is the **binding contract** between the implementation lanes. Where code and
this file disagree, this file wins until it is amended. It exists so four people (or
agents) can build separate modules that meet exactly.

Source plan: `ash_enterprise/docs/plans/business-process-modelling.md` (Option C —
BPMN-*inspired* declarative process engine over Ash/Postgres/Oban). The one deviation,
made deliberately: **the BPMN XML document is the single source-of-truth artifact**,
edited by an embedded [bpmn-js](https://github.com/bpmn-io/bpmn-js) designer with an
`ash:` extension namespace for Ash bindings. The DSL-vs-diagram round-tripping problem
the plan bans (§8) does not arise, because there is no second artifact: the compiled
graph is a *derived, immutable, versioned snapshot* (plan §7), regenerated only by
publishing a new definition version. One artifact, one-way compilation, ever.

> **The architectural line (plan §5.3): the process graph orchestrates. It never
> decides, never validates, and never authorizes.** Every node resolves to a host
> callback; every mutation goes through ordinary Ash actions with policies.

---

## 1. Shape of the package

`ash_bpmn` is a library (Hex-style layout, like `ash_strangler`) providing:

| Piece | Modules |
|---|---|
| Process data model | six resource macros the **host app instantiates** (`AshBpmn.Resources.*`) |
| BPMN compiler | `AshBpmn.Compiler`, `AshBpmn.Feel` — XML → verified graph snapshot |
| Runtime engine | `AshBpmn` (facade), `AshBpmn.Runtime.*` — token interpreter over Oban |
| Web designer | `AshBpmn.Web.*` LiveViews + `priv/js/ash_bpmn_designer.js` hook |
| Host extension points | `AshBpmn.AssignmentResolver`, `AshBpmn.ActionInvoker` behaviours |

### 1.1 Supported BPMN subset (Common Executable, plan §2)

`startEvent`, `endEvent`, `userTask`, `serviceTask`, `exclusiveGateway`,
`parallelGateway` (fork and join), `sequenceFlow` with `conditionExpression`.
Everything else is rejected at compile time with a precise error. No conformance
claims, ever.

---

## 2. Host integration (the contract Lane A implements, Lane E consumes)

### 2.1 Resource instantiation (ash_events pattern)

The host declares its own modules; each macro builds the entire resource:

```elixir
defmodule MyApp.Bpmn.Definition do
  use AshBpmn.Resources.Definition,
    domain: MyApp.Bpmn,
    repo: MyApp.Repo,
    tenant?: false,          # default false; enterprise passes true (adds organization_id + attribute multitenancy)
    table: "bpmn_definitions" # default shown; one per macro
end
```

Six macros, tables, and the persisted marker each sets:

| Macro | Default table | `@ash_bpmn_kind` |
|---|---|---|
| `AshBpmn.Resources.Definition` | `bpmn_definitions` | `:definition` |
| `AshBpmn.Resources.Instance` | `bpmn_instances` | `:instance` |
| `AshBpmn.Resources.Token` | `bpmn_tokens` | `:token` |
| `AshBpmn.Resources.HumanTask` | `bpmn_human_tasks` | `:human_task` |
| `AshBpmn.Resources.TaskCandidate` | `bpmn_task_candidates` | `:task_candidate` |
| `AshBpmn.Resources.ProcessEvent` | `bpmn_process_events` | `:process_event` |

The marker is set via `persisted` in each macro (`Spark.Dsl.Extension.set_persisted`?
No — inside a `use Ash.Resource` body you cannot. **Use module attribute registration:
each macro generates a zero-arg function `ash_bpmn_kind/0` returning the atom.**)
`AshBpmn.Resources.kind/1` sniffs a loaded module by calling that function, rescuing
ArgumentError → `:not_bpmn`.

`AshBpmn.Resources.for_domain/1` — `Ash.Domain.Info.resources/1` filtered by kind,
returns `{:ok, %{definition: m, instance: m, token: m, human_task: m,
task_candidate: m, process_event: m}}` or `{:error, :missing_resources, [kinds]}`.

The macro accepts an optional `do` block, injected verbatim after the generated body
(hosts add policies there, e.g. enterprise does `use AshEnterprise.Security.Policies`).
If the host supplies no policies, the macro generates **nothing** — an authorizer with
no policies denies all, which is the safe default; hosts opt in explicitly. Tests and
enterprise pass their policy sets.

### 2.2 Schemas (exact attributes)

All resources: `uuid_primary_key :id`, `timestamps()`. When `tenant?`: attribute
`organization_id, :uuid, allow_nil?: false, public?: true, writable?: false` +
`multitenancy do strategy(:attribute) attribute(:organization_id) global?(true) end`.

**Definition** — immutable once published. Each row IS a future version: `version`
is assigned at create as `max(existing versions of same key, default 0) + 1` (a
change runs one aggregate query at create time — low volume, acceptable). Only one
`:draft` row per key may exist (create errors if another draft of the same key is
present); that draft is edited in place by `save_xml` until published. Publishing
keeps the row's pre-assigned version. Multiple published versions coexist;
`latest_published` sorts version desc.

- `key, :string, allow_nil?: false` (process key, e.g. `"access_request"`)
- `name, :string, allow_nil?: false`
- `version, :integer, allow_nil?: false` (assigned at create, see above)
- `status, :atom, constraints one_of [:draft, :published, :retired], default :draft, allow_nil? false`
- `xml, :string, allow_nil?: false` (the artifact)
- `graph, :map` (compiled snapshot; nil when the draft does not compile)
- `errors, {:array, :map}, default []` (compile errors `%{"path" => ..., "message" => ...}`; empty when it compiles)
- `content_hash, :string, allow_nil?: false` (sha256 hex of normalized xml)
- identity `unique_key_version [:key, :version]`
- actions: `:read`; `:create` accepting `key, name, xml` (computes hash, attempts
  compile, stores graph or `errors`); `:save_xml` update (**draft only**, accepts
  `xml`, recomputes hash/compile, rejects when status != :draft); `:publish` update
  (draft → published, **requires** `graph != nil` i.e. `errors == []`; published
  rows reject every further update); `:retire` update (published → retired).
- code interfaces (defined by macro on the module): `publish!/1`,
  `retire!/1`, `save_xml!/2`, `by_key_version/2` (`get?: true`, identity-backed),
  `latest_published/1` (read action `:latest_published`, filter status == :published,
  sort version desc, limit 1 — **returns a list**, caller takes hd).

**Instance** — pins one definition for life.
- `definition_id, :uuid, allow_nil?: false` belongs_to `:definition`
- `subject_type, :string, allow_nil?: false` (resource module name)
- `subject_id, :uuid, allow_nil?: false`
- `correlation_id, :string` (defaults to subject_id)
- `status, :atom, one_of [:running, :completed, :failed, :cancelled], default :running, allow_nil? false`
- `started_by_id, :uuid` (the human who started it, if any)
- `outcome, :atom` (from the end event reached; nil while running)
- actions: `:read`, `:create` (accepting all above, engine-only), `:mark_completed`
  (update, sets status/outcome), `:mark_failed`, `:cancel` (running → cancelled).

**Token** — one row per live branch.
- `instance_id, :uuid, allow_nil?: false` belongs_to `:instance`
- `node_id, :string, allow_nil?: false` (BPMN element id in the snapshot)
- `status, :atom, one_of [:active, :executing, :consumed, :dead], default :active, allow_nil? false`
- `parent_token_id, :uuid`
- `fork_id, :uuid` (shared id across siblings of one parallel fork)
- `attempts, :integer, default 0`
- actions: `:read`, `:create`, `:claim` (update with filter `status == :active`
  setting `status = :executing, attempts = attempts + 1` — optimistic; engine checks
  updated count to detect a concurrent winner), `:consume` (→ :consumed),
  `:kill` (→ :dead), `:reactivate` (dead/executing → active for retry).
  Implement claim semantics as an update action whose changeset filter guarantees
  single-winner (Ash returns error if no record matched).

**HumanTask** — the human work item (plan §6.2 `Process.Task`). Doubles as the
**standalone approval** (§2.5): `instance_id`/`token_id` are nil for
action-attached approvals.
- `instance_id, :uuid` belongs_to `:instance` (nil ⇒ standalone approval)
- `token_id, :uuid` belongs_to `:token` (nil ⇒ standalone approval)
- `node_id, :string, allow_nil?: false` (BPMN element id, or the host-chosen
  approval key for standalone, e.g. `"access_request.grant"`)
- `name, :string, allow_nil?: false`
- `status, :atom, one_of [:open, :claimed, :completed, :cancelled], default :open, allow_nil? false`
- `assignee_type, :atom, one_of [:user, :team]`, `assignee_id, :uuid`
- `claimed_at, :utc_datetime_usec`
- `due_at, :utc_datetime_usec`
- `outcome, :atom` (one of the node's declared outcomes, or `:expired`)
- `decided_by_id, :uuid`, `delegated_from_id, :uuid`
- `timer_job_ids, {:array, :integer}, default []`
- `comment, :string`
- `on_complete, :map, default %{}` — standalone only: `%{outcome => action_ref}`
  (e.g. `%{"approved" => "provision_access"}`); the engine invokes the matching
  action ref through `AshBpmn.ActionInvoker` when the task completes with that
  outcome. Empty for process tasks (the graph routes; it does not decide).
- `subject_type, :string`, `subject_id, :uuid` — denormalized onto the task for
  standalone approvals (process tasks get them from the instance).
- custom index (partial): `[:subject_type, :subject_id, :node_id]` unique
  `where: "status IN ('open','claimed')"` — one live approval per subject+key,
  the "before it takes effect" idempotency guard.
- actions: `:read`, `:create`, `:claim` (open → claimed, sets assignee+claimed_at;
  allowed for any current candidate — policy enforced by host rows + engine check),
  `:complete` (claimed → completed, requires `outcome`), `:cancel` (open/claimed → cancelled),
  `:delegate` (reassigns assignee, records delegated_from_id), `:attach_timers`
  (update accepting timer_job_ids), `:force_complete` (engine: timer expiry or
  sweep — completes with given outcome without an assignee, records decided_by_id nil).

**TaskCandidate** — materialized candidates (plan §6.3). Same shape as a grant row.
- `task_id, :uuid, allow_nil?: false` belongs_to `:task`
- `principal_type, :atom, one_of [:user, :team], allow_nil?: false`
- `principal_id, :uuid, allow_nil?: false`
- identity `unique_task_principal [:task_id, :principal_type, :principal_id]`
- actions: `:read`, `:create`, `:destroy`. No update — candidacy is a set, not a row.

**ProcessEvent** — process facts `ash_events` cannot express (plan §6.5). Never
duplicates a row change.
- `instance_id, :uuid, allow_nil?: false`
- `token_id, :uuid`
- `node_id, :string`
- `kind, :atom, allow_nil?: false` — one of `:instance_started, :node_entered,
  :node_completed, :gateway_branch_taken, :task_created, :task_claimed,
  :task_delegated, :task_completed, :task_cancelled, :task_expired, :timer_fired,
  :timer_cancelled, :action_invoked, :action_failed, :instance_completed,
  :instance_failed, :instance_cancelled, :sweep_recovered`
- `data, :map, default %{}`
- `recorded_at, :utc_datetime_usec, allow_nil?: false, default &DateTime.utc_now/0`
- actions: `:read`, `:create` (engine-only). UUIDv7? Use plain uuid v4 — the host's
  audit log already carries time-ordering; keep the library simple.

### 2.3 Configuration (host `config/config.exs`)

```elixir
config :ash_bpmn,
  assignment_resolver: MyApp.Bpmn.Resolver,   # required for user tasks (module impl'ing behaviour)
  action_invoker: MyApp.Bpmn.Invoker,         # required for service tasks
  queue: :bpmn,                               # Oban queue for advance/timer jobs (default :bpmn)
  max_attempts: 5                             # advance job attempts before instance :failed
```

Read via `AshBpmn.Config.assignment_resolver!/0` etc. (raise with instructive message
when missing; `queue/0` and `max_attempts/0` return defaults).

### 2.5 Standalone approvals — the thesis-7 deliverable

The manifesto's named gap: *"an action that requires a second person's approval
before it takes effect, with delegation, escalation, and an audit trail of who
approved what."* ash_bpmn closes it **without requiring a process graph**. The
approval layer is the same machinery as the `userTask` node — `HumanTask` +
`TaskCandidate` + timers + resolver — attached directly to a resource action.

**The change module** (host drops it on any action; Lane C owns it):

```elixir
create :submit do
  accept [...]
  change AshBpmn.Changes.RequireApproval,
    key: "access_request.grant",            # unique per subject+action while live
    name: "Approve access request",
    outcomes: [:approved, :rejected],
    candidates: [{:manager_of, "created_by_id"}],   # opaque to the library; resolver reads
    excluding: [:created_by_id],                     # maker-checker, plan §6.3
    on_complete: %{approved: "provision_access"},    # outcome => invoker action ref
    due_in: [hours: 48], escalate_in: [hours: 24], expire_in: [days: 7]  # all optional
end
```

`after_action`: creates the standalone `HumanTask` (`instance_id`/`token_id` nil,
subject denormalized, `on_complete` stored), materializes candidates minus
exclusions via the resolver, attaches timers (due/escalate/expire — omit any),
writes ProcessEvent `:task_created`. The partial unique index on
`(subject_type, subject_id, node_id) where status in (open, claimed)` makes
double-submission a constraint violation, not a race.

**Deciding**: `AshBpmn.decide!(task, outcome: :approved, comment: ..., actor: user)`
— validates outcome, completes the task, cancels timers, fires the matching
`on_complete` action ref through `AshBpmn.ActionInvoker` (ctx: subject loaded,
actor = decider, tenant), writes `:task_completed`. `claim_task!`/`delegate_task!`
/`my_tasks` are shared with process tasks (nil instance is fine everywhere).

The audit trail is the ProcessEvent log: claimed, delegated (delegate actor +
delegator accountability via `delegated_from_id`), decided, expired — with
`decided_by_id`, outcome and comment in `data`. Host-level audit (ash_events)
additionally captures task row mutations when the host instantiates the resources
with its own platform base, as ash_enterprise does.

### 2.4 Behaviours

```elixir
defmodule AshBpmn.AssignmentResolver do
  @callback candidates(specs :: [map()], ctx :: map()) ::
              {:ok, [%{type: :user | :team, id: Ash.UUID.t()}]} | {:error, term()}
  @callback exclusions(specs :: [map()], ctx :: map()) ::
              {:ok, [Ash.UUID.t()]} | {:error, term()}
  @callback escalate(task :: map(), ctx :: map()) :: :ok | {:ok, map()} | {:error, term()}
  @optional_callbacks escalate: 2
end

defmodule AshBpmn.ActionInvoker do
  @callback invoke(action :: String.t(), ctx :: map()) ::
              :ok | {:ok, map()} | {:error, term()}
end
```

`ctx` keys: `:subject` (loaded record or nil), `:instance`, `:task` (nil for service
tasks), `:actor` (the instance's starter user record or nil), `:tenant`, `:assigns`
(map of engine assigns, e.g. `%{"task" => %{"outcome" => :approved}}` at gateways).
**The engine passes `authorize?: false`-free ordinary options through** — the invoker
decides actors and calls its own actions (plan §5.3).

---

## 3. BPMN XML with Ash bindings (contract between Lane B, Lane D, Lane E)

Standard BPMN 2.0 namespaces. Bindings live in the `ash:` namespace
(`uri "https://github.com/lukegalea/ash_bpmn/ns"`), inside `extensionElements`.
**bpmn-moddle drops unknown namespaces on round-trip, so the designer's moddle
descriptor must define every ash element below and the compiler must accept exactly
these spellings.**

Full annotated example (this exact document is the Lane E seed fixture, modulo DI):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<bpmn2:definitions xmlns:bpmn2="http://www.omg.org/spec/BPMN/20100524/MODEL"
                   xmlns:ash="https://github.com/lukegalea/ash_bpmn/ns"
                   id="Definitions_1"
                   targetNamespace="https://github.com/lukegalea/ash_bpmn/ns">
  <bpmn2:process id="Process_access_request" name="Privileged access request" isExecutable="true">

    <bpmn2:startEvent id="Start_1" name="Request submitted">
      <bpmn2:outgoing>Flow_1</bpmn2:outgoing>
    </bpmn2:startEvent>

    <bpmn2:serviceTask id="Validate" name="Validate request">
      <bpmn2:extensionElements>
        <ash:taskConfig action="validate_request"/>
      </bpmn2:extensionElements>
      <bpmn2:incoming>Flow_1</bpmn2:incoming>
      <bpmn2:outgoing>Flow_2</bpmn2:outgoing>
    </bpmn2:serviceTask>

    <bpmn2:exclusiveGateway id="PrivilegedGateway" name="Privileged role?" default="Flow_NotPriv">
      <bpmn2:incoming>Flow_2</bpmn2:incoming>
      <bpmn2:outgoing>Flow_Sec</bpmn2:outgoing>
      <bpmn2:outgoing>Flow_NotPriv</bpmn2:outgoing>
    </bpmn2:exclusiveGateway>

    <bpmn2:userTask id="ManagerApproval" name="Manager approval">
      <bpmn2:extensionElements>
        <ash:taskConfig>
          <ash:candidates>
            <ash:candidate kind="manager_of" of="subject.created_by_id"/>
          </ash:candidates>
          <ash:exclusions>
            <ash:exclusion who="subject.created_by_id"/>
          </ash:exclusions>
          <ash:outcomes>
            <ash:outcome name="approved"/>
            <ash:outcome name="rejected"/>
          </ash:outcomes>
          <ash:timers>
            <ash:timer kind="remind" hours="24"/>
            <ash:timer kind="escalate" hours="48"/>
            <ash:timer kind="expire" days="7"/>
          </ash:timers>
        </ash:taskConfig>
      </bpmn2:extensionElements>
      <bpmn2:incoming>Flow_NotPriv</bpmn2:incoming>
      <bpmn2:outgoing>Flow_MgrOut</bpmn2:outgoing>
    </bpmn2:userTask>

    <bpmn2:serviceTask id="Provision" name="Provision access">
      <bpmn2:extensionElements>
        <ash:taskConfig action="provision_access"/>
      </bpmn2:extensionElements>
      <bpmn2:incoming>Flow_JoinOut</bpmn2:incoming>
      <bpmn2:outgoing>Flow_Done</bpmn2:outgoing>
    </bpmn2:serviceTask>

    <bpmn2:endEvent id="End_approved" name="Approved">
      <bpmn2:incoming>Flow_Done</bpmn2:incoming>
    </bpmn2:endEvent>
    <bpmn2:endEvent id="End_rejected" name="Rejected">
      <bpmn2:incoming>Flow_Rej</bpmn2:incoming>
    </bpmn2:endEvent>
  </bpmn2:process>
  <bpmndi:BPMNDiagram id="BPMNDiagram_1"> ... </bpmndi:BPMNDiagram>
</bpmn2:definitions>
```

Rules:
- `conditionExpression` body uses the ash expression language (§4) and `xsi:type` is
  ignored. Gateway `default="Flow_x"` marks the default flow.
- `ash:taskConfig` on `serviceTask`: exactly one `action` attribute (non-empty).
- `ash:taskConfig` on `userTask`: `candidates` ≥ 1; `outcomes` ≥ 1; `exclusions` and
  `timers` optional. Timer attrs: `kind` (`remind|escalate|expire`) and exactly one
  duration unit attribute among `minutes|hours|days`.
- Candidate/exclusion `kind`/`of`/`who`/`name`/`scope` values are **opaque strings to
  the library** — the host resolver interprets them. `of`/`who` hold subject paths.
- End events may carry `<ash:taskConfig outcome="approved"/>` → instance outcome.
- Unknown elements/attributes in the ash namespace → compile error (typo protection).

---

## 4. Expression language (FEEL, via `AshBpmn.Feel`)

> **Superseded, 2026-08-20.** This section described `AshBpmn.Expr`: a hand-written
> tokenizer, recursive-descent parser and evaluator for a small comparison grammar.
> That module has been **deleted**, along with its 393-line test file, and FEEL — the
> expression language DMN itself specifies — replaced it. The grammar below is kept
> only so a reader of an older definition can see what used to be accepted.
>
> Two defects in the old implementation are worth recording, because they are why the
> replacement was not merely tidying. It called `String.to_atom/1` on path segments
> taken from **tenant-authored** BPMN XML, and atoms are never garbage collected, so a
> tenant admin with enough distinct segments could exhaust the atom table and take the
> node down. And `eval/2` wrapped everything in a bare `rescue _ -> {:ok, false}`, so
> every evaluation failure became "branch not taken" — indistinguishable from a
> condition that was genuinely false.
>
> Three semantics changed in ways an old expression can notice, which is why the test
> file was deleted rather than ported: FEEL orders strings, so `"a" > "b"` is `false`
> for a *reason* rather than by accident; a comparison against `null` is `null`, not
> `false`; and an erroneous expression is `null` rather than `false`. See
> `AshBpmn.Feel`, `AshBpmn.ConditionMigrationTest`, and ADR 0027 in ash_enterprise.

Conditions are FEEL expression text, stored as
`%{"language" => "feel", "text" => "..."}` inside the graph snapshot, and evaluated by
`AshBpmn.Feel.evaluate_condition/3` through `boxic_feel`. `language="feel"` on a
`tFormalExpression` is optional; any other language is refused at compile time with the
flow id in the error.

### The grammar this replaced (historical)

```
expr    := or
or      := and ("or" and)*
and     := not ("and" not)*
not     := "not" not | cmp
cmp     := path op literal | path "in" "[" literal ("," literal)* "]"
op      := ">" ">=" "<" "<=" "==" "!="
path    := ident ("." ident)*
literal := integer | float | quoted-string | true | false
```

Note `==` and `!=`, which are not FEEL: FEEL spells equality `=` and inequality
`!=`. Fixture conditions were rewritten accordingly.

Runtime context paths are unchanged: `subject.<attr>` (nested maps and structs via
Access-safe traversal — structs use dot access on fields, never `Access`),
`task.outcome`, `task.assignee_id`, `routing.<signal>` promoted by a business rule
task, and `env.<key>` from engine assigns.

---

## 5. Compiled graph snapshot (Lane B output, Lane C input — exact shape)

`AshBpmn.compile(xml)` → `{:ok, graph} | {:error, [errors]}` where errors are
`%{path: String.t(), message: String.t()}`. Graph is a plain map, JSON-able:

```elixir
%{
  "process_id" => "Process_access_request",
  "start" => "Start_1",
  "nodes" => %{
    "Start_1" => %{"type" => "startEvent", "name" => "Request submitted"},
    "Validate" => %{"type" => "serviceTask", "name" => "Validate request",
                    "action" => "validate_request"},
    "PrivilegedGateway" => %{"type" => "exclusiveGateway", "name" => "...",
                              "default_flow" => "Flow_NotPriv"},
    "ManagerApproval" => %{"type" => "userTask", "name" => "Manager approval",
        "candidates" => [%{"kind" => "manager_of", "of" => "subject.created_by_id"}],
        "exclusions" => [%{"who" => "subject.created_by_id"}],
        "outcomes" => ["approved", "rejected"],
        "timers" => [%{"kind" => "remind", "minutes" => 1440},
                     %{"kind" => "escalate", "minutes" => 2880},
                     %{"kind" => "expire", "minutes" => 10080}]},
    "End_approved" => %{"type" => "endEvent", "name" => "Approved", "outcome" => "approved"}
  },
  "flows" => %{
    "Flow_1" => %{"from" => "Start_1", "to" => "Validate", "condition" => nil},
    "Flow_Sec" => %{"from" => "PrivilegedGateway", "to" => "SecurityApproval",
                    "condition" => {expr ast}}
  },
  "joins" => %{"Join_1" => %{"waits_for" => ["SecurityApproval", "ManagerApproval"]}}
}
```

- Parallel gateway with >1 outgoing = fork (engine mints a `fork_id`); with >1
  incoming = join (entry in `"joins"` keyed by node id, `waits_for` = incoming source
  node ids). Mixed parallel gateways are **rejected** by the compiler (documented
  limitation, plan §10.4).
- All durations normalize to `minutes` (integer).

### 5.1 Compiler verifications (each a distinct error)

1. exactly one start event; ≥1 end event
2. every flow references existing nodes; graph is fully reachable from start; every
   path reaches an end event (no dangling nodes, no cycles without end — detect via
   reachability from start + every reachable node can reach some end event)
3. exclusive gateway: ≥1 outgoing; exactly one default flow or every outgoing has a
   condition (else error); conditions parse
4. userTask: has taskConfig, ≥1 candidate, ≥1 outcome
5. serviceTask: has taskConfig with non-empty action
6. joins: waits_for matches actual incoming flows
7. unsupported BPMN element types rejected with the element id
8. unknown ash: attributes/elements rejected with the element id
9. `isExecutable` must be true

---

## 6. Runtime (Lane C)

### 6.1 Public facade `AshBpmn`

```elixir
AshBpmn.start_instance!(domain, process: "access_request", subject: request,
                        actor: user, tenant: org_id) :: instance
AshBpmn.advance(instance, token: token, assigns: %{})          # internal, enqueues job
AshBpmn.complete_task!(task, outcome: :approved, comment: "...", actor: user) :: task
AshBpmn.decide!(task, outcome: :approved, comment: "...", actor: user) :: task
  # standalone approvals: complete + fire on_complete action ref (§2.5);
  # process tasks: identical to complete_task!
AshBpmn.claim_task!(task, actor: user) :: task
AshBpmn.delegate_task!(task, to_principal: %{type: :user, id: id}, actor: user) :: task
AshBpmn.cancel_instance!(instance, actor: user) :: instance
AshBpmn.my_tasks(domain, principal_ids: [id], opts) :: [task]   # candidates join, status in open/claimed, claimed by actor OR open
AshBpmn.instance_report(instance) :: %{instance:, tokens: [], tasks: [], events: []}
AshBpmn.retry_instance!(instance) :: instance                   # reactivate dead tokens, re-enqueue
```

Bang variants raise Ash errors (host renders form errors via AshPhoenix normally).
Non-bang variants also exist for each. All take the host **domain** module as first
arg where shown, resolved via `AshBpmn.Resources.for_domain/1`.

### 6.2 Execution loop (`AshBpmn.Runtime.AdvanceWorker`, Oban worker)

Job args: `%{"instance_id" => id, "token_id" => id, "node_id" => binary}`. Worker:

1. load instance+token; unless token :active → `{:ok, :skipped}` (idempotent redelivery)
2. token `:claim` — if claim loses the race → `{:ok, :lost_race}`
3. load graph from definition; execute node by type (§6.3); in ONE transaction
   (Ash `Ash.transaction` on domain where supported, else sequential ops with the
   claim-gate as the idempotency anchor):
   compute outgoing, consume/dead-end token, write next token(s) or complete
   instance, write ProcessEvent rows, enqueue next AdvanceWorker jobs (Oban insert is
   transactional — Oban 2.x supports `Oban.insert/2` inside `Ecto` multi via repo
   transaction; call through `AshBpmn.Runtime.Oban.insert_txn/1` helper that uses
   `Oban.insert/1` (transaction-aware))
4. human task nodes: create HumanTask + TaskCandidate rows (via resolver), attach
   timers as Oban jobs (`scheduled_at` = now + minutes), record job ids, **do not
   advance** — token sits at :executing until completion
5. return `{:ok, ...}`; rescue/error → `{:error, reason}` letting Oban retry with
   backoff; after `max_attempts` (job.attempts >= max) worker marks instance
   `:failed` and returns `{:ok, :failed_permanently}` (cancel the loop).

Timers (`AshBpmn.Runtime.TimerWorker`, args `%{"task_id", "kind"}`): unless task
status in [:completed, :cancelled] → fire: `remind` → ProcessEvent
`:timer_fired` (+ resolver `escalate/2` if defined? no — remind just records);
`escalate` → resolver.escalate + event; `expire` → task `:force_complete` with
outcome `:expired`, record `:task_expired`, then advance the token with
`assigns %{"task" => %{"outcome" => "expired"}}`. On task completion the engine
cancels remaining timer jobs (`Oban.cancel_job/1`) — the bookkeeping the plan §6.4
demands.

Join semantics: when a token arrives at a join node, do not consume-and-advance;
instead within one transaction set it :consumed, then count :active tokens at same
node with same fork_id — wait, simpler and per contract: count tokens with same
`instance_id`, `node_id`, `fork_id`, status :active; if count == `waits_for` size
(minus self already consumed) → mint one fresh :active token at join and enqueue
advance. Otherwise just record event and wait. **Deadlock honesty:** if any sibling
token is :dead, the join can never fire — the compiler forbids mixed patterns that
create this, and the sweep (§6.4) reports stuck joins.

Sweep (`AshBpmn.Runtime.SweepWorker`): plain Oban worker the host may cron
(`config :ash_oban`/Oban plugins). Finds instances :running whose :active tokens
have no live Oban job (query oban_jobs via repo — provide helper with graceful
fallback if Oban table unqueryable: re-enqueue advances for all :active tokens with
attempts < max, idempotent by claim-gate) + reports stuck joins via ProcessEvent
`:sweep_recovered`.

### 6.3 Node execution dispatch (`AshBpmn.Runtime.Interpreter`)

- `startEvent` → follow outgoing(s)
- `endEvent` → instance `:mark_completed` with `outcome` from node config or nil
- `serviceTask` → `AshBpmn.Config.action_invoker!/0.invoke(action, ctx)`; `:ok`/`{:ok, _}` → follow outgoing; `{:error, e}` → raise (Oban retry; after max → :failed + `:action_failed` event)
- `userTask` → create task+candidates+timers as §6.2.4
- `exclusiveGateway` → eval each outgoing condition against ctx (subject re-loaded
  fresh, `task` assigns present when following a task completion) in declared order;
  first true wins; else default flow; else compile-time-impossible (but runtime error
  if evaluator misbehaves); record `:gateway_branch_taken` with chosen flow
- `join` → §6.2 join semantics

Task completion path (`complete_task!`): validates outcome ∈ node outcomes;
task `:complete`; cancel timers; ProcessEvent `:task_completed`; advance token with
assigns.

**Candidate re-check at claim (plan §6.3):** `claim_task!` asserts the actor's
principal appears in TaskCandidate rows for the task; on mismatch raises
`Ash.Error.Forbidden`. Rows are the index, the rule is the resolver — the engine
does NOT re-run the resolver at claim (documented: staleness handled by sweep +
host may re-materialize by destroying/creating candidate rows).

---

## 7. Web layer (Lane D)

### 7.1 JS — `priv/js/ash_bpmn_designer.js` (ESM, no default export)

Exports: `AshBpmnDesigner` (LiveView hook), `AshBpmnViewer` (LiveView hook),
`ashBpmnModdle` (descriptor object), `AshBpmnPropertiesPanel`? NO — the properties
panel is **server-rendered** by the LiveView; the hook only applies config edits to
the diagram. The hook imports:
`bpmn-js/lib/Modeler`, `bpmn-js/lib/Viewer` (navigated), CSS via
`bpmn-js/dist/assets/diagram-js.css`, `bpmn-js/dist/assets/bpmn-js.css`,
`bpmn-font` css — these are **host package.json deps** (`bpmn-js@^18`). Hook
protocol (exact event names):

hook → LV (pushEvent): `save_xml` `%{"xml" => str}` (reply to collect), `selection_changed`
`%{"id" => id, "type" => bpmn_type, "name" => name}` (empty selection → `%{}`),
`dirty_changed %{"dirty" => bool}`, `import_error %{"message" => msg}`,
`saved `%{"ok" => true}` (after apply-config ack)`.
LV → hook (push_event): `load_xml` `%{"xml" => str}` (mount + revert),
`collect_xml` `%{}` (hook replies via save_xml), `apply_config`
`%{"id" => id, "config" => %{...ash taskConfig as JSON-able map...}, "name" => str}`
(hook writes extensionElements via moddle + `modeling.updateProperties`),
`highlight` `%{"node_ids" => [ids]}` (viewer: add css class marker to elements;
remove previous), `fit` `%{}`.

taskConfig JSON shape (matches compiler input exactly — candidates/exclusions/
outcomes/timers/action/outcome keys as §5). The hook is the ONLY place that knows
moddle; keep `setConfigFromJson(bo, json)` small and total (rebuild extension
elements from scratch each apply — never merge).

Watermark: leave bpmn.io logo untouched (license). Document it.

### 7.2 LiveViews (`lib/ash_bpmn/web/`) — layout-agnostic content

Each LiveView is configured by **host wrapper modules using `use`** (the
AshAdmin pattern — Phoenix has no supported way to pass dynamic options via
routes):

```elixir
# host router:  live "/processes/access_request/designer", MyAppWeb.Bpmn.DesignerLive
defmodule MyAppWeb.Bpmn.DesignerLive do
  use AshBpmn.Web.DesignerLive,
    domain: MyApp.Bpmn,                  # required: host bpmn domain
    process: "access_request",           # required: definition key
    actor: {MyAppWeb.Bpmn.Helpers, :current_actor, []}  # optional {m,f,a} (socket) → actor
end
```

The `use` macro injects `mount/3`, `handle_params/3`, `render/1` and all event
handlers; hosts may override any of them after. LiveViews render inner content
only — the host picks layout via its own router `layout:` opt or wrapper. No
`<Layouts.app>` of their own, no host module references inside the library.

- `AshBpmn.Web.DesignerLive` — router opts (via `handle_params` third arg):
  `domain:` (required, host bpmn domain), `process:` key, `actor: {m, f, a}`
  (called with socket to get current actor; default nil). Assigns: definition,
  latest published version info, compile errors panel, selected node panel
  (server-rendered forms per node type: text for name, select for action ref
  candidates is host-specific — keep free-text + datalist of known actions from
  graph), dirty flag, save/publish/revert buttons. Save = collect → `save_xml!`;
  Publish = save then `publish!`; errors rendered inline. Events handled:
  `collect-xml` (push collect_xml), `save-xml` (params xml), `selection-changed`,
  `update-config` (panel form submit → apply_config push), `publish`, `revert`.
- `AshBpmn.Web.ViewerLive` — opts `domain:`, `instance_id:` (param) — loads
  instance_report, renders viewer hook + right rail: tokens (node, status),
  tasks (name/status/assignee/outcome), events (kind/node/time). Pushes highlight
  on update (poll via `Process.send_after` every 5s while running, stopped on
  completed/failed/cancelled).
- `AshBpmn.Web.TaskListLive` — opts `domain:`, `principal_ids: {m,f,a}` (called
  with socket; enterprise: `&__MODULE__.scopeless`? no — enterprise passes a
  `{Module, :fun, [args]}` returning principal_ids, or the LV accepts a
  `principal_ids` assign set via `send_update` — keep `{m,f,a}`). Lists my_tasks
  grouped open/claimed, buttons claim/complete(outcome select)/delegate(select
  user input) — minimal generic forms.

Styling: Tailwind utility classes only, no component library, dark-neutral palette
that reads fine inside any host layout (`bg-white dark:bg-zinc-900` etc.), scoped
`.ash-bpmn-canvas` sizing (`h-[32rem] w-full border rounded-lg overflow-hidden`).
No `<script>` tags; the hook is host-registered. No A2UI dependency (library must
stay host-agnostic).

CSRF/auth: LiveViews never authenticate themselves — the host's live_session does.

---

## 8. Tests

- Lane B: pure unit tests (`test/ash_bpmn/compiler_test.exs`, `expr_test.exs`) with
  hermetic XML fixtures — no DB.
- Lane A: resource tests against `AshBpmn.TestRepo` (real Postgres like ash_strangler;
  env `PGPORT`), instantiating a test domain `AshBpmn.Test.Domain` under
  `test/support/`.
- Lane C: engine tests with `config :ash_bpmn, oban_testing: :inline` — the
  runtime's Oban shim (`AshBpmn.Runtime.Oban`) honours it:
  - `insert(worker, args, opts)` inline-mode → executes `worker.perform/1`
    synchronously (wrapped, errors re-raised after job bookkeeping), returns
    `{:ok, %Oban.Job{id: unique_integer, args: args}}`.
  - `insert(... scheduled_at: dt)` inline-mode (timers) → does NOT execute;
    stores the job in a test-owned ETS table (`AshBpmn.Runtime.Oban.TestJobs`)
    and returns `{:ok, %Oban.Job{id: ...}}`. Tests fire timers explicitly via
    `AshBpmn.Runtime.Oban.TestJobs.fire!(kind, task_id)` (looks up matching
    stored job, calls TimerWorker.perform) and inspect stored timers via
    `all/0` + `clear/0`. Time-based behaviour is thus always explicit.
  - `cancel_job/1` inline-mode → removes from TestJobs, `:ok`.
  - Production mode (no config) → delegates to real `Oban.insert/2` (Oban 2.x
    inserts are transaction-aware when called inside an Ecto transaction) and
  `Oban.cancel_job/1`.
- Lane D: no JS tests in-repo; LiveView render tests using `Phoenix.ConnTest`-free
  `@tag :skip`? LiveView tests need a host endpoint — provide `test/support/endpoint.ex`
  bare Phoenix Endpoint with the three LVs at fixed routes + `test/support/conn_case.ex`.
  Assert key element ids (`#ash-bpmn-canvas`, `[phx-hook="AshBpmnDesigner"]`, panels,
  buttons with dom ids), not text.

Oban queue name for workers: read `AshBpmn.Config.queue/0` at runtime (worker
`use Oban.Worker, queue: :dynamic` — Oban supports `queue/0` callback override;
implement `queue/0` reading config).

---

## 9. File ownership (write scopes are exclusive)

- **Orchestrator**: `DESIGN.md`, `mix.exs`, `devenv.nix`, `config/**`, `.formatter.exs`,
  `.gitignore`, `LICENSE*`, `LICENSES/**`, `.tool-versions`, `.github/**`,
  `CHANGELOG.md`, `README.md`, `usage-rules.md`, `documentation/**`, repo/CI.
- **Lane A**: `lib/ash_bpmn/resources.ex` (+ per-resource files), `lib/ash_bpmn/resources/*.ex`,
  `lib/ash_bpmn/config.ex`, `lib/mix/tasks/ash_bpmn.install.ex`, `test/support/**` (test repo,
  domain, resource instantiations), `test/ash_bpmn/resources_test.exs`.
- **Lane B**: `lib/ash_bpmn/compiler.ex`, `lib/ash_bpmn/compiler/*.ex` (xml.ex, graph.ex,
  verify.ex, errors.ex), `lib/ash_bpmn/expr.ex`, `test/ash_bpmn/compiler_test.exs`,
  `test/ash_bpmn/expr_test.exs`, `test/fixtures/*.bpmn`.
- **Lane C**: `lib/ash_bpmn.ex` (facade), `lib/ash_bpmn/runtime/**`, `lib/ash_bpmn/changes/**`
  (`require_approval.ex`), `lib/ash_bpmn/assignment_resolver.ex`,
  `lib/ash_bpmn/action_invoker.ex`, `test/ash_bpmn/engine_test.exs`,
  `test/ash_bpmn/approvals_test.exs`, `test/ash_bpmn/runtime_test.exs`
  (uses Lane A test support by name).
- **Lane D**: `priv/js/ash_bpmn_designer.js`, `lib/ash_bpmn/web/**`,
  `test/ash_bpmn/web/**`, `test/support/endpoint.ex`, `test/support/conn_case.ex`.

---

## 10. Non-goals (explicit)

BPMN 2.0 conformance; XML interchange with foreign engines; lanes; message events /
correlation; sub-processes; compensation (phase-3 per plan); DMN; CMMN; a second
runtime; process-state on the subject resource; `forbid_if` anywhere (plan §10.14);
business logic in the graph (plan §5.3). In-flight migration: **never migrate**
(plan §7 default) — instances finish on their pinned definition.
