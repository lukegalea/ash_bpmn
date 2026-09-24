<!--
SPDX-FileCopyrightText: 2026 Luke Galea
SPDX-License-Identifier: MIT
-->

# The flight view

A flight view is a process diagram with one live marker per running token — a
patient avatar, a case badge — positioned on the node the token is standing on
and moved in real time as the process runs. Three APIs in `AshBpmn.FlightView`
give a host everything it needs to build one:

1. **`mermaid/2`** renders a published definition as a mermaid flowchart, with
   node ids that are the definition's own element ids.
2. **`token_positions/2`** answers "where is everything right now": one entry
   per live token, with the node id, the token status, and the instance's
   subject passthrough.
3. **The subscription contract**: the engine broadcasts every token movement on
   Phoenix PubSub topics, so the view moves its markers as the process runs
   instead of polling forever.

## The mermaid rendering

```elixir
definition = MyApp.Bpmn.Definition.latest_published!("visit_flow") |> hd()
{:ok, mermaid} = AshBpmn.FlightView.mermaid(definition)
```

produces (for a small visit-like process):

```
flowchart TD
Start_1(["Start"])
Triage["Triage"]
Approve_1(["End"])
Start_1 --> Triage
Triage --> Approve_1
```

Three properties make this usable as an overlay canvas:

* **Node ids round-trip.** The mermaid node id *is* the definition's element id
  whenever the id is one mermaid can carry — letters, digits and underscores,
  not starting with a digit, and not the reserved word `end` (which mermaid
  cannot parse as a node id at all; it is renamed `node_end` by a documented
  rule). bpmn-js authors exactly those ids, so definitions drawn in the
  designer round-trip untouched, and an overlay positioned "by node id" lands
  on the element the token is standing on. Ids that fail that test are
  sanitized deterministically; see the `mermaid/2` moduledoc for the rule.
* **The shapes mean something.** Gateways render as diamonds, events as
  circles (double for an end), a call activity as a subroutine box, tasks as
  rectangles — so a reader sees the process, not just a graph.
* **It is deterministic.** Nodes in id order, edges in flow order, byte-identical
  output for the same graph. Pin it in a test if you like; the engine's own
  suite does.

Boundary events are drawn attached to their activity by a dotted edge, and a
sequence flow carrying a FEEL condition is drawn with that condition as its
edge label — `Gateway -->|"subject.amount > 100"| Task_A` — with `default`
marking the default flow.

## Token positions

```elixir
{:ok, positions} = AshBpmn.FlightView.token_positions(MyApp.Bpmn,
  definition: definition
)
```

One entry per live token (`active`, `executing` or `waiting`) across every
running instance pinned to that definition:

```elixir
%{
  instance_id: "…",
  instance_status: "running",
  definition_id: "…",
  definition_key: "visit_flow",
  definition_version: 3,
  subject_type: "Elixir.MyApp.Clinical.Visit",
  subject_id: "…",
  correlation_id: nil,
  started_by_id: "…",
  tenant_id: nil,
  token_id: "…",
  node_id: "ManagerApproval",
  node_type: "userTask",
  node_name: "Manager approval",
  status: "waiting",
  parked_at: "2026-09-24T10:12:33.104Z",
  token_created_at: "2026-09-24T10:12:31.001Z"
}
```

**`subject_type` and `subject_id` are join keys, not records.** An instance
references its business record by module name and id — that is all the engine
ever stores — and the host resolves the patient, the appointment, the purchase
order itself, at query time, through its own domain and its own authorization.
The engine deliberately does not read the host's tables here. A patient avatar
is the host's `subject_id` rendered; the engine supplies the position.

Narrow with arguments rather than filtering afterwards — every option maps
onto the engine's own `:in_flight` reads: `:definition` / `:definition_id` /
`:definition_key`, `:instance_ids`, and the status lists if you need more than
running instances with live tokens. With no `:actor` the read runs as the
engine's system actor; pass `:actor`/`:tenant` to run it under a caller's own
authority and policies instead.

## Live updates

Configure a PubSub server and the engine broadcasts on every token transition
— create, claim, park, wake, consume, kill, reactivate — on two topics:

| Topic | Payloads |
| --- | --- |
| `bpmn:tokens:definition:<definition_id>` | every token of every instance pinned to that definition — the flight view's topic |
| `bpmn:tokens:instance:<instance_id>` | one instance's tokens — for a per-case side panel |

```elixir
config :ash_bpmn, pubsub_server: MyApp.PubSub
```

The payload is string-keyed and JSON-safe, and mirrors what
`token_positions/2` reports for the same token minus the diagram's own node
metadata (the view rendered the diagram; the node id is the key it positions
overlays by):

```elixir
%{
  "event" => "token_moved",
  "token_id" => "…",
  "instance_id" => "…",
  "definition_id" => "…",
  "node_id" => "ManagerApproval",
  "status" => "waiting",
  "subject_type" => "Elixir.MyApp.Clinical.Visit",
  "subject_id" => "…",
  "correlation_id" => nil,
  "instance_status" => "running",
  "tenant_id" => "…",
  "moved_at" => "2026-09-24T10:12:33.104Z"
}
```

Broadcasts happen after the write commits, in engine write order. Within one
hop a new token's creation is announced before the token it came from is
retired — the engine creates forward before it consumes behind — so a view
that patches as messages arrive will place the new marker before it removes
the old one, never the reverse.

### Subscribing

```elixir
defmodule MyAppWeb.Clinical.FlightLive do
  use Phoenix.LiveView

  def mount(_params, _session, socket) do
    definition = ...latest published...

    case AshBpmn.FlightView.subscribe(
           AshBpmn.FlightView.definition_topic(definition.id)
         ) do
      :ok -> :ok
      # No PubSub configured (or not running): poll instead.
      {:error, _} -> Process.send_after(self(), :refresh, 5_000)
    end

    {:ok, assign(socket, positions: positions(definition), definition: definition)}
  end

  def handle_info(%{"event" => "token_moved"}, socket) do
    # The broadcast is a hint, the query is the truth: refetch on movement.
    {:noreply, assign(socket, positions: positions(socket.assigns.definition))}
  end

  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, 5_000)
    {:noreply, assign(socket, positions: positions(socket.assigns.definition))}
  end

  defp positions(definition), do: AshBpmn.FlightView.token_positions!(MyApp.Bpmn, definition: definition)
end
```

### The broadcast is a hint, the query is the truth

A broadcast says "this token's row changed". PubSub gives no delivery
guarantee — a listener that was redeploying, or a second token that moved a
millisecond later, is invisible to it — and the payload is a snapshot, not a
stream. Views that must be exact re-fetch `token_positions/2` when a broadcast
arrives (immediately, or debounced); the broadcast exists so the refetch
happens *when something moved* instead of every five seconds forever.

### No PubSub is a supported configuration

With no `:pubsub_server` set, broadcasts are no-ops and `subscribe/2` returns
`{:error, :pubsub_not_configured}` — poll `token_positions/2` on an interval,
which is exactly what the built-in viewer LiveView has always done. A
configured-but-not-running PubSub is treated the same way (`:pubsub_not_running`),
and a broadcast that fails for any other reason is logged and swallowed: a
viewer that misses an update can re-query, and a process that raises because
nobody was watching has failed at the wrong job.

## What the engine does not do

* It does not resolve subjects into records — join keys only, per the
  architecture line: the graph orchestrates, it never reads your data model.
* It does not push positions over a socket for you — the topics are plain
  `Phoenix.PubSub` topics; render them through a LiveView, a channel, or a
  plain subscriber, as your host prefers.
* It does not redraw the diagram on movement. The mermaid output is a function
  of the pinned definition, which is immutable — render it once at mount and
  move the overlays.
