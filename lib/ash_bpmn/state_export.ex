# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.StateExport do
  @moduledoc """
  What is in flight right now, as a stable JSON shape.

  An instance pins a definition version for its whole life, which is what makes a running
  process safe to reason about — and what makes an upgrade a question rather than an event.
  Before anyone can answer *can these instances move to the new diagram?* there has to be a
  written-down answer to *what are they doing?*, in a form that survives being stored, mailed
  to somebody and compared against a later copy of itself. That is this module.

  `AshBpmn.Migration.Classifier` consumes it. So does a host's provenance envelope: the
  digests here are the same form (`AshBpmn.Canonical`) that an envelope's `input_digest` uses,
  so an exported token's `element_digest` and an envelope's `definition_version` are
  comparable artefacts rather than two conventions that both happen to say "sha256".

  ## What it holds, and what it refuses to hold

  Identifiers, statuses, timestamps, and digests of shapes. Not business data.

  A token carries almost nothing by design — node id, status, and routing signals a business
  rule task promoted — and the export keeps it that way. The two places where host data could
  leak through are handled explicitly:

    * **`routing`** is exported as its sorted *key* list plus a digest of the whole map. A
      routing signal is a scalar a gateway reads, and its name is a fact about the diagram
      while its value is a fact about the case.
    * **`correlation_key`** is the value an arriving event must equal — an invoice number, an
      account reference, a person's email if somebody modelled it that way. It is digested by
      default. `include_correlation_keys: true` emits it in the clear, for an operator
      debugging a correlation that is not matching, and the export records which of the two it
      is in `"correlation_keys"` so a consumer never has to guess whether a missing match is a
      redaction or a mismatch.

  `subject_id`, `correlation_id` and the tenant id stay in the clear. They are join keys with
  no meaning outside the system that issued them, which is the same line the enterprise
  provenance envelope draws for `actor_id` and `tenant_id`.

  ## Element digests are the load-bearing part

  For every node in every pinned definition the export records a digest of that node's
  *occupancy shape*: the node's own compiled config, its outgoing flows with their conditions,
  the boundary events attached to it, and its join specification if it is one. That is the
  complete set of things that decide what happens to a token sitting on that node.

  Two things are deliberately left out of the digest:

    * **`name`.** Renaming a task changes the diagram a person reads and nothing a token does.
      A classifier that called every rename a breaking change would be ignored within a week.
      The name is exported alongside the digest so a human reading a classification still sees
      what the node is called.
    * **Everything downstream.** A change three nodes ahead of a parked token is usually the
      *point* of the migration. Scoping the digest to occupancy is what makes "safe to
      continue" a meaningful answer rather than one nobody ever gets.

  ## Usage

      {:ok, export} = AshBpmn.StateExport.export(MyApp.Bpmn)
      File.write!("before.json", AshBpmn.StateExport.to_json(export))

  The reads behind it are ordinary Ash actions — `:in_flight` on the instance and token
  resources — so a host that wants a narrower slice can call those directly with the same
  arguments.
  """

  alias AshBpmn.Canonical

  @format "ash_bpmn.in_flight_state"
  @format_version 1

  @live_token_statuses [:active, :executing, :waiting]
  @all_instance_statuses [:running, :completed, :failed, :errored, :cancelled]

  # A call activity's child may itself call an activity. Following the chain to a fixpoint is
  # right; following it without a bound means a diagram that (incorrectly) recurses takes the
  # export with it. Ten is far beyond any process anyone draws, and hitting it is reported
  # rather than silently truncated.
  @max_child_depth 10

  @typedoc "The exported document: string keys, JSON-safe values, stable ordering."
  @type t :: %{String.t() => term()}

  @doc "The format identifier written into every export."
  @spec format() :: String.t()
  def format, do: @format

  @doc "The format version written into every export. Bumped when the shape changes."
  @spec format_version() :: pos_integer()
  def format_version, do: @format_version

  @doc """
  Exports the in-flight state of `domain`.

  ## Options

    * `:statuses` — instance statuses to include (default `[:running]`).
    * `:definition_key` — restrict to one process key.
    * `:instance_ids` — restrict to specific instances.
    * `:token_statuses` — token statuses that count as in flight
      (default `#{inspect(@live_token_statuses)}`).
    * `:include_children` — follow call-activity children into the export (default `true`).
      A parent parked on a call activity cannot be classified without its child, so this is on
      unless a caller explicitly wants one process's own rows.
    * `:include_correlation_keys` — emit correlation keys in the clear (default `false`).
    * `:actor`, `:tenant` — passed to `AshBpmn.Scope.from_opts/1`. With no actor the export
      runs as the `:engine` system actor, because an export is engine work with nobody behind
      it and `nil` would lose that distinction.
    * `:now` — the `exported_at` instant. Injectable so a test can compare two exports byte
      for byte.

  Returns `{:ok, export}`, or `{:error, :missing_resources, kinds}` when the domain is not a
  complete BPMN domain — the same shape `AshBpmn.Resources.for_domain/1` returns, unchanged,
  because rewording it here would give a caller two spellings of one failure.
  """
  @spec export(module(), keyword()) :: {:ok, t()} | {:error, :missing_resources, [atom()]}
  def export(domain, opts \\ []) do
    case AshBpmn.Resources.for_domain(domain) do
      {:ok, resources} -> {:ok, build(domain, resources, opts)}
      {:error, :missing_resources, kinds} -> {:error, :missing_resources, kinds}
    end
  end

  @doc "Like `export/2`, raising on a domain that is not a complete BPMN domain."
  @spec export!(module(), keyword()) :: t()
  def export!(domain, opts \\ []) do
    case export(domain, opts) do
      {:ok, export} ->
        export

      {:error, :missing_resources, kinds} ->
        raise ArgumentError,
              "#{inspect(domain)} is missing BPMN resources: #{inspect(kinds)}"
    end
  end

  @doc """
  The export as canonical JSON — sorted keys, stable bytes.

  The same encoding the digests are taken over, so a file written by this function and a
  digest computed in memory cannot disagree about what the document was.
  """
  @spec to_json(t()) :: String.t()
  def to_json(export), do: Canonical.encode(export)

  @doc """
  The digest of a whole export.

  Useful as the "before" side of a migration record: one value that changes if anything about
  what was in flight changed.
  """
  @spec digest(t()) :: String.t()
  def digest(export), do: Canonical.digest(export)

  # ── definitions ───────────────────────────────────────────────────────────

  @doc """
  A definition entry from a loaded `Definition` record.

  Returns `nil` for a record whose `graph` is absent — a draft that did not compile has no
  elements to digest, and inventing an empty element map for it would make "did not compile"
  and "has no nodes" the same document.
  """
  @spec definition_entry(struct()) :: map() | nil
  def definition_entry(%{graph: nil}), do: nil

  def definition_entry(record) do
    record.key
    |> definition_entry_from_graph(record.version, record.graph)
    |> Map.merge(%{
      "id" => record.id,
      "status" => to_string(record.status),
      "content_hash" => record.content_hash
    })
  end

  @doc """
  A definition entry from a compiled graph, with no database row behind it.

  This is how the *target* side of a classification is built: compile the new XML with
  `AshBpmn.Compiler.compile/1` and hand the graph here. The entry is the same shape a stored
  definition produces, minus the columns only a row has (`id`, `status`, `content_hash`),
  which are `nil`.
  """
  @spec definition_entry_from_graph(String.t(), integer() | nil, map()) :: map()
  def definition_entry_from_graph(key, version, graph) when is_map(graph) do
    %{
      "id" => nil,
      "key" => key,
      "version" => version,
      "status" => nil,
      "content_hash" => nil,
      "process_id" => graph["process_id"],
      "start" => graph["start"],
      "feel_engine" => graph["feel_engine"],
      "graph_digest" => Canonical.digest(graph),
      "elements" => elements(graph)
    }
  end

  @doc """
  A definition entry compiled straight from BPMN XML.

  The ordinary way to build the *target* side of a classification: the new diagram usually
  exists as XML long before it exists as a published row, and a migration has to be assessable
  before it is applied. Returns `{:error, errors}` in the compiler's own shape for XML that
  does not compile, because a target that will not publish is not a target.
  """
  @spec definition_entry_from_xml(String.t(), integer() | nil, String.t()) ::
          {:ok, map()} | {:error, [map()]}
  def definition_entry_from_xml(key, version, xml) do
    with {:ok, graph} <- AshBpmn.Compiler.compile(xml) do
      {:ok, definition_entry_from_graph(key, version, graph)}
    end
  end

  @doc """
  Every node in `graph`, as `node_id => element entry`.

  An element entry is:

    * `"type"` / `"name"` — what the node is, and what it is called.
    * `"digest"` — the occupancy digest: node config (minus the name), outgoing flows,
      attached boundary events, join specification. This is what the classifier compares.
    * `"node_digest"`, `"outgoing_digest"`, `"boundary_digest"`, `"join_digest"` — the same
      four parts, separately, so a classification can name which one moved. A change to the
      boundaries around an occupied activity and a change to the flows out of it are both
      "the digest differs" and they need different answers.
    * `"conditional_outgoing"` — whether any flow out of this node carries a condition.
    * `"wait"` — what a token parking here would be listening for, or `nil` for a node that
      does not park. See `wait_spec/2`.
  """
  @spec elements(map()) :: %{String.t() => map()}
  def elements(graph) when is_map(graph) do
    nodes = graph["nodes"] || %{}

    Map.new(nodes, fn {node_id, node} ->
      {node_id,
       %{
         "type" => node["type"],
         "name" => node["name"],
         "node_digest" => Canonical.digest(Map.delete(node, "name")),
         # The occupancy digest is one value, and one value cannot say *which* part moved.
         # Its three components are recorded beside it so a classification can distinguish a
         # rerouted gateway (a restart) from a boundary event added to an activity a token is
         # already sitting in (nobody's job is armed for it; a person has to look).
         "outgoing_digest" => Canonical.digest(outgoing(graph["flows"] || %{}, node_id)),
         "boundary_digest" => Canonical.digest(boundaries(graph, node_id)),
         "join_digest" => Canonical.digest_or_nil((graph["joins"] || %{})[node_id]),
         "digest" => Canonical.digest(occupancy(graph, node_id, node)),
         # Recorded separately from the digest because it is the one thing a *FEEL engine*
         # upgrade can change without changing a single byte of the diagram: conditions are
         # stored as source text and re-evaluated by whatever engine is installed, so an
         # engine change makes the routing out of this node statically undecidable. A node
         # with no conditional outgoing flow is unaffected and must not be flagged.
         "conditional_outgoing" => conditional_outgoing?(graph, node_id),
         "wait" => wait_spec(node_id, node)
       }}
    end)
  end

  @doc """
  What a token parked on this node is listening for, or `nil` if it does not park.

  `"signature"` is the `subscription_signature` the interpreter would write onto the token,
  recomputed from the node rather than remembered — which is the whole point: comparing a
  parked token's stored signature against the signature the *target* definition would produce
  is how the classifier detects a wait that will never be woken. The spellings mirror
  `AshBpmn.Runtime.Interpreter`'s park clauses exactly; if one moves, this must move with it,
  and `AshBpmn.StateExportTest` pins them against the interpreter's real output.

  `"correlation_basis"` is what the frozen `correlation_key` was computed *from* — a FEEL
  expression for a message catch, the subject's own id for a conditional one. A change there
  invalidates every key already frozen onto a parked token, which no digest of the node alone
  would tell you, since the key lives on the token and the expression lives on the node.
  """
  @spec wait_spec(String.t(), map()) :: map() | nil
  def wait_spec(node_id, node) do
    case node["type"] do
      type when type in ["intermediateCatchEvent", "receiveTask"] ->
        catch_wait(node_id, node["catch"] || %{})

      "userTask" ->
        # Parks with no signature and no key: a user task is woken by somebody completing
        # *that task*, which names the token directly.
        %{"kind" => "human_task", "signature" => nil, "correlation_basis" => nil}

      "callActivity" ->
        %{
          "kind" => "child_process",
          "signature" => nil,
          "correlation_basis" => nil,
          "process_key" => (node["call_process"] || %{})["key"]
        }

      _other ->
        nil
    end
  end

  defp catch_wait(node_id, %{"kind" => "timer"} = spec) do
    %{
      "kind" => "timer",
      "signature" => "timer:#{node_id}",
      "correlation_basis" => nil,
      "duration" => spec["duration"],
      "seconds" => spec["seconds"]
    }
  end

  defp catch_wait(_node_id, %{"kind" => "message"} = spec) do
    %{
      "kind" => "message",
      "signature" => AshBpmn.Runtime.Interpreter.message_signature(spec),
      "correlation_basis" => Canonical.digest_or_nil(spec["correlate"]),
      "lookback_minutes" => spec["lookback_minutes"]
    }
  end

  defp catch_wait(_node_id, %{"kind" => "signal"} = spec) do
    %{
      "kind" => "signal",
      "signature" => "signal:#{spec["ref"]}",
      "correlation_basis" => nil
    }
  end

  defp catch_wait(_node_id, %{"kind" => "conditional"} = spec) do
    %{
      "kind" => "conditional",
      "signature" => "conditional:#{spec["resource"]}",
      # Not an expression: a conditional catch waits for *this* subject, so the key is the
      # instance's own subject id and nothing a modeller wrote can change it.
      "correlation_basis" => "subject_id"
    }
  end

  # A catch whose kind this version does not know about. Saying so is the honest answer; the
  # classifier turns it into an `unknown` rather than guessing the wait is unchanged.
  defp catch_wait(_node_id, spec) do
    %{"kind" => spec["kind"], "signature" => nil, "correlation_basis" => nil}
  end

  defp occupancy(graph, node_id, node) do
    flows = graph["flows"] || %{}

    %{
      "node" => Map.delete(node, "name"),
      "outgoing" => outgoing(flows, node_id),
      "boundaries" => boundaries(graph, node_id),
      "join" => (graph["joins"] || %{})[node_id]
    }
  end

  # Flow ids are left out and the list is sorted by its own canonical form. A modeller who
  # deletes a flow and draws the same one again gets a new id from the tool and an identical
  # routing decision, and the second of those is the one a parked token experiences.
  defp outgoing(flows, node_id) do
    flows
    |> Enum.filter(fn {_id, flow} -> flow["from"] == node_id end)
    |> Enum.map(fn {_id, flow} -> %{"to" => flow["to"], "condition" => flow["condition"]} end)
    |> sort_canonically()
  end

  # Boundary ids *are* included, unlike flow ids: a boundary timer's Oban job carries the
  # boundary node id, so a boundary that is renamed has live jobs pointing at a node that no
  # longer exists.
  defp boundaries(graph, node_id) do
    nodes = graph["nodes"] || %{}

    (graph["boundaries"] || %{})
    |> Map.get(node_id, [])
    |> Enum.map(fn id -> %{"id" => id, "node" => Map.delete(nodes[id] || %{}, "name")} end)
    |> sort_canonically()
  end

  defp conditional_outgoing?(graph, node_id) do
    (graph["flows"] || %{})
    |> Enum.any?(fn {_id, flow} -> flow["from"] == node_id and not is_nil(flow["condition"]) end)
  end

  defp sort_canonically(entries), do: Enum.sort_by(entries, &Canonical.encode/1)

  # ── the export itself ─────────────────────────────────────────────────────

  defp build(domain, resources, opts) do
    scope = scope(opts)
    include_keys? = Keyword.get(opts, :include_correlation_keys, false)

    {instances, truncated?} = collect_instances(resources, scope, opts)
    instance_ids = Enum.map(instances, & &1.id)

    tokens =
      read(resources.token, :in_flight, scope, %{
        statuses: Keyword.get(opts, :token_statuses, @live_token_statuses),
        instance_ids: instance_ids
      })

    children = children_by_parent_token(resources, scope, tokens, opts)
    definitions = definition_entries(instances)
    elements_by_definition = Map.new(definitions, &{&1["id"], &1["elements"]})
    tokens_by_instance = Enum.group_by(tokens, & &1.instance_id)

    %{
      "format" => @format,
      "format_version" => @format_version,
      "exported_at" => DateTime.to_iso8601(Keyword.get(opts, :now) || DateTime.utc_now()),
      "domain" => inspect(domain),
      "engine" => %{"ash_bpmn" => engine_version()},
      "correlation_keys" => if(include_keys?, do: "included", else: "digested"),
      "children_truncated" => truncated?,
      "definitions" => Enum.sort_by(definitions, &{&1["key"], &1["version"]}),
      "instances" =>
        instances
        |> Enum.map(
          &instance_entry(
            &1,
            Map.get(tokens_by_instance, &1.id, []),
            Map.get(elements_by_definition, &1.definition_id, %{}),
            children,
            include_keys?
          )
        )
        |> Enum.sort_by(& &1["id"])
    }
  end

  # The instances the caller asked for, plus — unless they said not to — every call-activity
  # child reachable from them. Iterated to a fixpoint rather than recursed once, because a
  # child that itself calls an activity is an ordinary thing to draw.
  defp collect_instances(resources, scope, opts) do
    seed =
      read(resources.instance, :in_flight, scope, %{
        statuses: Keyword.get(opts, :statuses, [:running]),
        definition_key: Keyword.get(opts, :definition_key),
        instance_ids: Keyword.get(opts, :instance_ids)
      })

    if Keyword.get(opts, :include_children, true) do
      follow_children(resources, scope, opts, seed, MapSet.new(Enum.map(seed, & &1.id)), 0)
    else
      {seed, false}
    end
  end

  defp follow_children(resources, scope, opts, acc, seen, depth) do
    token_ids =
      read(resources.token, :in_flight, scope, %{
        statuses: Keyword.get(opts, :token_statuses, @live_token_statuses),
        instance_ids: Enum.map(acc, & &1.id)
      })
      |> Enum.map(& &1.id)

    # Every status, not just `:running`. A child that has already finished while its parent's
    # wake is still queued is exactly the state an operator needs to see, and filtering it out
    # would report the parent as waiting for nothing.
    found =
      read(resources.instance, :in_flight, scope, %{
        statuses: @all_instance_statuses,
        parent_token_ids: token_ids
      })
      |> Enum.reject(&MapSet.member?(seen, &1.id))

    case found do
      [] ->
        {acc, false}

      new when depth + 1 >= @max_child_depth ->
        {acc ++ new, true}

      new ->
        follow_children(
          resources,
          scope,
          opts,
          acc ++ new,
          Enum.reduce(new, seen, &MapSet.put(&2, &1.id)),
          depth + 1
        )
    end
  end

  defp children_by_parent_token(resources, scope, tokens, opts) do
    if Keyword.get(opts, :include_children, true) do
      resources.instance
      |> read(:in_flight, scope, %{
        statuses: @all_instance_statuses,
        parent_token_ids: Enum.map(tokens, & &1.id)
      })
      |> Enum.group_by(& &1.parent_token_id, fn instance ->
        %{
          "instance_id" => instance.id,
          "definition_key" => definition_field(instance, :key),
          "definition_version" => definition_field(instance, :version),
          "status" => to_string(instance.status)
        }
      end)
    else
      %{}
    end
  end

  defp definition_entries(instances) do
    instances
    |> Enum.map(& &1.definition)
    |> Enum.reject(&(is_nil(&1) or is_struct(&1, Ash.NotLoaded)))
    |> Enum.uniq_by(& &1.id)
    |> Enum.map(&definition_entry/1)
    |> Enum.reject(&is_nil/1)
  end

  defp instance_entry(instance, tokens, elements, children, include_keys?) do
    %{
      "id" => instance.id,
      "definition_id" => instance.definition_id,
      "definition_key" => definition_field(instance, :key),
      "definition_version" => definition_field(instance, :version),
      "definition_content_hash" => definition_field(instance, :content_hash),
      "status" => to_string(instance.status),
      "subject_type" => instance.subject_type,
      "subject_id" => instance.subject_id,
      "correlation_id" => instance.correlation_id,
      "started_by_id" => instance.started_by_id,
      "parent_instance_id" => instance.parent_instance_id,
      "parent_token_id" => instance.parent_token_id,
      "trigger_depth" => instance.trigger_depth,
      "outcome" => instance.outcome,
      "tenant_id" => Map.get(instance, :organization_id),
      "started_at" => timestamp(instance.inserted_at),
      "updated_at" => timestamp(instance.updated_at),
      "tokens" =>
        tokens
        |> Enum.map(&token_entry(&1, elements, children, include_keys?))
        |> Enum.sort_by(& &1["id"])
    }
  end

  defp token_entry(token, elements, children, include_keys?) do
    element = Map.get(elements, token.node_id)

    %{
      "id" => token.id,
      "node_id" => token.node_id,
      # From the pinned graph, not from the token: a token records where it is, not what that
      # place is. A nil here means the node is not in the definition the instance pinned,
      # which is a finding and not a formatting problem.
      "node_type" => element && element["type"],
      "node_name" => element && element["name"],
      "element_digest" => element && element["digest"],
      "status" => to_string(token.status),
      "parent_token_id" => token.parent_token_id,
      "fork_id" => token.fork_id,
      "attempts" => token.attempts,
      "routing_keys" => routing_keys(token.routing),
      "routing_digest" => Canonical.digest_or_nil(token.routing),
      "created_at" => timestamp(token.inserted_at),
      "updated_at" => timestamp(token.updated_at),
      "waiting" => waiting_entry(token, element, children, include_keys?)
    }
  end

  defp waiting_entry(%{status: :waiting} = token, element, children, include_keys?) do
    %{
      "since" => timestamp(token.parked_at),
      "waits_for" => waits_for(token, element),
      "subscription_signature" => token.subscription_signature,
      "lookback_until" => timestamp(token.lookback_until),
      "children" => Map.get(children, token.id, [])
    }
    |> Map.merge(correlation_key_fields(token.correlation_key, include_keys?))
  end

  defp waiting_entry(_token, _element, _children, _include_keys?), do: nil

  defp correlation_key_fields(nil, _include_keys?),
    do: %{"correlation_key" => nil, "correlation_key_digest" => nil}

  defp correlation_key_fields(key, true),
    do: %{"correlation_key" => key, "correlation_key_digest" => Canonical.digest(key)}

  defp correlation_key_fields(key, false),
    do: %{"correlation_key" => nil, "correlation_key_digest" => Canonical.digest(key)}

  # The graph is the authority on what a node waits for. Falling back to the signature's own
  # prefix covers the case the graph cannot answer — a node deleted from the definition since
  # the token parked — and `"unknown"` is what a token with neither gets, rather than a guess
  # that reads like a fact.
  defp waits_for(token, element) do
    cond do
      element && element["wait"] && element["wait"]["kind"] ->
        element["wait"]["kind"]

      is_binary(token.subscription_signature) ->
        hd(String.split(token.subscription_signature, ":"))

      true ->
        "unknown"
    end
  end

  # ── plumbing ──────────────────────────────────────────────────────────────

  defp scope(opts) do
    case Keyword.get(opts, :actor) do
      nil -> %{AshBpmn.Scope.system(:engine) | tenant: Keyword.get(opts, :tenant)}
      _actor -> AshBpmn.Scope.from_opts(opts)
    end
  end

  defp read(resource, action, scope, params) do
    apply(resource, :"#{action}!", [drop_nils(params), AshBpmn.Scope.engine(scope)])
  end

  # An argument that is nil means "do not narrow on this", and the preparations spell that as
  # a nil-matching clause — but only if the argument was never set. Passing `nil` explicitly
  # would set it, which is the same thing here, and dropping it keeps the two paths identical.
  defp drop_nils(params), do: params |> Enum.reject(&(elem(&1, 1) == nil)) |> Map.new()

  defp routing_keys(routing) when is_map(routing),
    do: routing |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort()

  defp routing_keys(_routing), do: []

  defp definition_field(%{definition: %Ash.NotLoaded{}}, _field), do: nil
  defp definition_field(%{definition: nil}, _field), do: nil
  defp definition_field(%{definition: definition}, field), do: Map.get(definition, field)

  defp timestamp(nil), do: nil
  defp timestamp(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp timestamp(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)

  defp engine_version do
    case :application.get_key(:ash_bpmn, :vsn) do
      {:ok, vsn} -> List.to_string(vsn)
      _other -> "unknown"
    end
  end
end
