<!--
SPDX-FileCopyrightText: 2026 Luke Galea
SPDX-License-Identifier: MIT
-->

# The demo app

A small Phoenix application that hosts ash_bpmn the way a real application
would: it owns the repo, instantiates the six BPMN resources into its own
domain, implements `AshBpmn.AssignmentResolver` and `AshBpmn.ActionInvoker`, and
mounts the designer, viewer and task list LiveViews.

It exists for two reasons. The test suite can exercise the LiveView contracts,
but only a browser exercises bpmn-js — so a change to the hook or the properties
panel is not verified until it has run here. And the screenshots in the
documentation are captured from it, which keeps them honest.

It is dev-only: `elixirc_paths(:dev)` picks up `dev/lib`, the `files:` list in
`mix.exs` excludes everything here from the published package.

## Running it

```bash
mix deps.get
mix dev.assets   # npm install, then esbuild + tailwind into dev/priv/static
mix dev.setup    # create the database, migrate, seed
mix dev.server   # http://localhost:4008
```

`mix dev.reset` drops and re-seeds. The seeds publish `access_request` (the
diagram in `priv/access_request.bpmn`, which unlike the test fixtures carries
full BPMN DI so bpmn-js can lay it out), open the next draft for the designer to
edit, and leave three instances behind:

| Instance | State | What it demonstrates |
|---|---|---|
| `prod-db-readonly` | running | parked on a manager approval |
| `prod-db-admin` | running | privileged: forked into two parallel reviews, one claimed |
| `staging-deploy` | completed | a finished audit trail |

The signed-in user is hard-coded to Priya Raman, the requester's manager, so the
task list has candidate rows to show. The org chart lives in
`lib/ash_bpmn_dev/people.ex`.

There is no Oban instance: `config :ash_bpmn, oban_testing: :inline` in
`config/dev.exs` runs advance jobs synchronously and parks timers in ETS, so the
demo is a single process with no queue to babysit. A real host runs real Oban.

## Screenshots

With the server running:

```bash
node dev/screenshots/capture.mjs
```

writes the images in `documentation/assets/`. Requires `npx playwright install
chromium` once. Regenerate whenever the LiveViews change — a stale screenshot is
worse than none.
