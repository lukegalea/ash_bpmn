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

  ## Depth: on the dispatch row, on the instance, and on what the instance writes

  Subscriptions may not match `ash_bpmn` resources (publish-time refusal),
  which closes the direct cycle. Two cycles remain: a process whose steps write
  the host resource its own subscription watches, and a cycle through
  `AshBpmn.Resources.Signal`. `depth` bounds both (G-5).

    * An event's depth is read from its context metadata (`trigger_depth`, `0`
      when absent — an event a person caused). A signal row carries its own
      `depth` (the thrower's `trigger_depth + 1`), which counts as the hop
      already taken.
    * The dispatch records `depth + 1`, and the instance it starts is started
      with `trigger_depth: depth`, so the instance knows which hop it is.
    * The engine passes the instance's `trigger_depth` to everything its steps
      write through: an `ash:call` action finds it at
      `context.ash_bpmn.trigger_depth`, and the host's `AshBpmn.ActionInvoker`
      finds it at `ctx.trigger_depth`. **Stamping it into the audit metadata of
      the rows those writes produce is the host's half**, the same way the host
      stamps the correlation id; without it every lap looks like a person's
      write and the bound never fires.

  Past `AshBpmn.Config.trigger_max_depth/0` the dispatch refuses with
  `:depth_exceeded` and starts nothing.

  ## Versions, and the event window

  A superseded subscription version keeps the events up to its
  `retired_sequence`, and its successor takes the events after its
  `effective_sequence` (see `AshBpmn.Resources.Subscription`). The funnel
  offers an event only to the versions in force for its sequence, so a replay
  or a re-drive of an old event can never start it again under the new version.

  ## Re-drive

  `dispatch_event/4` with `redrive: true` runs the funnel again for an event
  whose dispatch failed. A `:failed` row is not counted as "already
  dispatched" then (nor by the dispatch identity), while any other row still
  is, so a re-drive can turn a failure into a start but never start twice. An
  ordinary sweep treats every row, failed included, as the record and does not
  retry it. Catch delivery is not repeated by a re-drive.

  ## A funnel that raises

  An exception the funnel does not catch rolls back the event's transaction.
  The sweep then calls `record_aborted/4`, which writes a `:failed` row with
  reason `:funnel_error` for each subscription the event could have reached,
  in a fresh transaction, and the cursor passes the event only after that.
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
  @data "data"

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
  @spec dispatch_event(term(), [struct()], map(), keyword()) :: :ok
  def dispatch_event(event, subscriptions, ctx, opts \\ []) do
    redrive? = Keyword.get(opts, :redrive, false)
    raw_ctx = ctx.event_source.context(event)
    feel_ctx = Feel.to_feel_value(raw_ctx)

    if listening?(feel_ctx) do
      signal? = signal_event?(feel_ctx, ctx)
      depth = event_depth(raw_ctx, signal?) + 1

      subscriptions
      |> candidates(feel_ctx, signal?, event_sequence(event, raw_ctx, ctx))
      |> Enum.each(&dispatch(&1, raw_ctx, feel_ctx, ctx, depth, redrive?))
    end

    # Deliberately outside the index gate above. `Index` is built from published
    # *subscriptions*, and a token parked at a message catch is not one -- it is a running
    # instance's private interest in something. Putting delivery behind that gate would mean a
    # process waiting for a payment was woken only if some unrelated subscription happened to
    # be watching payments too. A re-drive is about subscriptions, and does not deliver again.
    unless redrive?, do: deliver_to_waiting(feel_ctx, ctx)

    :ok
  end

  # The subscriptions this event is offered to: the right kind, a structural match, and the
  # version in force for the event's sequence.
  defp candidates(subscriptions, feel_ctx, signal?, sequence) do
    Enum.filter(subscriptions, fn subscription ->
      # A signal subscription is only ever offered signal events, and a message
      # subscription never is. Without this a `:message` subscription matching the signal
      # resource by name would start a process on every signal thrown.
      subscription.kind == :signal == signal? and matches?(subscription, feel_ctx) and
        in_force?(subscription, sequence)
    end)
  end

  # See "Versions, and the event window" in the moduledoc. A sequence the funnel cannot read
  # is offered to every version, which is what happened before versions had windows.
  defp in_force?(_subscription, nil), do: true

  defp in_force?(subscription, sequence) do
    effective = Map.get(subscription, :effective_sequence)
    retired = Map.get(subscription, :retired_sequence)

    (is_nil(effective) or sequence > effective) and (is_nil(retired) or sequence <= retired)
  end

  defp event_sequence(event, raw_ctx, ctx) do
    case get_in(raw_ctx, [@event, "sequence"]) do
      sequence when is_integer(sequence) -> sequence
      _ -> ctx.event_source.sequence(event)
    end
  rescue
    _ -> nil
  end

  @doc """
  Records that the funnel raised for `event`, after its transaction rolled back.

  Writes one `:failed` dispatch with reason `:funnel_error` and the message in `error` for
  each subscription the event could have reached: the ones it matches, when its context can
  still be built, and every one offered otherwise (nothing else can be known about an event
  whose context raises). A subscription that already has a row for the event is left alone.

  Raises when a row is owed and cannot be written, so the caller does not move its cursor
  past an event that left no trace. Call it in a transaction of its own.
  """
  @spec record_aborted(term(), [struct()], map(), String.t()) :: :ok
  def record_aborted(event, subscriptions, ctx, message) do
    {raw_ctx, owed} =
      case safe_context(ctx.event_source, event) do
        {:ok, raw_ctx} ->
          feel_ctx = Feel.to_feel_value(raw_ctx)

          if listening?(feel_ctx) do
            signal? = signal_event?(feel_ctx, ctx)
            sequence = event_sequence(event, raw_ctx, ctx)
            {raw_ctx, candidates(subscriptions, feel_ctx, signal?, sequence)}
          else
            {raw_ctx, []}
          end

        :error ->
          sequence = safe(fn -> ctx.event_source.sequence(event) end)
          {nil, Enum.filter(subscriptions, &in_force?(&1, sequence))}
      end

    Enum.each(owed, &record_abort!(&1, event, raw_ctx, ctx, message))
    :ok
  end

  defp record_abort!(subscription, event, raw_ctx, ctx, message) do
    event_id = get_in(raw_ctx || %{}, [@event, "id"]) || adapter_event_id(event)

    if is_nil(event_id) do
      raise "ash_bpmn could not record the aborted dispatch of an event with no id " <>
              "(subscription #{subscription.key}): #{message}"
    end

    unless already_dispatched?(ctx.resources.dispatch, subscription, event_id, ctx, false) do
      signal? = raw_ctx != nil and Map.get(subscription, :kind) == :signal

      attrs = %{
        subscription_id: subscription.id,
        event_id: event_id,
        event_sequence:
          get_in(raw_ctx || %{}, [@event, "sequence"]) || ctx.event_source.sequence(event),
        event_occurred_at:
          get_in(raw_ctx || %{}, [@event, "occurred_at"]) || adapter_occurred_at(event, ctx),
        kind: :start,
        status: :failed,
        reason: :funnel_error,
        error: String.slice(message, 0, 2_000),
        correlation_id: get_in(raw_ctx || %{}, [@metadata, "correlation_id"]),
        depth: if(raw_ctx, do: event_depth(raw_ctx, signal?) + 1, else: 0)
      }

      try do
        ctx.resources.dispatch.create!(attrs, AshBpmn.Scope.engine(ctx.scope))
      rescue
        e ->
          reraise RuntimeError,
                  [
                    message:
                      "ash_bpmn could not record the aborted dispatch of event #{event_id} " <>
                        "for subscription #{subscription.key}: #{Exception.message(e)}"
                  ],
                  __STACKTRACE__
      end
    end

    :ok
  end

  defp safe_context(event_source, event) do
    {:ok, event_source.context(event)}
  rescue
    _ -> :error
  end

  defp safe(fun) do
    fun.()
  rescue
    _ -> nil
  end

  defp adapter_event_id(event) when is_map(event), do: Map.get(event, :id)
  defp adapter_event_id(_event), do: nil

  defp adapter_occurred_at(event, ctx) do
    safe(fn -> ctx.event_source.occurred_at(event) end) || DateTime.utc_now()
  end

  # ── catch delivery ──────────────────────────────────────────────────────

  # Waking the tokens parked at a message catch event for this kind of event.
  #
  # The query is the reason `subscription_signature` exists. It pins resource and action, is
  # backed by a partial index on `status = 'waiting'`, and is therefore proportional to the
  # tokens actually parked rather than to every token the system has ever created. The
  # correlation key is compared afterwards, in memory, over an already small set.
  #
  # The `match` expression belongs to the *node*, not the token, so it is evaluated once per
  # distinct node rather than once per token -- a hundred instances parked at the same catch
  # event cost one evaluation, not a hundred.
  defp deliver_to_waiting(feel_ctx, ctx) do
    token_resource = ctx.resources.token

    signatures = event_signatures(feel_ctx, ctx)

    token_resource
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(status == :waiting and subscription_signature in ^signatures)
    |> Ash.read!(AshBpmn.Scope.engine(ctx.scope))
    |> Enum.group_by(& &1.instance_id)
    |> Enum.each(fn {instance_id, tokens} ->
      deliver_to_instance(instance_id, tokens, feel_ctx, ctx)
    end)
  rescue
    # A waiting token that cannot be read must not wedge the sweep -- the batch's other events
    # are unrelated to it, and the cursor has to keep moving. The sweep wraps each event in
    # its own transaction, so this costs one event's delivery.
    error ->
      Logger.error("ash_bpmn catch delivery failed: #{Exception.message(error)}")
      :ok
  end

  # The subscription signatures this event can wake: the tokens parked for its resource and
  # action, for any action on its resource, or for a change to its resource.
  #
  # A signal event carries the name it broadcast, so its signature is derived from the
  # *payload* rather than from the resource and action the way a message's is. Both shapes
  # are queried together because a single read over one partial index beats two.
  defp event_signatures(feel_ctx, ctx) do
    event = feel_ctx[@event]

    [
      "message:#{event["resource"]}:#{event["action"]}",
      "message:#{event["resource"]}:*",
      "conditional:#{event["resource"]}"
    ] ++ signal_signatures(feel_ctx, ctx)
  end

  # `["signal:<ref>"]` when this event is a signal row, `[]` otherwise.
  #
  # Identified by resource rather than by the presence of a name field, because "has a name"
  # is a property plenty of business records share and mistaking one for a signal would wake
  # processes on an unrelated write.
  defp signal_signatures(feel_ctx, ctx) do
    name = signal_name(feel_ctx)

    if is_binary(name) and signal_event?(feel_ctx, ctx) do
      ["signal:#{name}"]
    else
      []
    end
  end

  defp deliver_to_instance(instance_id, tokens, feel_ctx, ctx) do
    instance =
      ctx.resources.instance
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(id == ^instance_id)
      |> Ash.read_one!(AshBpmn.Scope.engine(ctx.scope))

    if instance && instance.status == :running do
      deliver_to_running(instance, tokens, feel_ctx, ctx)
    else
      # Belt and braces over the token status the claim already checks. Cancelling an instance
      # kills its waiting tokens, so this should never fire -- but the correlator finds tokens
      # by signature and would otherwise have no opinion about the instance they belong to, and
      # "resumed a process that had already ended" is not a failure worth leaving one bug away.
      :ok
    end
  end

  @doc """
  Attempts one event against one already-parked token.

  Public because the lookback scan needs exactly this and nothing else: it has a token, it
  has a historical event, and it wants the same decision the live path makes. Duplicating
  that decision is how the two drift until an event delivers live and not on replay.

  That decision starts where the live path's query does: the event must be one the token
  subscribed to (its resource and action, by `subscription_signature`). The live path gets
  that from the query that found the token; a scan of history has every kind of event in it,
  so the check is made here. Without it, any event of the same resource whose `match`
  happened to carry the token's key would wake it, whatever its action. A token with no
  signature subscribed to nothing and is never woken here.
  """
  @spec deliver_one(struct(), map(), map(), map()) :: :ok
  def deliver_one(token, graph, feel_ctx, ctx) do
    with true <- token.subscription_signature in event_signatures(feel_ctx, ctx),
         {:ok, key} <- expected_key(graph, token.node_id, feel_ctx),
         true <- token.correlation_key == key do
      wake(token, token.node_id, feel_ctx, ctx, graph)
    end

    :ok
  end

  defp deliver_to_running(instance, tokens, feel_ctx, ctx) do
    graph =
      AshBpmn.DefinitionLoader.load!(
        ctx.resources.definition,
        instance.definition_id,
        instance,
        ctx.scope
      ).graph

    tokens
    |> Enum.group_by(& &1.node_id)
    |> Enum.each(fn {node_id, node_tokens} ->
      # Broadcast versus addressed, and it is the only branch in delivery that matters. A
      # signal wakes every token listening for that name -- there is no key to compare, and
      # asking which token it was "for" is a question with no answer. The signature has
      # already narrowed the set to tokens listening for this exact name.
      case catch_kind(graph, node_id) do
        # Broadcast. A signal wakes every token listening for that name -- there is no key to
        # compare, and asking which token it was "for" is a question with no answer.
        "signal" ->
          Enum.each(node_tokens, &wake(&1, node_id, feel_ctx, ctx, graph))

        # The subject changed. Correlate on its identity first, then ask the condition -- and
        # ask it of the subject as it now is, read live, not of the event's snapshot. The
        # snapshot is what the write contained; the condition is about the record.
        "conditional" ->
          node_tokens
          |> Enum.filter(&(&1.correlation_key == to_string(feel_ctx[@event]["record_id"])))
          |> Enum.each(&maybe_wake_conditional(&1, node_id, graph, feel_ctx, ctx))

        _ ->
          deliver_addressed(node_tokens, graph, node_id, feel_ctx, ctx)
      end
    end)
  end

  # The key this event carries, by the node's own `match` expression. A null or an error means
  # this event is not addressed to anything at this node -- an event of the right kind that
  # simply does not carry the field -- which is an ordinary no, not a condition to report.
  defp wake_kind(graph, node_id) do
    case catch_kind(graph, node_id) do
      "signal" -> :signal_received
      "conditional" -> :condition_met
      _ -> :message_received
    end
  end

  defp deliver_addressed(tokens, graph, node_id, feel_ctx, ctx) do
    case expected_key(graph, node_id, feel_ctx) do
      {:ok, key} ->
        tokens
        |> Enum.filter(&(&1.correlation_key == key))
        |> Enum.each(&wake(&1, node_id, feel_ctx, ctx, graph))

      :skip ->
        :ok
    end
  end

  defp catch_kind(graph, node_id), do: get_in(graph, ["nodes", node_id, "catch", "kind"])

  # The condition is evaluated against the subject loaded *now*, through the same path every
  # other node reads it by -- including the node's own `ash:load`. An event's `data` is the
  # snapshot of what that write contained, which is not the same thing and would answer a
  # different question on a partial update.
  defp maybe_wake_conditional(token, node_id, graph, feel_ctx, ctx) do
    instance =
      ctx.resources.instance
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(id == ^token.instance_id)
      |> Ash.read_one!(AshBpmn.Scope.engine(ctx.scope))

    subject =
      AshBpmn.Subject.load(
        instance,
        ctx.scope,
        get_in(graph, ["nodes", node_id, "load"]) || []
      )

    expr_ctx = %{
      "subject" => Feel.to_feel_value(subject),
      "routing" => Feel.to_feel_value(token.routing || %{})
    }

    condition = get_in(graph, ["nodes", node_id, "catch", "condition"])

    case Feel.evaluate_condition(condition, expr_ctx) do
      {:ok, true} ->
        wake(token, node_id, feel_ctx, ctx, graph)

      # False is the ordinary answer -- most updates to a watched record do not satisfy the
      # condition -- and null means the condition could not be answered, which is not a reason
      # to wake. Neither is recorded: one row per non-matching write would bury the log.
      _ ->
        :ok
    end
  end

  defp expected_key(graph, node_id, feel_ctx) do
    spec = get_in(graph, ["nodes", node_id, "catch"]) || %{}

    case spec["match"] && Feel.evaluate(spec["match"], feel_ctx) do
      # `:skip`, not an empty string. Folding null into `""` would wake any token whose own
      # key was empty, turning "this event carries no key" into "this event carries the empty
      # key" -- the broadcast this design exists to avoid, reached from the other side.
      #
      # Not covered by a test: every route to an empty correlation key runs through a required
      # attribute or a FEEL literal that does not survive the park, so the two behaviours are
      # currently indistinguishable from outside. The distinction is kept because it costs
      # nothing and stops being theoretical the moment a subject has an optional string field.
      {:ok, nil} -> :skip
      {:ok, value} -> {:ok, to_string(value)}
      _ -> :skip
    end
  end

  defp wake(token, node_id, feel_ctx, ctx, graph) do
    engine = AshBpmn.Scope.engine(ctx.scope)

    case ctx.resources.token.claim_waiting(token, engine) do
      # Losing is ordinary: a redelivered batch, or a branch pruned between the read and here.
      {:error, _} ->
        :ok

      {:ok, token} ->
        # A receive task's deadlines are moot once its message has arrived. Left armed they
        # would lose at the claim anyway; defused, they do not fire at all.
        AshBpmn.Runtime.Oban.cancel_all(%{"token_id" => token.id, "kind" => "boundary"})

        ctx.resources.process_event.create!(
          %{
            instance_id: token.instance_id,
            token_id: token.id,
            node_id: node_id,
            kind: wake_kind(graph, node_id),
            data: %{
              "event_id" => feel_ctx[@event]["id"],
              "resource" => feel_ctx[@event]["resource"],
              "action" => feel_ctx[@event]["action"]
            }
          },
          engine
        )

        advance_from_catch(token, node_id, ctx)
    end
  end

  # The same shape as the timer catch's wake: consume, mint an active token on the outgoing
  # flow, enqueue an ordinary advance. A catch event has exactly one way out, which the
  # compiler guarantees.
  defp advance_from_catch(token, node_id, ctx) do
    engine = AshBpmn.Scope.engine(ctx.scope)

    instance =
      ctx.resources.instance
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(id == ^token.instance_id)
      |> Ash.read_one!(engine)

    graph =
      AshBpmn.DefinitionLoader.load!(
        ctx.resources.definition,
        instance.definition_id,
        instance,
        ctx.scope
      ).graph

    case AshBpmn.Runtime.Routing.outgoing(graph, node_id) do
      [flow | _] ->
        ctx.resources.token.consume!(token, engine)

        new_token =
          ctx.resources.token.create!(
            %{
              instance_id: token.instance_id,
              node_id: flow["to"],
              status: :active,
              routing: token.routing || %{}
            },
            engine
          )

        AshBpmn.Runtime.Oban.insert(
          AshBpmn.Runtime.AdvanceWorker,
          AshBpmn.Scope.to_job_args(ctx.scope, %{
            "instance_id" => token.instance_id,
            "token_id" => new_token.id,
            "node_id" => flow["to"]
          })
        )

      [] ->
        ctx.resources.token.consume!(token, engine)
    end
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

  # Whether *this* event is a signal row, by resource rather than by the presence of a name
  # field -- plenty of business records have a name, and mistaking one for a signal would
  # start processes on an unrelated write.
  defp signal_event?(feel_ctx, ctx) do
    signal_module = Map.get(ctx.resources, :signal)

    signal_module != nil and
      same_resource?(signal_module, feel_ctx[@event]["resource"])
  end

  # Either spelling of the event's resource: `"MyApp.Signal"`, which an adapter that uses
  # `inspect/1` emits (the reference one does), or `"Elixir.MyApp.Signal"`. Comparing only
  # the second never recognised a signal row from the first kind of adapter.
  defp same_resource?(module, name) when is_binary(name),
    do: ResourceName.short(inspect(module)) == ResourceName.short(name)

  defp same_resource?(_module, _name), do: false

  # ── stage 3: match ──────────────────────────────────────────────────────

  # The context's `event.resource` is already the short name — the adapter
  # contract is where the module atom becomes the string people type — so the
  # stored `match_resource` (normalized to the same short form at create) is
  # compared directly. Getting this comparison wrong produces a subscription
  # that matches nothing, silently, which is why both spellings are pinned by
  # `ResourceName`.
  @doc """
  Whether this subscription would be offered this event, exposed for tests.

  The kind gate and the match are one decision and are tested as one: a signal subscription
  hearing a message event, or a message subscription hearing a signal, are the two ways this
  goes wrong, and neither is reachable through `dispatch_event/3` without a whole instance
  behind it.
  """
  @spec matches_for_test?(map(), map(), keyword()) :: boolean()
  def matches_for_test?(subscription, feel_ctx, opts) do
    signal? = Keyword.fetch!(opts, :signal?)
    subscription.kind == :signal == signal? and matches?(subscription, feel_ctx)
  end

  # A signal subscription hears a *name*; a message subscription matches a resource and
  # action. The two are told apart by the subscription's own kind rather than by sniffing the
  # event, because a subscription that declared `signal_name` and then matched on resource
  # would be a configuration nobody could debug from the outside.
  defp matches?(%{kind: :signal} = subscription, feel_ctx) do
    signal_name(feel_ctx) == subscription.signal_name
  end

  defp matches?(subscription, feel_ctx) do
    event = feel_ctx[@event]

    subscription.match_resource == event["resource"] and
      (is_nil(subscription.match_action) or
         to_string(subscription.match_action) == event["action"]) and
      (is_nil(subscription.match_action_type) or
         to_string(subscription.match_action_type) == event["action_type"])
  end

  # A signal event carries its name in the row's data. `nil` for anything that is not one,
  # which is what makes a signal subscription match nothing else.
  defp signal_name(feel_ctx), do: get_in(feel_ctx, [@data, "name"])

  # ── stages 4–6 ──────────────────────────────────────────────────────────

  # `raw_ctx` is the adapter's own context — the ledger reads from it, because
  # the FEEL boundary turns integers into decimals and the ledger wants the
  # event's plain values. `feel_ctx` is what every expression evaluates over.
  defp dispatch(subscription, raw_ctx, feel_ctx, ctx, depth, redrive?) do
    event_id = raw_ctx[@event]["id"]

    if already_dispatched?(ctx.resources.dispatch, subscription, event_id, ctx, redrive?) do
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
      do_dispatch(subscription, raw_ctx, feel_ctx, ctx, depth)
    end
  end

  defp do_dispatch(subscription, raw_ctx, feel_ctx, ctx, depth) do
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
      Logger.error("ash_bpmn trigger #{subscription.key}: start failed: #{Exception.message(e)}")

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
             correlation_id: feel_ctx[@metadata]["correlation_id"],
             # The hop this instance is. What it writes carries it (see the moduledoc),
             # which is what lets the next lap be counted.
             trigger_depth: depth
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

  # The hops already taken before this event: the metadata's `trigger_depth` (stamped by the
  # host on what a triggered process writes), and for a signal row its own `depth`, which
  # already counts the throw as a hop. A business record's `depth` field is not read: only a
  # signal row's is the engine's.
  defp event_depth(raw_ctx, signal?) do
    stamped = to_depth(get_in(raw_ctx, [@metadata, "trigger_depth"]))

    if signal? do
      max(stamped, to_depth(signal_depth(raw_ctx)) - 1)
    else
      stamped
    end
  end

  defp signal_depth(raw_ctx) do
    case raw_ctx[@data] do
      %{"depth" => depth} -> depth
      %{depth: depth} -> depth
      _ -> nil
    end
  end

  defp to_depth(depth) when is_integer(depth), do: depth
  defp to_depth(%Decimal{} = depth), do: Decimal.to_integer(depth)

  defp to_depth(depth) when is_binary(depth) do
    case Integer.parse(depth) do
      {value, ""} -> value
      _ -> 0
    end
  end

  defp to_depth(_depth), do: 0

  # A re-drive does not count a `:failed` row as the record: it is the record of the thing
  # being retried. See "Re-drive" in the moduledoc.
  defp already_dispatched?(dispatch_resource, subscription, event_id, ctx, redrive?) do
    query =
      dispatch_resource
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(subscription_id == ^subscription.id and event_id == ^event_id)

    query = if redrive?, do: Ash.Query.filter(query, status != :failed), else: query

    # `Ash.read/2` answers in a tuple, so the rows' presence is a pattern match on the
    # payload, not a nil check on the result. Several failed rows may share the pair.
    match?(
      {:ok, [_ | _]},
      query |> Ash.Query.limit(1) |> Ash.read(AshBpmn.Scope.engine(ctx.scope))
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
          correlation_id: raw_ctx[@metadata]["correlation_id"]
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
