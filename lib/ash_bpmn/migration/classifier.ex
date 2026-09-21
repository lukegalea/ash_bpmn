# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.Migration.Classifier do
  @moduledoc """
  Can these in-flight instances move to the new diagram?

  An instance pins its definition version for life, so publishing version 4 does nothing to
  the instances already running version 3. Sooner or later somebody wants them moved anyway —
  the old version has a bug, or a regulator changed the rule, or nobody wants to support two
  shapes of the same process. This module answers, per instance, which of four things is true:

  | Verdict | Meaning |
  |---|---|
  | `safe_to_continue` | Every live token is standing somewhere the new definition spells identically. Repoint the instance and carry on. |
  | `needs_restart` | A live token's immediate situation changed. The instance can be re-run from the start under the new definition, but not resumed where it stands. |
  | `needs_manual_attention` | Something a restart does not fix: a node a token is standing on is gone, a parked wait will never be woken, a join now waits for a branch that never forked. A person has to decide. |
  | `unknown` | Not decidable from the artefacts given, **with the reason attached**. |

  `unknown` is a first-class answer and not a failure mode. A classifier that resolves every
  ambiguity to `safe_to_continue` is worse than no classifier, because someone will trust it;
  one that resolves everything to `needs_manual_attention` gets switched off. So where the
  inputs genuinely do not decide — a target definition that was not supplied, a catch kind
  this version does not recognise, a FEEL engine change under a conditional gateway — the
  verdict says so and names which of those it was.

  ## What "changed shape" means

  From `AshBpmn.StateExport`: a node's **occupancy digest** covers its own compiled config,
  its outgoing flows and their conditions, the boundary events attached to it, and its join
  specification. Not its name, and not anything downstream — a change three nodes ahead of a
  parked token is usually the point of the migration, and treating it as breaking would make
  every migration need manual attention.

  ## Severity ordering

  `needs_manual_attention` > `needs_restart` > `unknown` > `safe_to_continue`.

  `needs_restart` outranking `unknown` is deliberate and is the one ordering worth arguing
  about: if one token definitely needs a restart and another is undecidable, restarting the
  instance disposes of both, so the actionable answer wins. Every reason found is reported
  regardless of which one set the verdict.

  ## Usage

      {:ok, before} = AshBpmn.StateExport.export(MyApp.Bpmn)
      {:ok, target} = AshBpmn.StateExport.definition_entry_from_xml("onboarding", 4, new_xml)

      report = AshBpmn.Migration.Classifier.classify(before, [target])
      report["summary"]
      #=> %{"safe_to_continue" => 12, "needs_restart" => 3, "needs_manual_attention" => 1, "unknown" => 0}

  The target may be a bare list of definition entries as above, a map keyed by process key, or
  a whole second export — which is the "two `ash_bpmn` versions" case: export before the
  upgrade, export after, and classify one against the other.
  """

  alias AshBpmn.Canonical

  @format "ash_bpmn.migration_classification"
  @format_version 1

  @safe "safe_to_continue"
  @restart "needs_restart"
  @manual "needs_manual_attention"
  @unknown "unknown"

  @severity %{@manual => 3, @restart => 2, @unknown => 1, @safe => 0}
  @verdicts [@safe, @restart, @manual, @unknown]

  @typedoc "A classification report: string keys, JSON-safe values."
  @type report :: %{String.t() => term()}

  @doc "The format identifier written into every report."
  @spec format() :: String.t()
  def format, do: @format

  @doc "The format version written into every report."
  @spec format_version() :: pos_integer()
  def format_version, do: @format_version

  @doc """
  Classifies every instance in `export` against `target`.

  `target` is one of:

    * a list of definition entries (`AshBpmn.StateExport.definition_entry_from_xml/3` or
      `definition_entry_from_graph/3`),
    * a map of `key => entry` or `key => [entries]`,
    * a whole export map, whose `"definitions"` are used.

  ## Options

    * `:to_versions` — `%{key => version}`, pinning which target version each process key
      moves to. Without it the highest version present for the key is used, and a target list
      with one entry per key — the usual case — needs nothing.
    * `:now` — the `classified_at` instant, injectable for tests.
  """
  @spec classify(map(), term(), keyword()) :: report()
  def classify(export, target, opts \\ []) do
    targets = index_targets(target)
    classified_at = DateTime.to_iso8601(Keyword.get(opts, :now) || DateTime.utc_now())

    instances =
      case export["format_version"] do
        @format_version ->
          export
          |> instance_verdicts(targets, opts)
          |> propagate_children(export)

        other ->
          # A newer export may carry token state this version cannot interpret. Guessing from
          # the fields it happens to recognise is how a classifier reports `safe_to_continue`
          # over a wait shape it has never seen.
          unsupported_format(export, other)
      end

    %{
      "format" => @format,
      "format_version" => @format_version,
      "classified_at" => classified_at,
      "source_format_version" => export["format_version"],
      "source_digest" => Canonical.digest(export),
      "source_engine" => export["engine"],
      "summary" => summarize(instances),
      "instances" => Enum.sort_by(instances, & &1["instance_id"])
    }
  end

  @doc """
  The four verdicts, most severe first.

  Exposed so a consumer can render or order them without hard-coding the strings, and so the
  ordering that decides a verdict is the same list a reader sees.
  """
  @spec verdicts() :: [String.t()]
  def verdicts, do: Enum.sort_by(@verdicts, &(-@severity[&1]))

  # ── per-instance ──────────────────────────────────────────────────────────

  defp instance_verdicts(export, targets, opts) do
    sources = Map.new(export["definitions"] || [], &{&1["id"], &1})

    Enum.map(export["instances"] || [], fn instance ->
      source = sources[instance["definition_id"]]
      target = pick_target(targets, instance["definition_key"], opts)
      reasons = reasons_for(instance, source, target)

      %{
        "instance_id" => instance["id"],
        "definition_key" => instance["definition_key"],
        "from_version" => instance["definition_version"],
        "to_version" => target && target["version"],
        "classification" => verdict(reasons),
        "reasons" => reasons
      }
    end)
  end

  defp reasons_for(_instance, nil, _target) do
    [
      reason(
        @unknown,
        "source_definition_missing",
        "the export carries no definition for this instance, so there is nothing to compare " <>
          "against; a definition that failed to compile is exported as absent rather than as empty"
      )
    ]
  end

  defp reasons_for(instance, _source, nil) do
    [
      reason(
        @unknown,
        "target_definition_missing",
        "no target definition was supplied for process key #{inspect(instance["definition_key"])}"
      )
    ]
  end

  defp reasons_for(instance, source, target) do
    cond do
      unchanged?(source, target) ->
        [
          reason(
            @safe,
            "definition_unchanged",
            "the target is byte-identical to the pinned graph"
          )
        ]

      instance["tokens"] == [] ->
        # A running instance with nothing live in it has already gone wrong -- there is no
        # branch to carry over and no branch to restart from where it stands. Saying so is
        # more useful than calling it safe because nothing could be found to object to.
        [
          reason(
            @unknown,
            "no_live_tokens",
            "the instance is #{instance["status"]} but has no live tokens, so there is nothing to move"
          )
        ]

      true ->
        graph_reasons(source, target) ++
          Enum.flat_map(instance["tokens"], &token_reasons(&1, source, target))
    end
  end

  defp unchanged?(source, target) do
    (source["graph_digest"] && source["graph_digest"] == target["graph_digest"]) or
      (source["content_hash"] && source["content_hash"] == target["content_hash"])
  end

  # Process-level facts that no single token owns. Both are restarts rather than manual work:
  # the instances can be re-run, and neither can be resumed, because the interpreter resolves
  # a token's next step against a graph that no longer describes the same process.
  defp graph_reasons(source, target) do
    []
    |> maybe(
      source["process_id"] != target["process_id"],
      reason(
        @restart,
        "process_id_changed",
        "the process id changed from #{inspect(source["process_id"])} to #{inspect(target["process_id"])}"
      )
    )
    |> maybe(
      source["start"] != target["start"],
      reason(
        @restart,
        "start_node_changed",
        "the start event changed from #{inspect(source["start"])} to #{inspect(target["start"])}"
      )
    )
  end

  # ── per-token ─────────────────────────────────────────────────────────────

  defp token_reasons(token, source, target) do
    node_id = token["node_id"]
    from = (source["elements"] || %{})[node_id]
    to = (target["elements"] || %{})[node_id]

    cond do
      is_nil(from) ->
        [
          token_reason(
            token,
            @unknown,
            "node_missing_in_source",
            "the token stands on #{inspect(node_id)}, which is not in the graph its instance pinned"
          )
        ]

      is_nil(to) ->
        [
          token_reason(
            token,
            @manual,
            "node_missing_in_target",
            "the node this token stands on does not exist in the target, so there is nowhere to resume it"
          )
        ]

      true ->
        element_reasons(token, from, to) ++
          wait_reasons(token, from, to) ++
          engine_reasons(token, source, target, from)
    end
  end

  defp element_reasons(token, from, to) do
    cond do
      from["type"] != to["type"] ->
        [
          token_reason(
            token,
            @manual,
            "node_type_changed",
            "the node changed from #{inspect(from["type"])} to #{inspect(to["type"])}; " <>
              "whatever this token was doing there, it is not the same kind of thing any more"
          )
        ]

      from["digest"] == to["digest"] ->
        []

      true ->
        shape_reasons(token, from, to)
    end
  end

  # The occupancy digest said something moved; these say what, and each part carries its own
  # answer rather than one verdict for "the shape changed".
  #
  # A boundary change is the one that is easy to get wrong. Boundary timer jobs are armed when
  # a token *enters* the activity, so a boundary added to an occupied node is never armed for
  # the tokens already standing in it, and one removed leaves a scheduled job pointing at a
  # boundary the graph no longer declares. A restart repairs neither -- somebody has to look at
  # the queue -- so it is manual where a rerouted flow is a restart.
  #
  # A join change is manual for a sharper reason: `waits_for` is the set of incoming branches a
  # parallel gateway counts, and adding one to a join an instance has already forked past means
  # that instance waits for a branch that will never arrive. That is a permanent stall, and it
  # is silent.
  defp shape_reasons(token, from, to) do
    []
    |> maybe(
      from["boundary_digest"] != to["boundary_digest"],
      token_reason(
        token,
        @manual,
        "boundaries_changed",
        "the boundary events attached to this node changed; jobs are armed on entry, so the " <>
          "tokens already here cannot pick up an added one and a removed one leaves a job behind"
      )
    )
    |> maybe(
      from["join_digest"] != to["join_digest"],
      token_reason(
        token,
        @manual,
        "join_changed",
        "the branches this join waits for changed; an instance that has already forked may " <>
          "wait for a branch that will never arrive"
      )
    )
    |> maybe(
      from["node_digest"] != to["node_digest"],
      token_reason(
        token,
        @restart,
        "node_config_changed",
        "the node's own configuration changed (its action, decision, inputs or wait spec)"
      )
    )
    |> maybe(
      from["outgoing_digest"] != to["outgoing_digest"],
      token_reason(
        token,
        @restart,
        "outgoing_flows_changed",
        "the flows out of this node, or their conditions, changed; this token would route " <>
          "somewhere its instance was not designed to go"
      )
    )
    |> unchanged_fallback(token, from, to)
  end

  # The four components account for the whole occupancy digest, so this should be unreachable.
  # It is here because "should be" is not "is", and a digest that differs with no component to
  # blame is a defect in the export, not a safe instance.
  defp unchanged_fallback([], token, from, to) do
    [
      token_reason(
        token,
        @unknown,
        "element_shape_changed",
        "the occupancy digest changed from #{from["digest"]} to #{to["digest"]} but no " <>
          "component of it did; the export and the classifier disagree about what the digest covers"
      )
    ]
  end

  defp unchanged_fallback(reasons, _token, _from, _to), do: reasons

  # ── waits ─────────────────────────────────────────────────────────────────

  # A parked token is the one piece of state a redeployment cannot recreate. Its signature and
  # its correlation key were frozen at park, from the definition as it was then, and the
  # correlator matches on exactly those values -- so a target that would produce a different
  # signature produces a token that is never woken by anything, for as long as the instance
  # lives. That is the failure this whole module exists to catch, and it is invisible to a
  # digest comparison alone: the digest lives on the node, the frozen value lives on the row.
  defp wait_reasons(%{"waiting" => nil}, _from, _to), do: []

  defp wait_reasons(token, from, to) do
    waiting = token["waiting"]
    from_wait = from["wait"] || %{}
    to_wait = to["wait"] || %{}

    []
    |> maybe(
      is_nil(to_wait["kind"]) and not is_nil(from_wait["kind"]),
      token_reason(
        token,
        @manual,
        "wait_removed",
        "this token is parked, and the target's version of the node does not park at all"
      )
    )
    |> maybe(
      not is_nil(to_wait["kind"]) and to_wait["kind"] not in known_kinds(),
      token_reason(
        token,
        @unknown,
        "wait_kind_unrecognized",
        "the target parks on a wait of kind #{inspect(to_wait["kind"])}, which this version " <>
          "of the classifier does not know how to compare"
      )
    )
    |> maybe(
      not is_nil(from_wait["kind"]) and not is_nil(to_wait["kind"]) and
        from_wait["kind"] != to_wait["kind"],
      token_reason(
        token,
        @manual,
        "wait_kind_changed",
        "the wait changed from #{inspect(from_wait["kind"])} to #{inspect(to_wait["kind"])}"
      )
    )
    |> maybe(
      signature_broken?(waiting, to_wait),
      token_reason(
        token,
        @manual,
        "wait_signature_changed",
        "the token is parked on #{inspect(waiting["subscription_signature"])} but the target " <>
          "would park on #{inspect(to_wait["signature"])}; nothing would ever wake it"
      )
    )
    |> maybe(
      not is_nil(waiting["correlation_key_digest"]) and
        from_wait["correlation_basis"] != to_wait["correlation_basis"],
      token_reason(
        token,
        @manual,
        "correlation_basis_changed",
        "the correlation key frozen onto this token was computed from an expression the " <>
          "target no longer uses, so the key it is listening on no longer means what it meant"
      )
    )
    |> maybe(
      from_wait["kind"] == "child_process" and
        from_wait["process_key"] != to_wait["process_key"],
      token_reason(
        token,
        @manual,
        "call_process_key_changed",
        "this token is waiting for a child of #{inspect(from_wait["process_key"])}, and the " <>
          "target calls #{inspect(to_wait["process_key"])}; the child already running is the wrong one"
      )
    )
  end

  defp known_kinds,
    do: ["timer", "message", "signal", "conditional", "human_task", "child_process"]

  # Only when the target actually produces a signature. A user task and a call activity park
  # with none, and comparing nil against a stored nil says nothing either way.
  defp signature_broken?(waiting, to_wait) do
    stored = waiting["subscription_signature"]
    expected = to_wait["signature"]

    not is_nil(expected) and not is_nil(stored) and stored != expected
  end

  # ── engine ────────────────────────────────────────────────────────────────

  # The one axis that is about the *library* version rather than the diagram. Conditions are
  # stored as source text and re-evaluated by whatever FEEL engine is installed, which is what
  # lets an in-flight instance survive an engine upgrade -- and also means the engine can
  # change how a gateway routes without changing a byte of the graph. There is no static way
  # to tell whether it did, so this is an `unknown` with the versions named, and only for
  # tokens standing on a node that actually routes on a condition.
  defp engine_reasons(token, source, target, from) do
    if from["conditional_outgoing"] and source["feel_engine"] != target["feel_engine"] do
      [
        token_reason(
          token,
          @unknown,
          "feel_engine_changed",
          "this node routes on a FEEL condition and the engine changed from " <>
            "#{inspect(source["feel_engine"])} to #{inspect(target["feel_engine"])}; " <>
            "condition semantics cannot be compared statically"
        )
      ]
    else
      []
    end
  end

  # ── children ──────────────────────────────────────────────────────────────

  # A parent parked on a call activity cannot be dealt with independently of the child it is
  # waiting for: restarting the parent orphans a running child, and a child that needs manual
  # attention drags the parent into the same conversation. Run to a fixpoint so a grandchild's
  # verdict reaches the top, bounded by the number of instances because the parent/child graph
  # is a tree unless somebody has built a cycle, and a cycle must not hang the classifier.
  defp propagate_children(verdicts, export) do
    children_of =
      for instance <- export["instances"] || [],
          token <- instance["tokens"] || [],
          token["waiting"] != nil,
          child <- token["waiting"]["children"] || [],
          reduce: %{} do
        acc ->
          Map.update(acc, instance["id"], [{token["id"], child}], &(&1 ++ [{token["id"], child}]))
      end

    if children_of == %{} do
      verdicts
    else
      Enum.reduce_while(1..max(length(verdicts), 1), verdicts, fn _i, acc ->
        case propagate_once(acc, children_of) do
          ^acc -> {:halt, acc}
          next -> {:cont, next}
        end
      end)
    end
  end

  defp propagate_once(verdicts, children_of) do
    by_id = Map.new(verdicts, &{&1["instance_id"], &1})

    Enum.map(verdicts, fn verdict ->
      added =
        children_of
        |> Map.get(verdict["instance_id"], [])
        |> Enum.flat_map(fn {token_id, child} ->
          child_verdict = by_id[child["instance_id"]]
          inherited_reason(token_id, child, child_verdict)
        end)
        |> Enum.reject(&(&1 in verdict["reasons"]))

      case added do
        [] ->
          verdict

        new ->
          reasons = verdict["reasons"] ++ new
          %{verdict | "reasons" => reasons, "classification" => verdict(reasons)}
      end
    end)
  end

  defp inherited_reason(token_id, child, nil) do
    # The child is not in the export -- a narrowed export, or a child of a process key that
    # was filtered out. The parent's wait depends on something nobody classified.
    [
      %{
        "severity" => @unknown,
        "code" => "child_not_classified",
        "token_id" => token_id,
        "node_id" => nil,
        "detail" =>
          "this token waits for child instance #{child["instance_id"]}, which is not in the export"
      }
    ]
  end

  defp inherited_reason(_token_id, _child, %{"classification" => @safe}), do: []

  defp inherited_reason(token_id, child, child_verdict) do
    [
      %{
        "severity" =>
          if(child_verdict["classification"] == @unknown, do: @unknown, else: @manual),
        "code" => "child_needs_attention",
        "token_id" => token_id,
        "node_id" => nil,
        "detail" =>
          "the child instance #{child["instance_id"]} classifies as " <>
            "#{child_verdict["classification"]}; a parent cannot be moved past a child that cannot"
      }
    ]
  end

  # ── shared ────────────────────────────────────────────────────────────────

  defp verdict([]), do: @safe

  defp verdict(reasons) do
    reasons
    |> Enum.map(& &1["severity"])
    |> Enum.max_by(&@severity[&1])
  end

  defp summarize(instances) do
    counts = Enum.frequencies_by(instances, & &1["classification"])
    Map.new(@verdicts, &{&1, Map.get(counts, &1, 0)})
  end

  defp unsupported_format(export, version) do
    Enum.map(export["instances"] || [], fn instance ->
      %{
        "instance_id" => instance["id"],
        "definition_key" => instance["definition_key"],
        "from_version" => instance["definition_version"],
        "to_version" => nil,
        "classification" => @unknown,
        "reasons" => [
          reason(
            @unknown,
            "export_format_unsupported",
            "the export declares format version #{inspect(version)}; this classifier reads " <>
              "#{@format_version} and will not guess at the difference"
          )
        ]
      }
    end)
  end

  defp reason(severity, code, detail) do
    %{
      "severity" => severity,
      "code" => code,
      "token_id" => nil,
      "node_id" => nil,
      "detail" => detail
    }
  end

  defp token_reason(token, severity, code, detail) do
    %{
      "severity" => severity,
      "code" => code,
      "token_id" => token["id"],
      "node_id" => token["node_id"],
      "detail" => detail
    }
  end

  defp maybe(reasons, false, _reason), do: reasons
  defp maybe(reasons, true, reason), do: reasons ++ [reason]

  # ── target indexing ───────────────────────────────────────────────────────

  defp index_targets(%{"definitions" => definitions}), do: index_targets(definitions)

  defp index_targets(targets) when is_list(targets) do
    targets
    |> Enum.group_by(& &1["key"])
    |> Map.new(fn {key, entries} -> {key, Enum.sort_by(entries, &(&1["version"] || 0))} end)
  end

  defp index_targets(targets) when is_map(targets) do
    Map.new(targets, fn
      {key, entries} when is_list(entries) -> {key, Enum.sort_by(entries, &(&1["version"] || 0))}
      {key, entry} -> {key, [entry]}
    end)
  end

  defp pick_target(targets, key, opts) do
    entries = Map.get(targets, key, [])
    pinned = Keyword.get(opts, :to_versions, %{})[key]

    cond do
      entries == [] -> nil
      is_nil(pinned) -> List.last(entries)
      true -> Enum.find(entries, &(&1["version"] == pinned))
    end
  end
end
