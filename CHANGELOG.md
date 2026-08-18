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
