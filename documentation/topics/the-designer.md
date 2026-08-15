<!--
SPDX-FileCopyrightText: 2026 Luke Galea
SPDX-License-Identifier: MIT
-->

# The designer

The designer is [bpmn-js] — the Camunda-maintained, bpmn.io-licensed modeller that
every embeddable BPMN editor ultimately is — wrapped in a LiveView hook and a
server-rendered properties panel. This page is how to embed it, how the `ash:`
bindings work, and the one licence obligation you cannot skip.

## Embedding in a Phoenix app

The hook ships as plain ESM in the package (`priv/js/ash_bpmn_designer.js`), the
same pattern ash_a2ui uses. Your app owns the npm dependency so the designer
shares your bundle's diagram-js instance rather than shipping a second one.

```jsonc
// assets/package.json
{ "dependencies": { "bpmn-js": "^18.0.0" } }
```

```js
// assets/js/app.js
import {AshBpmnDesigner, AshBpmnViewer} from "../../deps/ash_bpmn/priv/js/ash_bpmn_designer.js"

let liveSocket = new LiveSocket("/live", Socket, {
  hooks: {AshBpmnDesigner, AshBpmnViewer}
})
```

The hook imports bpmn-js and its stylesheets itself; esbuild resolves them from
your `assets/node_modules`. Two LiveViews are wrapped by host modules:

```elixir
defmodule MyAppWeb.Bpmn.DesignerLive do
  use AshBpmn.Web.DesignerLive,
    domain: MyApp.Bpmn,
    process: "access_request",
    actor: {MyAppWeb.Bpmn.Helpers, :current_actor, []}
end
```

The canvas is the client's; the properties panel is the server's. When you select
an element, the hook pushes `selection_changed` and the LiveView renders the
appropriate form — candidates, exclusions, outcomes, timers for user tasks; the
action reference for service tasks. Edits come back as `apply_config` and the hook
rewrites the element's `extensionElements` from scratch via moddle — never
merged, so a config panel can never leave an element in a half-edited state. Save
asks the hook for `saveXML({format: true})` and stores the document; publish runs
the compiler and, on success, freezes the version.

## The `ash:` namespace

BPMN's extension mechanism is `extensionElements` plus a namespace — the standard
way vendors from Camunda to Flowable attach execution bindings to a diagram.
`ash:` uses it for exactly the things a process needs from Ash:

| Element | On | Carries |
|---|---|---|
| `ash:taskConfig action="..."` | serviceTask | the `ActionInvoker` reference |
| `ash:taskConfig` | userTask | candidates, exclusions, outcomes, timers |
| `ash:outcome name` | userTask config | one allowed decision value |
| `ash:candidate kind="..." of="..."` | userTask config | a resolver clause (opaque to the library) |
| `ash:exclusion who="..."` | userTask config | a maker-checker subtraction |
| `ash:timer kind hours/days/minutes` | userTask config | remind / escalate / expire |
| `ash:taskConfig outcome="..."` | endEvent | the instance outcome |

Candidate and exclusion specs are **opaque strings** to ash_bpmn. `kind="manager_of"
of="subject.created_by_id"` means whatever your `AshBpmn.AssignmentResolver` says
it means — the library refuses to know what a manager is, for the same reason it
refuses to know what an approval policy is: both are domain, and domain lives in
the host.

Because bpmn-moddle drops namespaces it has no descriptor for, the hook registers
a moddle descriptor for the full `ash:` vocabulary. The compiler accepts exactly
that vocabulary and nothing more — an unknown `ash:` attribute is a compile error
naming the element, which is typo protection, not pedantry: a designer-typed
`candiates` element that silently vanished would be indistinguishable from an
unassigned task until nobody's task list showed it.

## Versioning and the designer

The designer edits the **draft** row of a definition key. Publish freezes it as a
new version; the designer then starts the next draft from the published XML.
In-flight instances are untouched — they pin the version they started. The
instance viewer renders the pinned version's graph, not the latest draft, which
means what an operator sees is what the instance is actually executing.

## The watermark

bpmn-js is not MIT. It is MIT **plus one clause**: the "Powered by bpmn.io"
watermark that renders on the canvas must not be removed or changed, must stay
fully visible, and must not be overlapped by other elements.

For an internal tool this is a shrug. For a white-labelled product shipped to
enterprise customers it is a procurement conversation. ash_bpmn leaves the
watermark untouched, and so must you — hiding it is a licence violation, not a
styling choice. Plan the bottom-right corner of your canvas accordingly.

[bpmn-js]: https://github.com/bpmn-io/bpmn-js
