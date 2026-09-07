# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.Triggers.Correlator do
  @moduledoc """
  The funnel: what one event means for the subscriptions watching it, and the
  record of the answer (TRD §5.3, stages 1–6 — Phase 2 is starts only; catch
  delivery and waiting tokens are Phase 3).

  The stages are ordered by cost, because the early ones run against every
  event in the log and the late ones are the expensive ones:

    1. **Index check** — nobody listening? done, no rows. One ETS lookup
       against `AshBpmn.Triggers.Index`; skipped entirely when the index
       process is not running (the sweep's subscription query is then the gate).
    2. **Context** — `AshBpmn.EventSource.context/1`, with every value through
       `AshBpmn.Feel.to_feel_value/1` at the boundary. FEEL numbers are
       decimal, so a plain Elixir integer in the context makes every numeric
       comparison a type error, which becomes `null`, which becomes a silently
       wrong branch. This is the only place that can prevent it.
    3. **Match** — structural, on resource, action and action type over
       published **and enabled** `kind: :message` subscriptions. No evaluation.
    4. **Guard** — a FEEL boolean over the event context. In-process, no I/O.
    5. **Route** — a process key named directly, or a DMN decision chosen
       through the host's `AshBpmn.DecisionResolver`.
    6. **Instantiate** — resolve the subject, resolve the definition, start the
       instance.

  Almost every outcome writes an `AshBpmn.Resources.Dispatch` row, including
  the ones that did nothing — a dispatch that skipped is as much a fact as one
  that started something, and it is the row that answers "why did *nothing*
  happen", which is the harder question of the two. The exceptions, both
  deliberate: a guard that answers plain `false` records nothing (an ordinary
  no, not a condition to investigate — `:guard_null` and `:guard_error` exist
  precisely because they are *not* ordinary), and an event with no matching
  subscription records nothing because there is no subscription to name.

  ## Failures are rows, not exceptions

  A subscription whose guard cannot answer, whose decision errors, or whose
  process has no published definition records a `:failed` (or `:skipped`)
  dispatch, and the cursor advances past it. A broken subscription must never
  wedge a tenant's event stream. `AshBpmn.Triggers.SweepWorker` wraps each
  event's funnel in its own transaction, so an *unexpected* exception costs one
  event's work, never the batch.

  ## Disabling is not retroactive

  Matches are read per batch, so a subscription disabled before a sweep runs
  simply is not in the list, and events reaching the sweep after the disable
  record nothing. What disabling does **not** do is un-fire what already
  dispatched: the dispatch rows and the instances they started are history, and
  no switch rewrites them.

  ## Depth, and why it rides on the dispatch row

  Subscriptions may not match `ash_bpmn` resources (publish-time refusal),
  which closes the direct cycle; a cycle through `AshBpmn.Resources.Signal`
  remains structurally possible, and `depth` bounds it (G-5). The bound travels
  on the dispatch row: an event's depth is read from its context metadata
  (`trigger_depth`, `0` when absent — an event a person caused), and the
  dispatch records `depth + 1`. `AshBpmn.start_instance/2` has no depth
  parameter, so the bound cannot reach the instance itself — it is carried in
  dispatch metadata, the reference application's arrangement, and the row is
  what an auditor reads. Past `AshBpmn.Config.trigger_max_depth/0` the dispatch
  refuses with `:depth_exceeded` and starts nothing.
  """

  require Ash.Query
  require Logger

  alias AshBpmn.Config
  alias AshBpmn.Feel
  alias AshBpmn.Resources.Subscription.ResourceName
  alias AshBpmn.Triggers.Index

  # The published context contract's keys. The adapter owns the shape; these
  # are the paths the funnel reads, kept in one place so a contract change is
  # one edit.
  @event "event"
  @metadata "metadata"

  @doc """
  Runs every matching subscription against one event.

  `subscriptions` is the batch's already-read list of published, enabled,
  `kind: :message` subscriptions (the sweep reads them once per batch, not once
  per event). `ctx` carries what the sweep resolved: `:scope`, `:tenant`,
  `:domain`, `:resources` (the domain mapping) and `:event_source`.

  Runs inside the caller's transaction — the sweep gives each event its own —
  so the dispatch row and the instance it records commit together, and the
  `[:subscription_id, :event_id]` identity makes duplicate starts *provably*
  impossible under a partial failure: the loser's insert conflicts and its
  instance rolls back with it.
  """
  @spec dispatch_event(term(), [struct()], map()) :: :ok
  def dispatch_event(event, subscriptions, ctx) do
    raw_ctx = ctx.event_source.context(event)
    feel_ctx = Feel.to_feel_value(raw_ctx)

    if listening?(feel_ctx) do
      subscriptions
      |> Enum.filter(&matches?(&1, feel_ctx))
      |> Enum.each(&dispatch(&1, raw_ctx, feel_ctx, ctx))
    end

    :ok
  end

  # ── stage 1: the index ──────────────────────────────────────────────────

  # One lookup; an event nobody is listening for costs the context build and
  # nothing further. The index is an optimisation, not a gate: when it is not
  # running, the sweep's subscription read is what decides, so a missing index
  # costs queries, never correctness.
  defp listening?(feel_ctx) do
    not Index.started?() or
      Index.interested?(feel_ctx[@event]["resource"], feel_ctx[@event]["action_type"])
  end

  # ── stage 3: match ──────────────────────────────────────────────────────

  # The context's `event.resource` is already the short name — the adapter
  # contract is where the module atom becomes the string people type — so the
  # stored `match_resource` (normalized to the same short form at create) is
  # compared directly. Getting this comparison wrong produces a subscription
  # that matches nothing, silently, which is why both spellings are pinned by
  # `ResourceName`.
  defp matches?(subscription, feel_ctx) do
    event = feel_ctx[@event]

    subscription.match_resource == event["resource"] and
      (is_nil(subscription.match_action) or
         to_string(subscription.match_action) == event["action"]) and
      (is_nil(subscription.match_action_type) or
         to_string(subscription.match_action_type) == event["action_type"])
  end

  # ── stages 4–6 ──────────────────────────────────────────────────────────

  # `raw_ctx` is the adapter's own context — the ledger reads from it, because
  # the FEEL boundary turns integers into decimals and the ledger wants the
  # event's plain values. `feel_ctx` is what every expression evaluates over.
  defp dispatch(subscription, raw_ctx, feel_ctx, ctx) do
    event_id = raw_ctx[@event]["id"]

    if already_dispatched?(ctx.resources.dispatch, subscription, event_id, ctx) do
      # A replayed batch hits here: the existing row is the record, and the
      # only alternative to the pre-check is re-running the funnel and letting
      # the identity abort the transaction — which works (the duplicate
      # instance rolls back with the row) but repeats the work to do it. A
      # second row for the same (subscription, event) cannot exist: the ledger
      # is append-only, and the identity is the point.
      Logger.debug(
        "ash_bpmn trigger #{subscription.key} already dispatched for event #{event_id}"
      )

      :already_dispatched
    else
      do_dispatch(subscription, raw_ctx, feel_ctx, ctx)
    end
  end

  defp do_dispatch(subscription, raw_ctx, feel_ctx, ctx) do
    depth = event_depth(raw_ctx) + 1

    if depth > Config.trigger_max_depth() do
      record(subscription, raw_ctx, ctx, status: :failed, reason: :depth_exceeded, depth: depth)
    else
      case guard(subscription, feel_ctx) do
        :pass ->
          route_and_start(subscription, raw_ctx, feel_ctx, ctx, depth)

        # A plain false is an ordinary no, and an ordinary no records nothing:
        # there is no condition to investigate. (:guard_null and :guard_error
        # exist precisely because they are not ordinary.)
        :refused ->
          nil

        :null ->
          # FEEL folds a missing path or a type mismatch to null, and a guard
          # that cannot answer is not a guard that says yes — but neither is it
          # an error. A plain false records nothing; a null is recorded,
          # because a guard that is silently never true is the bug you want to
          # see.
          record(subscription, raw_ctx, ctx, status: :skipped, reason: :guard_null, depth: depth)

        {:error, detail} ->
          Logger.warning(
            "ash_bpmn trigger #{subscription.key}: guard error: #{inspect(detail, limit: 5)}"
          )

          record(subscription, raw_ctx, ctx, status: :failed, reason: :guard_error, depth: depth)
      end
    end
  end

  defp guard(subscription, feel_ctx) do
    case subscription.guard_feel do
      nil -> :pass
      "" -> :pass
      source -> evaluate_guard(source, feel_ctx)
    end
  end

  # `AshBpmn.Feel.evaluate/3` already reports an *engine* error as `{:ok, nil}`
  # (FEEL semantics: an erroneous expression is a null result), so what remains
  # here is exactly the three-valued answer plus the not-a-boolean case.
  defp evaluate_guard(source, feel_ctx) do
    case Feel.evaluate(source, feel_ctx) do
      {:ok, true} -> :pass
      {:ok, false} -> :refused
      {:ok, nil} -> :null
      {:ok, other} -> {:error, {:guard_not_boolean, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp route_and_start(subscription, raw_ctx, feel_ctx, ctx, depth) do
    case route(subscription, feel_ctx, ctx) do
      {:skipped, :no_rule_fired, _detail} ->
        record(subscription, raw_ctx, ctx,
          status: :skipped,
          reason: :no_rule_fired,
          decision_key: subscription.decision_key,
          depth: depth
        )

      {:error, reason, detail} ->
        # A decision that could not answer is a different row from a decision
        # that answered "nothing": an error is a bug to fix, a no-rule is a
        # modelling gap to close, and folding one into the other hides which.
        Logger.warning(
          "ash_bpmn trigger #{subscription.key}: #{reason}: #{inspect(detail, limit: 5)}"
        )

        record(subscription, raw_ctx, ctx,
          status: :failed,
          reason: reason,
          decision_key: subscription.decision_key,
          depth: depth
        )

      {:ok, targets} ->
        start_all(subscription, raw_ctx, feel_ctx, ctx, depth, targets)
    end
  end

  # A subscription names either a process directly, or a decision that chooses.
  # The decision form may return several, which is what `max_starts_per_event`
  # bounds. An output may name a process, or fall back to the subscription's
  # own `process_key`; neither means the decision answered "nothing".
  defp route(%{route_kind: :static, process_key: key}, _feel_ctx, _ctx) when is_binary(key) do
    {:ok, [%{process_key: key, fired_rule: nil, decision_key: nil}]}
  end

  defp route(%{route_kind: :decision} = subscription, feel_ctx, ctx) do
    key = subscription.decision_key

    resolver = Config.decision_resolver!()

    case resolver.decide(key, feel_ctx, %{tenant: ctx.tenant}) do
      {:ok, %{outputs: outputs} = result} ->
        result_rule = result |> Map.get(:rule_ids) |> List.wrap() |> List.first()

        targets =
          outputs
          |> List.wrap()
          |> Enum.map(&target_from_outputs(&1, subscription))
          |> Enum.reject(&is_nil/1)
          |> Enum.map(fn target ->
            if is_nil(target.fired_rule),
              do: Map.put(target, :fired_rule, result_rule),
              else: target
          end)

        case targets do
          [] ->
            {:skipped, :no_rule_fired, %{decision: key}}

          targets ->
            {:ok, Enum.map(targets, &Map.put(&1, :decision_key, key))}
        end

      {:error, reason} ->
        {:error, :decision_error, %{decision: key, detail: inspect(reason, limit: 5)}}
    end
  end

  # An output may name a process; a subscription whose decision does not name
  # one may still fall back to its own `process_key`. Neither is a no-rule:
  # only "no name anywhere" is.
  defp target_from_outputs(outputs, subscription) when is_map(outputs) do
    case Map.get(outputs, "process_key") || subscription.process_key do
      nil -> nil
      key -> %{process_key: key, fired_rule: fired_rule(outputs)}
    end
  end

  defp target_from_outputs(_outputs, _subscription), do: nil

  # The resolver's optional `rule_ids` — "when the engine can say" is the
  # contract's own phrase; a host that does not track rules simply omits them.
  # Per-output rule ids would be better under a COLLECT hit policy; the
  # contract carries them at the result level, so the row records what exists.
  defp fired_rule(outputs) do
    case get_in(outputs, ["rule_ids"]) do
      [first | _] when is_binary(first) -> first
      _ -> nil
    end
  end

  defp start_all(subscription, raw_ctx, feel_ctx, ctx, depth, targets) do
    if length(targets) > subscription.max_starts_per_event do
      # Refusing loudly beats starting fifty thousand processes from one write.
      Logger.error(
        "ash_bpmn trigger #{subscription.key}: fan-out refused — wanted #{length(targets)}, " <>
          "allowed #{subscription.max_starts_per_event}"
      )

      record(subscription, raw_ctx, ctx,
        status: :failed,
        reason: :fan_out_exceeded,
        depth: depth
      )
    else
      Enum.each(targets, &start_one(subscription, raw_ctx, feel_ctx, ctx, depth, &1))
    end
  end

  defp start_one(subscription, raw_ctx, feel_ctx, ctx, depth, target) do
    case latest_definition(ctx.resources.definition, target.process_key, ctx.scope) do
      [] ->
        record(subscription, raw_ctx, ctx,
          status: :failed,
          reason: :no_definition,
          process_key: target.process_key,
          decision_key: target.decision_key,
          depth: depth
        )

      [definition | _] ->
        do_start_one(subscription, raw_ctx, feel_ctx, ctx, depth, target, definition)
    end
  end

  # Wrapped, and the wrapping is load-bearing rather than defensive: an
  # exception escaping here would abort the event's own transaction and
  # propagate into the sweep, costing the batch its cursor advance. A process
  # that failed to start must still leave the row that says it tried.
  defp do_start_one(subscription, raw_ctx, feel_ctx, ctx, depth, target, definition) do
    do_start(subscription, raw_ctx, feel_ctx, ctx, depth, target, definition)
  rescue
    e ->
      Logger.error(
        "ash_bpmn trigger #{subscription.key}: start failed: #{Exception.message(e)}"
      )

      record(subscription, raw_ctx, ctx,
        status: :failed,
        reason: :decision_error,
        process_key: target.process_key,
        decision_key: target.decision_key,
        depth: depth
      )
  end

  defp do_start(subscription, raw_ctx, feel_ctx, ctx, depth, target, definition) do
    with {:ok, subject_id} <- subject_id(subscription, feel_ctx),
         {:ok, subject_module} <- subject_module(subscription),
         {:ok, instance} <-
           AshBpmn.start_instance(ctx.domain,
             definition: definition,
             # The subject is identified by what the event recorded, not by a
             # live read: a trigger fires on what happened. The process re-reads
             # it through Ash when it needs the current state.
             subject: %{__struct__: subject_module, id: subject_id},
             actor: ctx.scope.actor,
             # The human is still named when the context carries one. Authority
             # and accountability are different columns: the engine runs as its
             # configured actor, and this is the "whose request was this"
             # answer.
             started_by_id: get_in(feel_ctx, ["actor", "user_id"]),
             tenant: ctx.tenant,
             correlation_id: feel_ctx[@metadata]["correlation_id"]
           ) do
      record(subscription, raw_ctx, ctx,
        status: :started,
        process_key: target.process_key,
        decision_key: target.decision_key,
        fired_rule: target.fired_rule,
        instance_id: instance.id,
        depth: depth
      )
    else
      {:error, :no_subject} ->
        Logger.warning(
          "ash_bpmn trigger #{subscription.key}: subject_of produced no value for event " <>
            "#{raw_ctx[@event]["id"]}"
        )

        record(subscription, raw_ctx, ctx,
          status: :failed,
          reason: :decision_error,
          process_key: target.process_key,
          decision_key: target.decision_key,
          depth: depth
        )

      {:error, :no_subject_resource} ->
        Logger.warning(
          "ash_bpmn trigger #{subscription.key}: match_resource " <>
            "#{subscription.match_resource} does not resolve to a loadable resource"
        )

        record(subscription, raw_ctx, ctx,
          status: :failed,
          reason: :decision_error,
          process_key: target.process_key,
          decision_key: target.decision_key,
          depth: depth
        )

      {:error, reason} ->
        # The start's own message, surfaced verbatim where there is a place to
        # put it. The dispatch row carries no detail column — a dispatch is
        # already the record of an event — so the verbatim text goes to the
        # log, and the row says which subscription, which event, which process.
        Logger.error(
          "ash_bpmn trigger #{subscription.key}: start failed: #{inspect(reason, limit: 10)}"
        )

        record(subscription, raw_ctx, ctx,
          status: :failed,
          reason: :decision_error,
          process_key: target.process_key,
          decision_key: target.decision_key,
          depth: depth
        )
    end
  end

  defp latest_definition(definition_resource, process_key, scope) do
    definition_resource.latest_published!(process_key, AshBpmn.Scope.engine(scope))
  end

  defp subject_id(subscription, feel_ctx) do
    source = subscription.subject_of || "event.record_id"

    case Feel.evaluate(source, feel_ctx) do
      {:ok, id} when is_binary(id) and id != "" -> {:ok, id}
      {:ok, id} when is_integer(id) -> {:ok, Integer.to_string(id)}
      _ -> {:error, :no_subject}
    end
  end

  defp subject_module(subscription) do
    case ResourceName.resolve(subscription.match_resource) do
      {:ok, module} -> {:ok, module}
      :error -> {:error, :no_subject_resource}
    end
  end

  defp event_depth(raw_ctx), do: get_in(raw_ctx, [@metadata, "trigger_depth"]) || 0

  defp already_dispatched?(dispatch_resource, subscription, event_id, ctx) do
    # `Ash.read_one/2` answers in a tuple, so the row's presence is a pattern
    # match on the payload, not a nil check on the result.
    match?({:ok, %{}},
      dispatch_resource
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(subscription_id == ^subscription.id and event_id == ^event_id)
      |> Ash.read_one(AshBpmn.Scope.engine(ctx.scope))
    )
  end

  # ── the ledger ──────────────────────────────────────────────────────────

  defp record(subscription, raw_ctx, ctx, opts) do
    attrs =
      Map.merge(
        %{
          subscription_id: subscription.id,
          event_id: raw_ctx[@event]["id"],
          event_sequence: raw_ctx[@event]["sequence"],
          event_occurred_at: occurred_at(raw_ctx),
          kind: :start,
          correlation_id: raw_ctx[@metadata]["correlation_id"],
          depth: event_depth(raw_ctx) + 1
        },
        Map.new(opts)
      )

    ctx.resources.dispatch.create!(attrs, AshBpmn.Scope.engine(ctx.scope))
    :ok
  rescue
    e ->
      # The identity makes a replayed batch idempotent, so a duplicate here is
      # expected rather than exceptional — and it is what makes a racing
      # sweep's duplicate start *impossible*, not merely unlikely: the loser's
      # insert conflicts and its instance rolls back with it. Anything else is
      # logged and the sweep continues: one subscription must not stop the
      # others.
      Logger.warning(
        "ash_bpmn trigger dispatch for event #{raw_ctx[@event]["id"]} not recorded: " <>
          Exception.message(e)
      )

      :ok
  end

  # The context carries `occurred_at` as a `DateTime` (`to_feel_value` passes
  # those through untouched), and it is the watermark lookback windows are
  # measured against — which is why a missing copy is filled, not nilled.
  defp occurred_at(feel_ctx) do
    feel_ctx[@event]["occurred_at"] || DateTime.utc_now()
  end
end
