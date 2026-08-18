<!--
SPDX-FileCopyrightText: 2026 Luke Galea

SPDX-License-Identifier: MIT
-->

# Authorization and tenancy

Three things about this package were true at once and should not have been.

Every generated resource declared `authorizers: [Ash.Policy.Authorizer]` and then
shipped no policies at all. The engine reached past that authorizer with
`authorize?: false` at ninety call sites. And `AshBpmn.start_instance/2`
documented a `:tenant` option that it bound to `_tenant` and discarded, while the
resource macros generated an `organization_id` multitenancy strategy nothing ever
set.

Each was individually defensible. Policy belongs to the host; a process engine
has to write rows no person is allowed to write; multitenancy was declared and
simply not finished. Together they meant the package shipped an unauthorized path
into the tables it manages, with nothing in any policy set to show for it, and a
tenant-scoped install in which no row carried a tenant.

This topic is what replaced all three.

## The scope

`AshBpmn.Scope` is an actor, a tenant and a domain, resolved once at the boundary
of a public function and threaded down through everything it calls.

```elixir
scope = AshBpmn.Scope.from_opts(opts)          # a caller's :actor and :tenant
scope = AshBpmn.Scope.from_record(instance)    # a record already loaded
scope = AshBpmn.Scope.from_job(args, :advance) # an Oban payload
```

`from_record/2` is the one worth understanding. Attribute multitenancy means the
row knows which tenant it belongs to, so an operation on a record already in hand
does not have to be told again — `cancel_instance/2` reads `organization_id` off
the instance. An explicit `:tenant` still wins, for the cases where the caller
knows better.

Background work is different, because a job outlives the process that enqueued
it. The tenant and the BPMN domain therefore travel **in the job args**:

```elixir
AshBpmn.Runtime.Oban.insert(
  AshBpmn.Runtime.AdvanceWorker,
  AshBpmn.Scope.to_job_args(scope, %{"instance_id" => id, "node_id" => node})
)
```

Carrying the domain fixed a second bug on the way past. Workers used to call
`AshBpmn.Runtime.DomainResolver.resolve!/0`, which searched the configured
domains and took the first with all six resource kinds. With one BPMN domain that
is always right. With two it is a coin toss that lands the same way every time,
so the second domain's instances were advanced against the first domain's tables.

## The engine's own authority

Engine calls now look like this:

```elixir
Ash.read_one!(query, AshBpmn.Scope.engine(scope))
```

`engine/2` sets `actor`, `tenant`, and `context: %{private: %{ash_bpmn?: true}}`.
Every generated resource carries one policy that recognises the last of those:

```elixir
policies do
  bypass AshBpmn.Checks.AshBpmnInteraction do
    authorize_if always()
  end
end
```

This is not a stronger security boundary than `authorize?: false` was. Anything
that can set private context could have passed the option, so the engine is no
harder to impersonate from inside the same BEAM. What changed is that the
engine's authority is now **one named thing in the policy set** instead of ninety
anonymous ones scattered through the facade, the workers and the LiveViews — so a
host reading a resource's policies can see the engine path, reason about it, and
replace it.

The actor stays the human. Substituting a system actor would have been simpler
and would have thrown away the thing a host base resource needs most: ownership,
provenance and the audit entry all derive from the actor, and completing a task
has to be attributable to the person who completed it. Only work with genuinely
nobody behind it — a timer, a sweep, an advance running long after the request
that triggered it — carries an `AshBpmn.SystemActor`, and it carries a named one
so the trail says "the timer worker did this" rather than saying nothing.

There is exactly one remaining `authorize?: false`, and it has a name:
`AshBpmn.Scope.subject/2`, for loading the host's subject record. An engine scope
is no use there — the flag is recognised by a policy this package generates, and
a host's own resource has no such policy, so an engine scope on a subject read is
a denied read swallowed by the `rescue` around it and surfacing much later as a
gateway that took the wrong branch. A test in `policies_test.exs` fails the build
if a second exception appears.

## Sitting on a base resource

Every resource macro takes `:base`:

```elixir
defmodule MyApp.Bpmn.HumanTask do
  use AshBpmn.Resources.HumanTask,
    domain: MyApp.Bpmn,
    repo: MyApp.Repo,
    instance: MyApp.Bpmn.Instance,
    token: MyApp.Bpmn.Token,
    base: MyApp.Platform.Resource,
    base_opts: [ownership: :organization_owned, cdm_entity: "Task"]
end
```

so a work item inherits whatever the application arranged for every other record
it owns. With `:base` the macro stops emitting `data_layer:` and `authorizers:`
(the base's decision) and stops emitting tenancy (a base worth having already
owns it — combining `:base` with `tenant?: true` raises rather than producing a
resource with two multitenancy strategies).

### The ordering rule

One constraint comes with this, and it is Ash's rather than ours. Policies are
folded into a single boolean expression in which a bypass contributes a disjunct
covering the policies **after** it. A bypass therefore skips only what follows it.

That is automatic when the macro owns the whole policy set — the bypass is the
only policy there is — and it is automatic for a host adding `policies do … end`
*after* the `use`. It is not automatic with `:base`, because `use <base>` expands
first and the base's policies land ahead of the bypass. On such a resource the
engine is forbidden.

A host in that position has two ways out, and `base_resource_test.exs` pins both:

1. **Put the bypass first in the base's own policy set.**

   ```elixir
   policies do
     bypass AshBpmn.Checks.AshBpmnInteraction do
       authorize_if always()
     end

     # … the rest of the base's policies
   end
   ```

2. **Act as an actor the base already admits**, when changing the base is not an
   option:

   ```elixir
   config :ash_bpmn, engine_actor: {MyApp.Platform.SystemActor, :system, []}
   ```

   The cost, and the reason this is not the default: every engine write is then
   attributed to that system actor, and the human survives only in the columns the
   engine writes explicitly — `started_by_id`, `decided_by_id`, `assignee_id`.

`policies?: false` removes the generated bypass entirely and hands the host the
whole policy set, including whatever the engine needs. With an authorizer and
nothing to satisfy it, such a resource refuses everyone — which is the correct
consequence rather than an oversight, and is asserted as such.

## What the suite proves

- `tenancy_test.exs` runs a process end to end with `tenant:` set, against a
  second, tenant-scoped copy of the tables, and asserts the tenant lands on the
  instance, its tokens and its events — including the ones the advance worker
  creates, which is also an assertion that the tenant survived the Oban payload.
  It asserts a second tenant cannot see any of it, and that two tenants run the
  same process key independently.
- `policies_test.exs` asserts each generated resource carries exactly the engine
  bypass, that a read with the engine context is allowed and one without it is
  forbidden even with a plausible actor, and that no module under `lib/` passes
  `authorize?: false`.
- `base_resource_test.exs` asserts a based resource keeps its data layer, table
  and actions, carries both policy sets, and behaves as the ordering rule above
  says it does — in both directions.
