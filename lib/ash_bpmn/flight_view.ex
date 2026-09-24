# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.FlightView do
  @moduledoc """
  The live process flight view: what a host needs to draw a process diagram and
  place live tokens on it.

  A flight view is a rendering of a published definition with one marker — a
  patient avatar, a case badge — per live token, moved in real time. Three APIs
  build it:

    * `mermaid/2` renders the definition's graph as a mermaid flowchart. Node ids
      are the definition's own element ids, so overlays positioned by mermaid node
      id land on the element the token is standing on.
    * `token_positions/2` answers "where is everything right now": one entry per
      live token of the definition's instances, carrying the node id, the token
      status, and the instance's subject passthrough — `subject_type`/`subject_id`
      are the join keys to the host's own business record, which the host resolves
      at query time. The engine deliberately does not resolve them itself.
    * The subscription contract: `definition_topic/1` and `instance_topic/1` name
      the two Phoenix PubSub topics the engine broadcasts token movement on, and
      `subscribe/2`/`unsubscribe/2` are thin wrappers over them. Every token
      transition the engine makes — create, claim, park, wake, consume, kill,
      reactivate — is broadcast after it commits, so a view can patch one node
      instead of repolling the world.

  A host that runs no PubSub (or sets no `:pubsub_server`) gets silent no-ops for
  the broadcasts and falls back to polling `token_positions/2` on an interval —
  the same polling the built-in viewer LiveView does. See
  [the flight view](documentation/topics/flight-view.md) for a worked example.

  ## The broadcast is a hint, the query is the truth

  A broadcast says "this token's row changed; here is its now-state". It carries
  the state as it was when the engine sent it, and PubSub gives no delivery
  guarantee — a listener that was down, or a second token that moved a
  millisecond later, is invisible to it. Views that must be exact re-fetch
  `token_positions/2` (immediately, or debounced); the broadcast exists so the
  refetch happens when something actually moved instead of every five seconds
  forever.
  """

  require Logger

  alias AshBpmn.Config
  alias AshBpmn.Scope

  @live_token_statuses [:active, :executing, :waiting]
  @running_instance_statuses [:running]

  @typedoc "One live token of one instance, with the instance's own passthrough."
  @type position :: %{
          required(:instance_id) => Ecto.UUID.t(),
          required(:instance_status) => String.t(),
          required(:definition_id) => Ecto.UUID.t(),
          required(:definition_key) => String.t() | nil,
          required(:definition_version) => pos_integer() | nil,
          required(:subject_type) => String.t() | nil,
          required(:subject_id) => Ecto.UUID.t() | nil,
          required(:correlation_id) => String.t() | nil,
          required(:started_by_id) => Ecto.UUID.t() | nil,
          required(:tenant_id) => term(),
          required(:token_id) => Ecto.UUID.t(),
          required(:node_id) => String.t(),
          required(:node_type) => String.t() | nil,
          required(:node_name) => String.t() | nil,
          required(:status) => String.t(),
          required(:parked_at) => String.t() | nil,
          required(:token_created_at) => String.t() | nil
        }

  # ── The mermaid rendering ────────────────────────────────────────────────

  @doc """
  Renders a definition's graph as a mermaid flowchart.

  Accepts a definition record (anything with a `graph` field) or a compiled graph
  map — the same map `AshBpmn.Compiler.compile/1` produces and a published
  definition stores. Returns `{:error, :no_graph}` for a definition whose graph is
  absent — a draft that has never compiled has nothing to render, and an empty
  diagram would make "did not compile" and "has no nodes" look the same.

  ## Options

    * `:direction` — the mermaid flowchart direction (default `"TD"`).

  ## Node ids

  The emitted mermaid node id is the definition's element id, verbatim, whenever
  the id is one mermaid can carry: letters, digits and underscores, not starting
  with a digit, and not the reserved word `end` (which mermaid cannot parse as a
  node id at all). bpmn-js authors exactly those ids, so every definition drawn
  in the designer round-trips untouched. Anything else — an id with spaces or
  punctuation, or literally `end` — is sanitized deterministically (`end` becomes
  `node_end`; other unsafe ids get an `n_` prefix and their unsafe characters
  become underscores), which keeps the diagram renderable at the cost of the
  overlay mapping for those ids. Hosts that restrict element ids at authoring
  time never meet the sanitizer.

  ## What is drawn

  One node per compiled element, shaped by type — gateways are diamonds, events
  are circles, a call activity is a subroutine box — one edge per sequence flow,
  labelled with its FEEL condition or `default` where the diagram declares one,
  and one dotted edge from an activity to each boundary event attached to it.
  Output is deterministic: nodes in id order, edges in flow order, so the same
  graph always renders byte-identical markdown.
  """
  @spec mermaid(map() | struct(), keyword()) :: {:ok, String.t()} | {:error, :no_graph}
  def mermaid(definition_or_graph, opts \\ [])

  def mermaid(%{graph: graph}, opts) when is_map(graph) and map_size(graph) > 0,
    do: {:ok, render(graph, opts)}

  def mermaid(%{graph: _}, _opts), do: {:error, :no_graph}

  def mermaid(graph, opts) when is_map(graph) and map_size(graph) > 0,
    do: {:ok, render(graph, opts)}

  def mermaid(_definition_or_graph, _opts), do: {:error, :no_graph}

  @doc "Like `mermaid/2`, raising `ArgumentError` on a definition without a graph."
  @spec mermaid!(map() | struct(), keyword()) :: String.t()
  def mermaid!(definition_or_graph, opts \\ []) do
    case mermaid(definition_or_graph, opts) do
      {:ok, text} ->
        text

      {:error, :no_graph} ->
        raise ArgumentError,
              "AshBpmn.FlightView.mermaid! needs a compiled graph; this definition has none " <>
                "(a draft that has not compiled, or a graph that failed to compile)"
    end
  end

  defp render(graph, opts) do
    direction = Keyword.get(opts, :direction, "TD")
    nodes = graph["nodes"] || %{}
    flows = graph["flows"] || %{}
    boundaries = graph["boundaries"] || %{}

    node_lines =
      nodes
      |> Enum.sort_by(fn {id, _} -> id end)
      |> Enum.map(fn {id, node} -> node_line(id, node) end)

    boundary_lines =
      boundaries
      |> Enum.sort()
      |> Enum.flat_map(fn {attached, boundary_ids} ->
        Enum.sort(boundary_ids)
        |> Enum.map(fn boundary_id -> "#{node_ref(attached)} -.-> #{node_ref(boundary_id)}" end)
      end)

    edge_lines =
      flows
      |> Enum.sort_by(fn {flow_id, flow} -> {flow["from"], flow["to"], flow_id} end)
      |> Enum.map(fn {flow_id, flow} -> edge_line(flow_id, flow, nodes) end)

    (["flowchart " <> direction] ++ node_lines ++ boundary_lines ++ edge_lines)
    |> Enum.join("\n")
    # Text output convention: the diagram ends with a newline, so a host can
    # write it straight into a `.mmd` file.
    |> Kernel.<>("\n")
  end

  defp node_line(id, node) do
    {open, close} = shape(node["type"])
    label = escape_label(node["name"] || node["type"])

    "#{node_ref(id)}#{open}\"#{label}\"#{close}"
  end

  # Mermaid delimiters around a quoted label, per node type. The bracket styles
  # are mermaid's own shapes: stadium for a start, double circle for an end,
  # diamonds for gateways, circles for events, a subroutine box for a call
  # activity and plain rectangles for tasks.
  defp shape("startEvent"), do: {"([", "])"}
  defp shape("endEvent"), do: {"(((", ")))"}
  defp shape("exclusiveGateway"), do: {"{", "}"}
  defp shape("parallelGateway"), do: {"{", "}"}
  defp shape("intermediateCatchEvent"), do: {"((", "))"}
  defp shape("intermediateThrowEvent"), do: {"((", "))"}
  defp shape("boundaryEvent"), do: {"((", "))"}
  defp shape("callActivity"), do: {"[[", "]]"}
  defp shape(_type), do: {"[", "]"}

  defp edge_line(flow_id, flow, nodes) do
    from = node_ref(flow["from"])
    to = node_ref(flow["to"])

    cond do
      flow["condition"] ->
        "#{from} -->|\"#{escape_label(condition_text(flow["condition"]))}\"| #{to}"

      node_default(nodes, flow["from"]) == flow_id ->
        "#{from} -->|\"default\"| #{to}"

      true ->
        "#{from} --> #{to}"
    end
  end

  defp node_default(nodes, node_id), do: get_in(nodes, [node_id, "default_flow"])

  # Conditions are stored as FEEL source text at publish time (usage rule 9);
  # `AshBpmn.Feel.print/1` returns that text for a parsed condition and passes a
  # plain string through.
  defp condition_text(condition), do: AshBpmn.Feel.print(condition)

  defp escape_label(label) do
    label
    |> to_string()
    |> String.replace("\"", "#quot;")
    |> String.replace("|", "#vert;")
    |> String.replace("\r", " ")
    |> String.replace("\n", " ")
  end

  @safe_id_regex ~r/^[A-Za-z_][A-Za-z0-9_]*$/

  # See the `mermaid/2` moduledoc section on node ids. The `end` case exists
  # because mermaid cannot parse that word as a node id at all — not escaped,
  # not quoted — so the honest choice is a documented rename over a diagram
  # that will not render.
  defp node_ref(id) when is_binary(id) do
    cond do
      id == "end" -> "node_end"
      id =~ @safe_id_regex -> id
      true -> "n_" <> String.replace(id, ~r/[^A-Za-z0-9_]/, "_")
    end
  end

  # ── Token positions ──────────────────────────────────────────────────────

  @doc """
  One entry per live token across a definition's instances.

  The flight view's query. Reads only the engine's own `:in_flight` actions — the
  same reads `AshBpmn.StateExport` is built on — so tenancy and authorization
  behave exactly as they do everywhere else.

  ## Options

    * `:definition` — a definition record; narrows to instances pinned to it.
    * `:definition_id` — the same, by id.
    * `:definition_key` — the same, by process key (latest published is *not*
      consulted: instances are matched on the key they were started with, which
      includes instances pinned to older versions of the process).
    * `:instance_ids` — restrict to these instances.
    * `:instance_statuses` — which instance statuses count (default
      `#{inspect(@running_instance_statuses)}`; pass
      `[:running, :failed, :errored, :cancelled, :superseded, :completed]` to see
      everything).
    * `:token_statuses` — which token statuses count as live
      (default `#{inspect(@live_token_statuses)}`).
    * `:actor`, `:tenant` — passed to `AshBpmn.Scope.from_opts/1`. With no actor
      the read runs as the `:engine` system actor, because a flight view is engine
      work with nobody behind it and `nil` would lose that distinction.

  `subject_type`/`subject_id`/`correlation_id` are the engine's passthrough of
  how the instance references its business record. They are join keys, not
  records: the host resolves the patient or appointment itself, at query time,
  through its own domain — the engine never reads the host's tables here.
  """
  @spec token_positions(module(), keyword()) ::
          {:ok, [position()]} | {:error, :missing_resources, [atom()]}
  def token_positions(domain, opts \\ []) do
    case AshBpmn.Resources.for_domain(domain) do
      {:ok, resources} ->
        {:ok, build_positions(resources, opts)}

      {:error, :missing_resources, kinds} ->
        {:error, :missing_resources, kinds}
    end
  end

  @doc "Like `token_positions/2`, raising on a domain that is not a complete BPMN domain."
  @spec token_positions!(module(), keyword()) :: [position()]
  def token_positions!(domain, opts \\ []) do
    case token_positions(domain, opts) do
      {:ok, positions} ->
        positions

      {:error, :missing_resources, kinds} ->
        raise ArgumentError,
              "#{inspect(domain)} is missing BPMN resources: #{inspect(kinds)}"
    end
  end

  defp build_positions(resources, opts) do
    scope = position_scope(opts)

    instances = read_instances(resources, scope, opts)
    instance_ids = Enum.map(instances, & &1.id)

    tokens =
      read_tokens(resources, scope, %{
        statuses: Keyword.get(opts, :token_statuses, @live_token_statuses),
        instance_ids: instance_ids
      })

    tokens_by_instance = Enum.group_by(tokens, & &1.instance_id)

    positions =
      Enum.flat_map(instances, fn instance ->
        graph = definition_graph(instance)

        Enum.map(Map.get(tokens_by_instance, instance.id, []), fn token ->
          position_entry(instance, token, graph)
        end)
      end)

    Enum.sort_by(positions, &{&1.instance_id, &1.token_id})
  end

  defp definition_graph(%{definition: %Ash.NotLoaded{}}), do: %{}
  defp definition_graph(%{definition: nil}), do: %{}
  defp definition_graph(%{definition: %{graph: nil}}), do: %{}
  defp definition_graph(%{definition: %{graph: graph}}) when is_map(graph), do: graph
  defp definition_graph(_), do: %{}

  defp position_entry(instance, token, graph) do
    element = graph["nodes"][token.node_id]

    %{
      instance_id: instance.id,
      instance_status: to_string(instance.status),
      definition_id: instance.definition_id,
      definition_key: definition_field(instance, :key),
      definition_version: definition_field(instance, :version),
      subject_type: instance.subject_type,
      subject_id: instance.subject_id,
      correlation_id: instance.correlation_id,
      started_by_id: instance.started_by_id,
      tenant_id: Map.get(instance, :organization_id),
      token_id: token.id,
      node_id: token.node_id,
      node_type: element && element["type"],
      node_name: element && element["name"],
      status: to_string(token.status),
      parked_at: timestamp(token.parked_at),
      token_created_at: timestamp(token.inserted_at)
    }
  end

  # The `:in_flight` action already loads `:definition`; these fields are read
  # from that load rather than re-queried. A definition that could not be loaded
  # (the host's loader refused it) degrades the key/version to nil rather than
  # hiding the tokens — a token whose definition cannot be named is exactly the
  # case a flight view must still show.
  defp definition_field(%{definition: %Ash.NotLoaded{}}, _field), do: nil
  defp definition_field(%{definition: nil}, _field), do: nil
  defp definition_field(%{definition: definition}, field), do: Map.get(definition, field)

  defp read_instances(resources, scope, opts) do
    # Through the `:in_flight` code interfaces, with arguments rather than
    # hand-built filters — the same path `AshBpmn.StateExport` reads through.
    # Arguments go in the interface call itself: arguments set on a query after
    # the fact lose to the action's argument defaults at read time, which is
    # not a race anyone should have to rediscover.
    definition_id =
      Keyword.get(opts, :definition_id) ||
        case Keyword.get(opts, :definition) do
          nil -> nil
          definition -> definition.id
        end

    args =
      %{
        statuses: Keyword.get(opts, :instance_statuses, @running_instance_statuses),
        definition_key: Keyword.get(opts, :definition_key),
        definition_id: definition_id,
        instance_ids: Keyword.get(opts, :instance_ids)
      }
      |> drop_nils()

    resources.instance.in_flight!(args, Scope.engine(scope))
  end

  defp read_tokens(_resources, _scope, %{instance_ids: []}), do: []

  defp read_tokens(resources, scope, args) do
    resources.token.in_flight!(drop_nils(args), Scope.engine(scope))
  end

  # An argument that is nil means "do not narrow on this", and the preparations
  # spell that as a nil-matching clause — but only if the argument was never set.
  defp drop_nils(params), do: params |> Enum.reject(&(elem(&1, 1) == nil)) |> Map.new()

  defp position_scope(opts) do
    case Keyword.get(opts, :actor) do
      nil -> %{Scope.system(:engine) | tenant: Keyword.get(opts, :tenant)}
      _actor -> Scope.from_opts(opts)
    end
  end

  # ── The subscription contract ────────────────────────────────────────────

  @doc """
  The PubSub topic every flight view of a definition subscribes to.

  `"bpmn:tokens:definition:<definition_id>"`. Movement of any token on any
  instance pinned to that definition arrives here, which is the topic a live
  process view is built on.
  """
  @spec definition_topic(Ecto.UUID.t() | String.t()) :: String.t()
  def definition_topic(definition_id), do: "bpmn:tokens:definition:" <> to_string(definition_id)

  @doc """
  The PubSub topic a single-instance view subscribes to.

  `"bpmn:tokens:instance:<instance_id>"`. The same payload as the definition
  topic, narrowed to one instance — the topic for a per-case side panel.
  """
  @spec instance_topic(Ecto.UUID.t() | String.t()) :: String.t()
  def instance_topic(instance_id), do: "bpmn:tokens:instance:" <> to_string(instance_id)

  @doc """
  Subscribes the calling process to a flight-view topic.

  Returns `{:error, :pubsub_not_configured}` when no `:pubsub_server` is set,
  and `{:error, :pubsub_not_running}` when one is configured but has no process
  — a host that is still starting up, or one that runs no PubSub at all. Either
  way the documented fallback is the same: poll `token_positions/2` on an
  interval. Options are passed to `Phoenix.PubSub.subscribe/3`.
  """
  @spec subscribe(String.t(), keyword()) ::
          :ok | {:error, :pubsub_not_configured} | {:error, :pubsub_not_running}
  def subscribe(topic, opts \\ []) do
    case Config.pubsub_server() do
      nil ->
        {:error, :pubsub_not_configured}

      pubsub ->
        if Process.whereis(pubsub) do
          Phoenix.PubSub.subscribe(pubsub, topic, opts)
          :ok
        else
          {:error, :pubsub_not_running}
        end
    end
  end

  @doc """
  Unsubscribes the calling process from a flight-view topic.

  Like `subscribe/2`, a no-op returning `{:error, :pubsub_not_configured}` when
  no `:pubsub_server` is set.
  """
  @spec unsubscribe(String.t()) :: :ok | {:error, :pubsub_not_configured}
  def unsubscribe(topic) do
    case Config.pubsub_server() do
      nil ->
        {:error, :pubsub_not_configured}

      pubsub ->
        Phoenix.PubSub.unsubscribe(pubsub, topic)
        :ok
    end
  end

  @doc """
  The broadcast payload for one token movement.

  String keys and JSON-safe values, because a payload that must survive a
  `Phoenix.PubSub` broadcast to a LiveView — and possibly through a serialization
  boundary a host adds — should not depend on atoms surviving the trip. The
  shape mirrors what `token_positions/2` reports for the same token, minus the
  diagram's own node metadata, which the view already has: it rendered the
  diagram, and the node id is the key it positions overlays by.
  """
  @spec token_payload(map(), map()) :: %{String.t() => term()}
  def token_payload(instance, token) do
    %{
      "event" => "token_moved",
      "token_id" => token.id,
      "instance_id" => instance.id,
      "definition_id" => instance.definition_id,
      "node_id" => token.node_id,
      "status" => to_string(token.status),
      "subject_type" => instance.subject_type,
      "subject_id" => instance.subject_id,
      "correlation_id" => instance.correlation_id,
      "instance_status" => to_string(instance.status),
      "tenant_id" => Map.get(instance, :organization_id),
      "moved_at" => DateTime.to_iso8601(DateTime.utc_now())
    }
  end

  @doc false
  # The engine's broadcast hook. Called at every site where a token's row
  # changes state, with the instance and the post-write token in hand — the
  # context is already there, so the broadcast costs one PubSub send and no
  # reads. Best-effort by contract: no PubSub configured, no PubSub process
  # running, or a broadcast that fails are all logged and swallowed, because a
  # viewer that misses an update can re-query and a process that raises because
  # nobody was watching has failed at the wrong job.
  @spec token_moved(map(), map()) :: :ok
  def token_moved(instance, token) do
    case Config.pubsub_server() do
      nil ->
        :ok

      pubsub ->
        broadcast(pubsub, instance, token)
        :ok
    end
  end

  defp broadcast(pubsub, instance, token) do
    if Process.whereis(pubsub) do
      payload = token_payload(instance, token)
      topics = [definition_topic(instance.definition_id), instance_topic(instance.id)]

      for topic <- topics do
        Phoenix.PubSub.broadcast(pubsub, topic, payload)
      end
    end
  rescue
    error ->
      Logger.debug(fn ->
        "ash_bpmn flight view broadcast failed (ignored): " <> Exception.format(:error, error)
      end)
  end

  defp timestamp(nil), do: nil
  defp timestamp(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp timestamp(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
end
