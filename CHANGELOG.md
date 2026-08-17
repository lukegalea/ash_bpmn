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
