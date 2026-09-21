# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.Migration.Restart do
  @moduledoc """
  Restarting an in-flight instance under another definition.

  `AshBpmn.Migration.Classifier` answers `needs_restart` for an instance whose live tokens
  cannot be resumed where they stand but whose work can be done again from the beginning. It
  had nothing to hand that verdict to. This module is what it names.

  ## The semantics: supersede

  Three things could have been meant by "restart", and they are not interchangeable:

    * **Cancel and start again.** Two unrelated instances, and the second one cannot say what
      it replaced. An auditor asking "what happened to the onboarding we opened in March?"
      gets "it was cancelled", which is true and useless.
    * **Repoint in place.** Move the instance's `definition_id` to the new version and let its
      tokens carry on. That is `safe_to_continue`, not `needs_restart` — it is precisely the
      thing the classifier said could not be done here.
    * **Supersede.** The old instance stops, keeps everything it did, and records which
      instance took its work over; a new instance of the target definition starts at that
      definition's start node, carrying the identity of the case but nothing about how far the
      old run had got.

  Supersede is what this implements. The old instance moves to `:superseded` — a status of its
  own, not `:cancelled`, because "the customer withdrew" and "we moved this onto version 4"
  must not be one number on anybody's report — and gains `superseded_by_instance_id` and
  `superseded_at`. Its tokens, events and closed tasks are left exactly as they were, because
  the only question a superseded instance exists to answer is what was running before the
  move, and an instance edited to resemble its successor cannot answer it.

  ## Why no in-flight state is carried across

  The obvious refinement is to carry the tokens the classifier found safe — the ones standing
  on a node the target spells identically — and start only the rest from scratch. It is wrong,
  and the reason is in the classifier's own contract rather than in any implementation detail.

  `needs_restart` means *this instance cannot be resumed where it stands*. Carrying some
  tokens and not others is resumption for those branches and restart for the rest, and the
  result is a marking the target definition can never reach by running: a token at the start
  node **and** a token halfway down the diagram. In a sequential process that is the process
  running twice from two places, with every service task in the overlap invoked twice. In a
  parallel one it is worse and quieter — a parallel join counts the branches named in its
  `waits_for`, so a carried branch plus a re-forked one either double-counts the join or
  starves it, and neither shows up as an error.

  The same argument disposes of carrying a token's `routing`. Routing signals are promoted by
  a business rule task *upstream* of where the token now stands, and the occupancy digest that
  makes a token "safe" covers the node it is on and nothing before it — so a safe token says
  nothing whatever about whether the decision that produced its routing still means what it
  meant. Seeding the successor with it would let a gateway read a stale value in the window
  before the rule task re-runs, which is a behaviour change with no symptom.

  So what crosses is identity, not progress:

    * `subject_type` / `subject_id` — which case this is. The whole point of the restart.
    * `correlation_id` — the host operation the work belongs to, so the two instances sit in
      one trace.
    * `started_by_id` — who is accountable for the process existing. Unchanged by a restart:
      the operator who *performed* the restart is the actor on its events, which is a
      different fact and is recorded as one.
    * `parent_instance_id` / `parent_token_id` — a restarted child keeps its parent's parked
      token, so the parent goes on waiting and is woken by the successor. The alternative is
      a parent waiting forever for an instance that was deliberately stopped.
    * `trigger_depth` — carried, not reset. The depth is the bound that stops a subscription
      cycle, and re-basing it to zero at every restart would hand a cycle a way around it.

  ## What the record says

  Everything the restart threw away is written into an `:instance_restarted` event on the
  successor and an `:instance_superseded` event on the predecessor — two rows, because an
  operator reading either instance must not have to find the other one to learn that a restart
  happened. The record names, per live token, where it stood and which of four things was true
  of that node in the target:

    * `identical_in_target` — the node is spelled the same, so the restart will reach it again
      by running.
    * `changed_in_target` — the node exists but its occupancy shape moved.
    * `unsafe_in_target` — the node is gone, or the token's parked wait would never be woken.
      This is the one an operator has to read: a token that had been parked on a payment for
      six days is not replaced by anything the successor does at its start node.
    * `undecided` — the classifier declined to say, with its reason codes attached.

  The disposition comes from `AshBpmn.Migration.Classifier` itself, run against a narrow
  export of this one instance at the moment of the restart, rather than from a second
  comparison written here. Two implementations of "did this node change" is one more than the
  number that can be right.

  It also names the **orphaned children**: an instance parked on a call activity has children
  still running, and stopping the parent leaves them with nobody to return to. This does not
  stop them — the classifier's position is that a parent cannot be moved past a child, and
  overriding that is the operator's call, not this module's — but it is written down, because
  the failure mode of not writing it down is a child process running to completion against a
  parent that no longer exists.

  ## Usage

      {:ok, %{superseded: old, successor: new, decision: record}} =
        AshBpmn.restart_instance(instance, actor: operator)

  The target defaults to the latest published definition for the instance's own process key.
  `:definition`, `:definition_id` and `:to_version` name one explicitly — `:to_version` being
  the one that pairs with `AshBpmn.Migration.Classifier.classify/3`'s `:to_versions`, so the
  version an operator classified is the version they restart onto.
  """

  alias AshBpmn.Migration.Classifier
  alias AshBpmn.Runtime.DomainResolver
  alias AshBpmn.Scope
  alias AshBpmn.StateExport

  @format "ash_bpmn.instance_restart"
  @format_version 1

  # The classifier's verdicts, said in the vocabulary of a token that is being discarded.
  # Keyed by the classifier's own strings so the two cannot drift apart silently; a verdict
  # this map has not heard of is `undecided`, which is the honest answer for one.
  @dispositions %{
    "needs_manual_attention" => "unsafe_in_target",
    "needs_restart" => "changed_in_target",
    "unknown" => "undecided",
    "safe_to_continue" => "identical_in_target"
  }

  @identical @dispositions["safe_to_continue"]
  @undecided @dispositions["unknown"]

  @doc "The format identifier written into every decision record."
  @spec format() :: String.t()
  def format, do: @format

  @doc "The format version written into every decision record."
  @spec format_version() :: pos_integer()
  def format_version, do: @format_version

  @doc """
  Restarts `instance` under another definition, superseding it.

  ## Options

    * `:definition` / `:definition_id` / `:to_version` — the target. Without one, the latest
      published definition for the instance's own process key.
    * `:actor` — who is performing the restart. Recorded on the events it writes.
    * `:tenant` — defaults to the instance's own, which is the right answer whenever the
      caller loaded the instance in the first place.

  Returns `{:ok, %{superseded: old, successor: new, decision: record}}`.
  """
  @spec restart(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def restart(instance, opts \\ []) do
    scope = Scope.from_record(instance, opts)
    domain = scope.domain || Ash.Resource.Info.domain(instance.__struct__)
    resources = DomainResolver.resolve!(domain)

    with :ok <- refuse_unless_running(instance),
         {:ok, target} <- target_definition(resources, instance, opts, scope) do
      transact(resources, domain, instance, target, scope)
    end
  end

  @doc "Like `restart/2`, raising rather than returning `{:error, reason}`."
  @spec restart!(map(), keyword()) :: map()
  def restart!(instance, opts \\ []) do
    case restart(instance, opts) do
      {:ok, result} -> result
      {:error, %{__exception__: true} = exception} -> raise exception
      {:error, reason} -> raise "AshBpmn.restart_instance! failed: #{inspect(reason)}"
    end
  end

  # ── refusals ──────────────────────────────────────────────────────────────

  # A restart is not idempotent and must not pretend to be. Running it twice would start a
  # second successor, and both would be doing the same case's work with neither aware of the
  # other -- so the second attempt is refused, by name, with the successor that already exists.
  #
  # The `:supersede` action refuses it a second time on its own `:running` guard, which is what
  # closes the race between two operators clicking at once; this clause is here so the ordinary
  # case gets a sentence a person can act on rather than a status validation.
  defp refuse_unless_running(%{status: :running}), do: :ok

  defp refuse_unless_running(%{status: :superseded} = instance) do
    {:error,
     "instance #{instance.id} was already superseded by #{instance.superseded_by_instance_id} " <>
       "at #{instance.superseded_at}. Restart the successor, not the instance it replaced"}
  end

  defp refuse_unless_running(instance) do
    {:error,
     "instance #{instance.id} is #{instance.status}, and a restart moves work that is still " <>
       "running. Start a new instance instead"}
  end

  # ── the target ────────────────────────────────────────────────────────────

  defp target_definition(resources, instance, opts, scope) do
    cond do
      definition = Keyword.get(opts, :definition) ->
        usable(definition)

      definition_id = Keyword.get(opts, :definition_id) ->
        case Ash.get(resources.definition, definition_id, Scope.engine(scope)) do
          {:ok, definition} -> usable(definition)
          {:error, _reason} -> {:error, "no definition with id #{inspect(definition_id)}"}
        end

      version = Keyword.get(opts, :to_version) ->
        pinned_version(resources, instance, version, scope)

      true ->
        latest_published(resources, instance, scope)
    end
  end

  defp pinned_version(resources, instance, version, scope) do
    key = definition_key!(resources, instance, scope)

    case resources.definition.by_key_version(key, version, Scope.engine(scope)) do
      {:ok, nil} ->
        {:error, "no definition #{inspect(key)} at version #{inspect(version)}"}

      {:ok, definition} ->
        usable(definition)

      {:error, _reason} ->
        {:error, "no definition #{inspect(key)} at version #{inspect(version)}"}
    end
  end

  defp latest_published(resources, instance, scope) do
    key = definition_key!(resources, instance, scope)

    case resources.definition.latest_published!(key, Scope.engine(scope)) do
      [] ->
        {:error,
         "no published definition found for process #{inspect(key)}; there is nothing to " <>
           "restart onto"}

      [definition | _rest] ->
        usable(definition)
    end
  end

  defp definition_key!(resources, instance, scope) do
    resources.definition
    |> Ash.get!(instance.definition_id, Scope.engine(scope))
    |> Map.fetch!(:key)
  end

  # A definition with no graph did not compile. `AshBpmn.StateExport.definition_entry/1`
  # exports it as absent rather than as empty -- deliberately, so "did not compile" and "has no
  # nodes" stay different documents -- and a classification against an absent target is an
  # `unknown` that tells the operator nothing about the diagram they actually chose. Refusing
  # here says the real thing.
  defp usable(%{graph: nil} = definition) do
    {:error,
     "definition #{definition.id} (#{definition.key} v#{definition.version}) has no compiled " <>
       "graph; a target that will not publish is not a target"}
  end

  defp usable(definition), do: {:ok, definition}

  # ── the restart ───────────────────────────────────────────────────────────

  # One transaction, and the ordering inside it is not free. The decision is taken first,
  # because it describes what was live and winding the instance down destroys that; the
  # successor is started before the link is written, because a link to an instance that does
  # not exist is worse than no link; and the supersede comes last, so a failure anywhere leaves
  # the old instance running rather than leaving two instances doing one case's work.
  defp transact(resources, domain, instance, target, scope) do
    Ash.transaction(
      [resources.instance, resources.token, resources.human_task, resources.process_event],
      fn ->
        decision = decide(resources, domain, instance, target, scope)

        :ok = AshBpmn.halt_instance_work(resources, instance, :instance_superseded, scope)

        successor = start_successor!(domain, instance, target, scope)
        decision = Map.put(decision, "to_instance_id", successor.id)

        superseded = resources.instance.supersede!(instance, successor.id, Scope.engine(scope))

        record!(resources, instance.id, :instance_superseded, decision, scope)
        record!(resources, successor.id, :instance_restarted, decision, scope)

        %{superseded: superseded, successor: successor, decision: decision}
      end
    )
  end

  # `start_instance/2` rescues and returns its error, so a failure here would otherwise be a
  # value the transaction happily commits around. Raising is what rolls it back.
  defp start_successor!(domain, instance, target, scope) do
    started =
      AshBpmn.start_instance(domain,
        definition: target,
        subject_type: instance.subject_type,
        subject_id: instance.subject_id,
        correlation_id: instance.correlation_id,
        started_by_id: instance.started_by_id,
        parent_instance_id: instance.parent_instance_id,
        parent_token_id: instance.parent_token_id,
        trigger_depth: instance.trigger_depth,
        actor: scope.actor,
        tenant: scope.tenant
      )

    case started do
      {:ok, successor} ->
        successor

      {:error, %{__exception__: true} = exception} ->
        raise exception

      {:error, reason} ->
        raise "ash_bpmn: could not start the successor to instance #{instance.id}: " <>
                inspect(reason)
    end
  end

  defp record!(resources, instance_id, kind, decision, scope) do
    resources.process_event.create!(
      %{instance_id: instance_id, kind: kind, data: decision},
      Scope.engine(scope)
    )
  end

  # ── the decision record ───────────────────────────────────────────────────

  # Built from a `AshBpmn.StateExport` document rather than from the token rows, which is what
  # keeps the invariant the export already holds: node ids, statuses and digests go in,
  # business data does not. A record assembled from the rows would have had to re-derive that
  # line, and would have got it wrong the first time somebody added a field.
  #
  # The export is narrowed to this one instance and explicitly excludes children. A parent and
  # its child are different processes with different keys, and classifying a child's tokens
  # against the *parent's* target would compare two unrelated diagrams. The children are
  # reported instead, as orphans, which is what they are.
  defp decide(resources, domain, instance, target, scope) do
    export =
      StateExport.export!(domain,
        instance_ids: [instance.id],
        include_children: false,
        actor: scope.actor,
        tenant: scope.tenant
      )

    exported = List.first(export["instances"]) || %{"tokens" => []}
    target_entry = StateExport.definition_entry(target)
    report = Classifier.classify(export, %{exported["definition_key"] => target_entry})
    verdict = List.first(report["instances"]) || %{"classification" => nil, "reasons" => []}

    %{
      "format" => @format,
      "format_version" => @format_version,
      "decided_at" => export["exported_at"],
      "from_instance_id" => instance.id,
      "to_instance_id" => nil,
      "from_definition" => %{
        "id" => exported["definition_id"],
        "key" => exported["definition_key"],
        "version" => exported["definition_version"],
        "content_hash" => exported["definition_content_hash"]
      },
      "to_definition" => %{
        "id" => target.id,
        "key" => target.key,
        "version" => target.version,
        "content_hash" => target.content_hash
      },
      "classification" => verdict["classification"],
      "instance_reasons" => codes(verdict["reasons"], &is_nil(&1["token_id"])),
      "source_digest" => report["source_digest"],
      "carried" => carried(instance),
      "dropped_tokens" => dropped_tokens(exported, verdict),
      "orphaned_children" => orphaned_children(resources, exported, scope)
    }
  end

  # Named one by one rather than taken from the struct, because the list *is* the decision:
  # a field that starts being carried because somebody widened a `Map.take/2` is a change to
  # what a restart means, made by accident. See the moduledoc for why each of these crosses.
  defp carried(instance) do
    %{
      "subject_type" => instance.subject_type,
      "subject_id" => instance.subject_id,
      "correlation_id" => instance.correlation_id,
      "started_by_id" => instance.started_by_id,
      "parent_instance_id" => instance.parent_instance_id,
      "parent_token_id" => instance.parent_token_id,
      "trigger_depth" => instance.trigger_depth
    }
  end

  defp dropped_tokens(exported, verdict) do
    by_token =
      verdict["reasons"]
      |> Enum.reject(&is_nil(&1["token_id"]))
      |> Enum.group_by(& &1["token_id"])

    Enum.map(exported["tokens"] || [], fn token ->
      reasons = Map.get(by_token, token["id"], [])
      waiting = token["waiting"]

      %{
        "token_id" => token["id"],
        "node_id" => token["node_id"],
        "node_name" => token["node_name"],
        "status" => token["status"],
        "disposition" => disposition(reasons),
        "waits_for" => waiting && waiting["waits_for"],
        "waiting_since" => waiting && waiting["since"],
        "routing_keys" => token["routing_keys"],
        "reasons" => codes(reasons, fn _reason -> true end)
      }
    end)
  end

  # `Classifier.verdicts/0` is ordered most severe first, so the first severity present wins.
  # Ordering them again here is how the two modules come to disagree about which of a token's
  # findings is the one an operator reads.
  defp disposition([]), do: @identical

  defp disposition(reasons) do
    severities = MapSet.new(reasons, & &1["severity"])

    Classifier.verdicts()
    |> Enum.find(&MapSet.member?(severities, &1))
    |> then(&Map.get(@dispositions, &1, @undecided))
  end

  # A parent parked on a call activity has children that are still running and that will, when
  # they finish, try to wake a token this restart just killed. They lose that race quietly --
  # `claim_waiting` admits only a `:waiting` token -- so without this they would be invisible.
  defp orphaned_children(resources, exported, scope) do
    token_ids = Enum.map(exported["tokens"] || [], & &1["id"])

    if token_ids == [] do
      []
    else
      resources.instance.in_flight!(
        %{statuses: [:running], parent_token_ids: token_ids},
        Scope.engine(scope)
      )
      |> Enum.map(
        &%{
          "instance_id" => &1.id,
          "definition_key" => &1.definition && &1.definition.key,
          "parent_token_id" => &1.parent_token_id,
          "status" => to_string(&1.status)
        }
      )
    end
  end

  defp codes(reasons, filter) do
    reasons
    |> Enum.filter(filter)
    |> Enum.map(& &1["code"])
    |> Enum.uniq()
  end
end
