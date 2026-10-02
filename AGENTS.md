<!--
SPDX-FileCopyrightText: 2026 Luke Galea
SPDX-License-Identifier: MIT
-->

# AGENTS.md

This is `ash_bpmn`, approvals and BPMN processes for Ash, packaged as a
dependency.

## Agent constitution

This repository follows `AGENT_PRINCIPLES.md` v1.5, the agent constitution of
the ai-sdlc platform:
<https://github.com/lukegalea/ai-sdlc/blob/master/AGENT_PRINCIPLES.md>.
That file is the root policy for every agent session here. This file adds the
rules of this repository only. It does not replace or weaken the root policy.
If a rule here contradicts a security rule there, stop and ask a human. The
link opens only for people with access to the ai-sdlc repository. If you cannot
open it, these rules from it still apply:

- Do not approve your own work. A human approves every merge and every release.
- Do not put a secret in a file, a commit, a log, or a prompt.
- Do not publish anything outside this repository without human approval.
- Do not say that work is verified unless a CI result shows it.

## Project guidelines

- The BPMN XML document is the single artifact. There is no code DSL to keep in
  sync with the diagram. Publish compiles the document one way into an
  immutable, versioned graph snapshot.
- An instance pins its definition version for life. In-flight instances never
  depend on a currently loaded module.
- Maker-checker exclusion applies when the candidate list is built, never as a
  `forbid_if`. Candidates are `TaskCandidate` rows.
- The compiler rejects every BPMN element outside the supported subset, with
  the element id in the error. It never ignores an element.
- Gateway conditions are FEEL. This package has no expression language of its
  own.
- If you change the LiveViews or the designer hook, examine them in the `dev/`
  app in a browser. Then regenerate the affected screenshots.
- Changes are judged against the 26 Iron Laws. Read "The iron laws and the
  judge" in `usage-rules.md`.

## Before you finish

CI runs `mix compile --force --warnings-as-errors`, `mix test` (against
Postgres 16), `mix format --check-formatted`, `mix credo --strict`,
`mix dialyzer`, `mix docs`, `mix deps.unlock --check-unused`, `mix deps.audit`,
and a REUSE check. Run them before you finish.

## Generated sections

This repository does not run `mix usage_rules.sync` today. If it starts to, the
task adds its own section at the end of this file, between its
`usage-rules-start` and `usage-rules-end` markers. Do not edit text inside
those markers. Keep the rules of this repository above them.
