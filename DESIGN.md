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

`escalate/2` is being redefined to answer whom to add, with a context that carries the
tenant: see §11.6.

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
AshBpmn.cancel_instance!(instance, actor: user, reason: "...") :: instance   # one step; cascades to call-activity children
AshBpmn.my_tasks(domain, principal_ids: [id], team_ids: [id]) :: [task]   # candidates join (:user rows on principal_ids, :team rows on team_ids), status in open/claimed
AshBpmn.instance_report(instance) :: %{instance:, tokens: [], tasks: [], events: []}
AshBpmn.retry_instance!(instance) :: instance                   # reactivate dead tokens, re-enqueue
```

Bang variants raise Ash errors (host renders form errors via AshPhoenix normally).
Non-bang variants also exist for each. All take the host **domain** module as first
arg where shown, resolved via `AshBpmn.Resources.for_domain/1`.

### 6.2 Execution loop (`AshBpmn.Runtime.AdvanceWorker`, Oban worker)

Job args: `%{"instance_id" => id, "token_id" => id, "node_id" => binary}`. Worker:

1. load instance+token; unless token :active → `{:ok, :skipped}` (idempotent redelivery)
2. token `:claim` — a compare-and-set in the `UPDATE` on (status `:active`, attempt
   count read); if it loses the race → `{:ok, :lost_race}`. The claim commits on its
   own: it is what marks the token as being worked on while the node runs.
3. load graph from definition; execute node by type (§6.3) — the host's work (service
   task action, business rule, `ash:call`) runs here, **outside** any transaction.
4. **A node step is atomic.** The node's writes run as one `AshBpmn.Runtime.Step`:
   one `Ash.transaction` over the engine's resources, which first takes the instance
   row `FOR UPDATE` and re-reads the token `FOR UPDATE`, and goes ahead only if this
   job's claim is still current (status `:executing`, same attempt count) — else it
   writes nothing and returns `{:ok, :claim_lost}`. Inside: consume/park/kill the token,
   write next token(s) or complete/fail the instance, ProcessEvent rows, tasks,
   candidates, timer ledger rows, and every `Oban.insert/2` for the next jobs. Oban
   inserts through the same repo, so a job is part of the transaction and a rollback
   drops it — **the host's Oban must use the BPMN resources' repo** for this to hold.
   The instance lock serializes the steps of one instance, which is what makes "am I
   the last branch?" (end events, joins) have one answer. Flight-view broadcasts and,
   in inline test mode, the jobs a step enqueued run after the outermost step commits
   and are dropped if it rolls back. Starting an instance, completing a task, and the
   timer, boundary and catch-timer wakes are steps in the same sense; a wake's claim
   out of `:waiting` is inside its step, so a wake that fails leaves the token parked.
4. human task nodes: create HumanTask + TaskCandidate rows (via resolver), attach
   timers as Oban jobs (`scheduled_at` = now + minutes), record job ids, **do not
   advance** — token sits at :executing until completion
5. return `{:ok, ...}`; a failure in 3 or 4 (4 having rolled back whole) hands the
   claim back (`:release`, attempts kept) and returns the error so Oban retries with
   backoff; on the last attempt (the engine's `max_attempts` or the job's own) the
   worker kills the token, marks the instance `:failed`, records `:action_failed` — one
   step — and returns `{:ok, :failed_permanently}`. A call activity whose child cannot
   be started is such a failure: the start is inside the call activity's step, so the
   park rolls back with it. It is a fault, not a business error, so an error boundary
   on the call activity does not catch it (an error boundary catches only a typed
   business error; see `AshBpmn.ActionInvoker`), and there is nowhere else to route it.

Timers (`AshBpmn.Runtime.TimerWorker`, args `%{"task_id", "kind"}`): unless task
status in [:completed, :cancelled] → fire: `remind` → ProcessEvent
`:timer_fired` (+ resolver `escalate/2` if defined? no — remind just records);
`escalate` → resolver.escalate + event; `expire` → task `:force_complete` with
outcome `:expired`, record `:task_expired`, then advance the token with
`assigns %{"task" => %{"outcome" => "expired"}}`. On task completion the engine
cancels remaining timer jobs (`Oban.cancel_job/1`) — the bookkeeping the plan §6.4
demands.

Join semantics (revised 2026-11-04; the 2026-09-07 rule this replaces looked only at a
join's *immediate* source nodes, and only for `:active`/`:executing` tokens, so a sibling
branch two nodes long, or parked one node back, read as "will never arrive" and the join fired
twice): when a token arrives at a join node, within one step (§6.2.4, under the instance lock)
kill it and record a `:node_entered` event with `"join" => "arrived"`. Then:

1. The join's *pending* arrivals are its `"arrived"` events whose token is not named in the
   `"arrived_token_ids"` of any `:node_completed` event at the join. A firing names the
   arrivals it used, so a join inside a loop starts every pass with nothing pending.
2. Ask whether anything can still arrive: a live token (`:active`, `:executing` or
   `:waiting`) on any node *upstream* of the join — any node with a path to it that does not
   pass through the join, walking sequence flows backwards and from a boundary event to the
   activity it is attached to — or a live token at the join itself (an arrival whose advance
   has not run yet), or another upstream join with pending arrivals. If yes → wait. If no →
   fire: record a `:node_completed` event naming the pending arrivals, mint one fresh
   `:active` token past the join and enqueue its advance.
3. Because a branch can be taken away from the join *after* its siblings arrived — an
   exclusive gateway choosing the other path, a boundary leading elsewhere, a branch reaching
   its own end — every advance step that does not end the instance re-asks (2) for each join
   with pending arrivals, repeating until nothing fires; an end event asks before deciding
   whether it was the last branch. An instance that is not `:running` never releases a join:
   a `:failed` instance's failed branch is dead until a retry brings it back.

When every incoming flow has had an arrival this is the BPMN parallel join. When an upstream
choice pruned a branch it is BPMN's inclusive-join rule: the join stops waiting for a branch
no token can reach any more. It is deliberately *not* a strict AND-join as Zeebe implements
one (fire when every incoming flow has a token, otherwise wait forever): the compiler permits
fork → exclusive-branch-prune → join, and a strict join would deadlock in every such graph. If
`inclusiveGateway` is ever added, this rule *is* its join semantics and should be promoted to
the shared implementation. No dead tokens are propagated through the graph; the question is
answered structurally from the live tokens and the snapshot.

Sweep (`AshBpmn.Runtime.SweepWorker`): plain Oban worker the host may cron
(`config :ash_oban`/Oban plugins). For each :running instance:

- `:active` tokens: re-enqueue the advance (idempotent by the claim gate), with a
  `:sweep_recovered` event, in one step.
- `:executing` tokens whose claim (`updated_at`) is older than `claim_timeout`
  (default 300 s): **executing tokens are recovered after `claim_timeout`.** The worker
  that claimed them is presumed dead. `:recover` sets the token back to `:active` as a
  compare-and-set on the status and attempt count the sweep read — so a racing sweep,
  or a worker that finished meanwhile, makes it a no-op — and the same step records
  `:sweep_recovered` (`"problem" => "stale_claim"`) and re-enqueues the advance. The
  attempt count is kept and the re-claim increments it, so a node that kills its worker
  every time exhausts `max_attempts` and fails the instance. A worker that was only
  slow loses at its step's claim check and writes nothing; its host action may have run
  twice, so `claim_timeout` must exceed the slowest service task.
- `:waiting` tokens on a timer with no live wake job: reported (`"problem" =>
  "orphaned_wait"`), never repaired.

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

**Candidate re-check at claim (plan §6.3):** `claim_task!` asserts a
TaskCandidate row names the actor (`:user`) or one of their teams (`:team`, from
the resolver's optional `team_ids/2`) and that the task's `excluded_principal_ids`
name neither; on mismatch it raises `ArgumentError`. `complete_task!` makes the
same check on an open task and requires the holder on a claimed one;
`delegate_task!` requires the holder and a candidate delegate (see
`AshBpmn.Candidacy`). Rows are the index, the rule is the resolver — the engine
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
- No task list LiveView. One shipped (`AshBpmn.Web.TaskListLive`) and was
  removed: it ran claim/complete/delegate through the resource's update actions
  with the engine's authority and no actor, so nothing recorded who acted and a
  completion never advanced the token. Hosts present tasks
  from their own `HumanTask` with a candidacy read and actions run as the
  person — see "Presenting tasks to people" in
  `documentation/topics/assignment-and-maker-checker.md`.

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

---

## 11. Deadlines, notices and escalation (decided 2026-11-21)

This section is the contract for the next four slices of work. It amends §2.4 (the
`escalate/2` callback), §3 (the `ash:timer` attributes) and
[what it refuses](documentation/topics/what-it-refuses.md) (timer cycles and absolute
dates). Until each slice lands, the code and the topic guides describe what runs today and
this section describes what is being built. Parts marked **[host-breaking]** change what an
existing host compiles, publishes or implements; each ships as its own pull request with a
note to downstream hosts, and is merged only after they have been told.

### 11.1 What is wrong today

- **A timer's moment can only be a literal.** `ash:timer` takes `minutes`, `hours` or
  `days`; a `timerEventDefinition` takes a literal `timeDuration`. Nothing a person is
  waiting on (a stored notice date, a grant's end, the day a request arrived) can set when a
  timer fires, so a modeller has to start a process at exactly the right moment for a fixed
  offset to line up, and a later change to the date moves nothing.
- **A reminder reaches nobody.** `remind` records `:timer_fired` and stops. §"Timers" in the
  running-processes guide says "your notifier reads the log", but no behaviour names a
  notifier, so a host that never wrote one is never told that its reminders go nowhere.
- **An escalation is declared but not plumbed.** `escalate/2` is optional. A host without
  it gets a `:timer_fired` event with `"handler" => "none"` and nothing else. A host that
  did implement it would be handed a context with `instance: nil`, `subject: nil` and no
  `:tenant` (`Runtime.TimerWorker`), so it could not resolve anyone correctly in the task's
  tenant. And the callback's answer is only `:ok`: the engine has no way to know whom the
  escalation reached, so it cannot keep maker-checker exclusions on the people it adds.
- **"Due" is not data on a diagram task.** `HumanTask.due_at` is set by
  `Changes.RequireApproval` only. A user task in a diagram never has one, so a host can only
  compute "late" from `inserted_at` with a constant.
- **A malformed `ash:timer` disappears.** `parse_timer/1` returns `nil` for a timer with no
  unit or no kind, and the nil is filtered out; a misspelled `kind` compiles and fails at
  run time as "unknown timer kind"; `hours="2.5"` raises inside the compiler instead of
  returning an error. Each is the declared-but-not-plumbed failure §3's typo protection
  exists to prevent.

### 11.2 Sources

Read for this decision:

- **BPMN 2.0.2** (OMG formal/2013-12-09). §10.5.5, Table 10.101: `timeDate`, `timeCycle`
  and `timeDuration` are each an *Expression*, mutually exclusive in an executable process,
  returning an ISO 8601 date and time, recurring interval or duration respectively.
  §10.5.4, Table 10.92: `cancelActivity` selects interrupting or non-interrupting for
  message, timer, escalation, signal and conditional boundary events. §10.5.6: "Escalations
  are non critical and execution continues at the location of throwing"; an escalation is
  thrown inside a sub-process or called process and caught by a boundary event on it or by
  an event sub-process. §10.3.4: a user task's lifecycle is managed by a task manager, and
  may be implemented with WS-HumanTask. BPMN itself defines no deadline on a user task.
- **OASIS WS-HumanTask 1.1** (ws-humantask-1.1-spec-cs-01). §3.1, generic human roles:
  potential owners, excluded owners ("All excluded owners are implicitly removed from the
  set of potential owners"), business administrators, notification recipients. §4.9:
  a `startDeadline` (obsolete once the task is started) and a `completionDeadline` (stops at
  a final state), each given `for` a duration or `until` a point in time, each carrying
  escalations; an escalation has an optional condition and exactly one action, a
  notification or a reassignment, and "the state of the task is not changed". §1 and
  §3.8.3: a notification is a one-way kind of task that carries input only.
- **Camunda 8** reference documentation (timer events; user tasks). Timer values are a
  static value or an expression, evaluated when the catch event is activated; a `timeDate`
  already past fires immediately; `timeCycle` is an ISO 8601 repeating interval
  (`R5/PT10S` fires five times; `R/P1D` repeats until cancelled) or a cron expression; a
  non-interrupting boundary with a cycle re-arms until its repetitions run out.
  `zeebe:taskSchedule` gives a user task a `dueDate` and a `followUpDate`, as expressions
  evaluated when the task activates, returning ISO 8601 date-times with an offset; neither
  date triggers anything by itself.
- **Flowable** BPMN constructs reference. `flowable:dueDate` on a user task, an expression
  resolving to a date, an ISO 8601 string or a duration from creation; timer expressions;
  a cycle's `endDate`; `businessCalendarName`; and boundary timers, with `timeCycle` for
  "sending multiple reminders for overdue user task", as the way to escalate.
- **DMN 1.5 FEEL** built-ins, as `boxic_feel` implements them: `now()`, `today()`,
  `date and time(...)`, `duration(...)`, and date-time plus or minus a duration.

What is taken: BPMN's three timer kinds, written as expressions; Camunda 8's rule for when
an expression is evaluated and the `=` prefix that marks one; WS-HumanTask's split between
a start deadline and a completion deadline, its notification as a kind of its own, and its
rule that an excluded owner is never a potential owner; Camunda's and Flowable's due date
and follow-up date as data on the task. What is not taken, and why, is in §11.9.

### 11.3 A timer's moment

Every timer in a definition, whether an `ash:timer` on a user task, a
`timerEventDefinition` on an intermediate catch event or a timer boundary event, resolves to
one instant when it is **armed**: when the token parks at the catch event, when the
boundary's activity parks, or when the user task is created. The instant is written to the
timer ledger (`TimerJob.due_at`) and to Oban's `scheduled_at`, and from then on it is a fact,
not a formula.

**Forms.** A value that begins with `=` is a FEEL expression; anything else is a literal.

| Form | `ash:timer` attribute | BPMN element | Literal | Expression must return |
|---|---|---|---|---|
| duration from arming | `duration` (or the existing `minutes`/`hours`/`days`) | `timeDuration` | ISO 8601 duration, as today | a days-and-time duration |
| point in time | `date` | `timeDate` | **refused**, as today | a date-time with an offset |
| bounded repetition | `cycle` | `timeCycle` | `R<n>/<duration>` | the same string, or `R<n>/<date-time>/<duration>` |

The existing `minutes`, `hours` and `days` attributes keep compiling and mean what they
mean now. A literal `timeDate` stays refused for the reason the refusal gives: a date typed
into a diagram published months before the token arrives is a deadline that may already be
gone. An expression is a date computed from the case in front of the engine, which is what
a deadline actually is.

**What an expression can read.** The same context a gateway condition reads at that node:
`subject` (only the paths the node declares in `ash:load`), `routing`, and on a user task
`task.inserted_at`, `task.due_at` and `task.follow_up_at` once §11.5's schedule has been
evaluated (so a reminder can be written as `= task.due_at - duration("P2D")`).
Months and years are still refused in a duration *literal*; inside a date expression they
are allowed (`= subject.renews_on_at - duration("P1M")` is calendar arithmetic FEEL defines),
because the result is recorded as an instant before anyone relies on it. If `boxic_feel`
does not implement a date-time minus a years-and-months duration, that case is a timer
incident rather than an approximation, and T1's tests say which.

**When the data is missing or wrong.** An expression that returns `null`, or a value of the
wrong type (a `date` without a time, a date-time without an offset, a non-positive duration,
a years-and-months duration where a duration is required, a cycle with no count), is a
**timer incident**: the step that would arm it fails, the instance is marked failed at that
node with a `:timer_unresolved` process event naming the node, the timer, the expression
and the reason, and the job is not retried, because the same data gives the same answer.
Nothing parks without its deadline. A modeller who wants a fallback writes it in the
diagram: `= if subject.notice_at != null then subject.notice_at else now() + duration("P30D")`.

**When the moment has already passed.** A `date` (or the first repetition of a `cycle`)
that resolves to the past fires at once, as BPMN engines do, and its `:timer_fired` event
carries `"late" => true` and the instant it was due. An `ash:timer` may say `ifPast="skip"`
instead; a skipped timer writes a `:timer_skipped` event and a ledger row ending
`cancelled` with reason `:past`, so "why was nobody reminded?" still has an answer. `skip`
is refused on `kind="expire"`: an expiry is an outcome, and skipping it would leave a task
open past its own deadline with nobody told. For a cycle whose start is in the past, the
repetitions already missed are skipped (one `:timer_skipped` event counting them) and the
next one at or after now is armed.

**When the data changes later.** Nothing moves by itself; an armed instant is a fact.
`AshBpmn.reschedule_timers(subject, opts)` re-evaluates every data-driven timer still
armed for live tasks and parked tokens of that subject's instances: each moved timer's
ledger row is cancelled with reason `:rescheduled` and a new one armed, a timer whose new
instant is past follows the `ifPast` rule, timers that have already fired are left alone,
and one `:timers_rescheduled` event records old and new instants. A host calls it from the
change that moves the date, in the same transaction.

**Cycles.** A `cycle` must name its count: `R/...` (unbounded) and cron are refused,
and the count is at most 100. Cycles are allowed only where repeating means something: an
`ash:timer kind="remind"` and a non-interrupting timer boundary event. On `escalate`,
`expire`, an interrupting boundary or a catch event, a cycle is refused, because each of
those fires once by its nature. The engine arms one repetition at a time, each with its own
ledger row; the next is armed in the job that fires the current one, and none is armed once
the activity has ended.

### 11.4 What a fired timer guarantees

- **One event per fired timer.** `:timer_fired`, carrying the timer's key, its kind, the
  repetition number and `late`. Under at-least-once delivery the event may be written more
  than once for one firing; readers count distinct keys.
- **A stable key.** `"<task or token id>/<node id>/<timer index>/<repetition>"`, where the
  index is the timer's position in the node's `ash:timers` (or the boundary's id). It is the
  same on every retry of a firing and different for every repetition, and it is the
  idempotency key a host deduplicates notices on. It does not depend on the timer ledger
  being installed. The ledger is still recommended, and its row id is carried beside the key
  when it is.
- **Nothing for work that is over.** A timer for a task that is completed or cancelled, or a
  token that has moved on, fires nothing and delivers nothing; its ledger row is cancelled
  with the reason the task ended.
- **Start and completion deadlines.** An `ash:timer` may say `until="claimed"` (WS-HumanTask's
  start deadline): it is cancelled, with reason `:claimed`, when someone claims the task, and
  is not re-armed if the task is released. The default, `until="completed"`, is the
  completion deadline and runs until the task ends. This is what lets "nobody has picked up
  this page in fifteen minutes" escalate without also escalating a page someone is working.

### 11.5 Due date and follow-up date are data

A user task may carry a schedule:

```xml
<ash:taskConfig>
  <ash:schedule due="= subject.received_at + duration(&quot;P30D&quot;)" followUp="P21D"/>
  ...
</ash:taskConfig>
```

`due` and `followUp` take the same forms as a timer moment (a duration literal from task
creation, or an expression returning a date-time) and are evaluated once, when the task is
created, with §11.3's rules for missing and past values. They are written to
`HumanTask.due_at` (existing) and `HumanTask.follow_up_at` (new). They trigger nothing by
themselves, as in Camunda; timers do. A task with no `due` but an `expire` timer takes the
expire instant as its `due_at`, since that is its completion deadline. `reschedule_timers/2`
re-evaluates both.

The HumanTask macro gains, so that hosts stop writing the same read twice: an `overdue?`
calculation (`due_at < now()`), a `:overdue` read (open or claimed, `due_at` in the past,
oldest due first) and a `:follow_up_due` read. A task with no `due_at` is neither overdue
nor on time: these reads leave it out, and a host that wants an age rule for tasks with no
deadline keeps one for exactly those tasks.

### 11.6 Escalation adds people; the engine keeps the exclusions

**[host-breaking: changed callback contract]**

```elixir
@callback escalate(task :: map(), ctx :: map()) ::
            {:ok, [principal()]} | {:error, term()}
```

`escalate/2` answers whom to add. `ctx` carries `:tenant`, `:instance`, `:subject` (loaded
with the node's `ash:load`), `:task`, `:candidates` (the task's current candidate
principals), `:exclusions` (`task.excluded_principal_ids`), `:timer` (its key and
repetition) and `:actor` (the instance's starter, as elsewhere). The engine, not the host:

1. subtracts the task's exclusions from the answer, as `AssignmentResolver.settle/4` does for
   the nobody-eligible fallback, so an escalation never hands a task to someone maker-checker
   excluded;
2. writes the remaining principals as new `TaskCandidate` rows in the task's tenant, and
   never removes a candidate or the assignee. WS-HumanTask's reassignment *replaces* the
   potential owners; widening is chosen instead, because the people already holding a
   review are usually still the right people to finish it, and taking it from someone
   mid-work is a separate act (delegation) with its own audit;
3. records `:task_escalated` with the added and the refused-as-excluded ids, then hands the
   notice (§11.7) to the deliverer;
4. treats `{:ok, []}`, or an answer the exclusions empty, as **an escalation that reached
   nobody**: an `:escalation_reached_nobody` event, the same shape as
   `:no_eligible_candidate`, so a host can raise a finding from it in the same transaction.
   It is not retried: the same organization gives the same answer.

`{:error, _}`, a raise or any other shape is `:escalation_failed` and is retried, as today.
The host's side of the contract, which the engine cannot check and the host's tests must:
resolve only in `ctx.tenant`, and when a team is added, its members who are excluded can
still never act (the engine's candidacy check already subtracts excluded ids from team
membership at claim time).

An escalate timer with `signal="..."` keeps its current meaning: it throws the signal and
calls no resolver.

### 11.7 Notices go through one host behaviour

**[host-breaking only through §11.8]**

```elixir
defmodule AshBpmn.TaskNotifier do
  @callback deliver(notice :: AshBpmn.Notice.t(), ctx :: map()) :: :ok | {:error, term()}
end
# config :ash_bpmn, task_notifier: MyApp.Bpmn.Notices
```

`AshBpmn.Notice` carries `key` (§11.4), `kind` (`:remind | :escalated | :expired`), `task`,
`recipients`, `added` (on `:escalated`), `due_at`, `late`, `repetition` and `tenant`.
`recipients` is computed by the engine: the assignee when the task is claimed, otherwise its
candidate principals, plus on `:escalated` the principals just added, always minus the
task's exclusions. The host turns principals into people and addresses, chooses the channel
(in-app, mail) and the words. WS-HumanTask's notification is a kind of task with no outcome;
here it is a delivery with no outcome, which is all a reminder needs, and a host that wants
an inbox of them keeps its own rows keyed by `key`.

What the engine guarantees: `deliver/2` is called after the timer's state changes have
committed, so a failed delivery never undoes an escalation; it is called at least once per
fired timer, again on every retry with the same `key`, and a host must make delivery
idempotent by that key; success writes `:notice_delivered`; an error is retried by Oban and
the final failure writes `:notice_failed`. An `expire` with a notifier configured delivers
an `:expired` notice; without one it still expires, since expiry routes the graph and does
not depend on anyone being told.

A timer that fires on a host with no notifier configured (possible only for definitions
published before §11.8) writes `:notice_undelivered` with reason `:no_notifier` and emits
`[:ash_bpmn, :notice, :undelivered]` telemetry. Missing is never recorded as a pass.

### 11.8 Fail closed at publication

**[host-breaking: publish-time refusals]**

Checked in `Compiler.Verify` beside the decision-resolver check, so a draft carrying them has
compile errors and cannot be published:

- a `remind` timer, or a cycle, when no `:task_notifier` is configured;
- an `escalate` timer without `signal`, when the assignment resolver does not export
  `escalate/2` or no `:task_notifier` is configured;
- `escalate_in` or `remind_in` on `Changes.RequireApproval` under the same conditions,
  refused when the approval is created (the change has no publish step);
- an `ash:timer` with no kind, an unknown kind, no moment, more than one moment, a
  non-integer `minutes`/`hours`/`days`, `ifPast="skip"` on `expire`, or `until="claimed"` on
  `expire`;
- every cycle §11.3 refuses.

Definitions already published are immutable and keep running; their timers are covered by
§11.7's `:notice_undelivered` rather than by a refusal. What changes for a host is the
next draft: a host that publishes a definition with remind or escalate timers must
configure a notifier and implement `escalate/2` first. This is the lesson of the business
rule task's resolver check, applied to people: a diagram that declares something the host
has not wired up is refused where a person is looking at it.

### 11.9 Supported now, later and not

| Construct | Decision |
|---|---|
| `timeDate`, `timeDuration`, `timeCycle` as expressions; `ash:timer` `date`/`duration`/`cycle` | now (§11.3) |
| due date, follow-up date, start and completion deadlines | now (§11.4, §11.5) |
| escalation that adds people, notices through one behaviour, fail-closed publication | now (§11.6 to §11.8) |
| message boundary events, interrupting and non-interrupting, on user tasks, receive tasks and call activities | next, after the slices above. The correlation (`ash:subscribe`) and the claim-the-parked-token race already exist for message catches and timer boundaries; a message boundary is their composition, and it is what "stop waiting for this review when the alert resolves itself" needs. |
| BPMN escalation events (`escalationEventDefinition`) | not now. BPMN's escalation is a non-critical signal from a child scope to its parent; it is not a deadline on a person, and nothing asks for it. Deadline escalation is §11.6. The refusal stays and its error names §11.6, because the two share a word. |
| timer start events, unbounded cycles, cron | refused. A process that starts on a clock belongs to the host's scheduler (an AshOban scheduled action or trigger), where the population it starts for is a query the host owns. |
| business calendars ("five business days") | later. FEEL has no business-day arithmetic. When it is needed it is a host behaviour the expression context calls, so the calendar is host data, not engine data. |
| WS-HumanTask business administrators as a role the engine knows | not now. The resolver's fallback and escalation clauses already name them in host terms. |

### 11.10 Slices

- **T1** (engine, mergeable): compiler refusals for malformed `ash:timer`; `ash:timer`
  `duration`/`date` and BPMN expression `timeDate`/`timeDuration`; arm-time evaluation, the
  timer incident, `ifPast`; the stable key; `until="claimed"`; the designer's moddle
  descriptor for the new attributes.
- **T2** (engine, mergeable): bounded cycles on remind timers and non-interrupting timer
  boundaries; `reschedule_timers/2`.
- **P1** (engine, mergeable): `ash:schedule`, `follow_up_at` (a new column, so hosts run
  `mix ash.codegen` when they take it), `overdue?`, `:overdue`, `:follow_up_due`; the
  `escalate` context gains `:tenant`, `:instance`, `:subject`, `:candidates`,
  `:exclusions`, `:timer`.
- **P2** (engine, **host-breaking**, separate PR): the `escalate/2` contract, the
  `TaskNotifier` behaviour and notice events, §11.8's refusals.
- **Hosts**: an `escalate/2` and a `TaskNotifier` each, the timer ledger installed, then
  timers on their diagrams.
