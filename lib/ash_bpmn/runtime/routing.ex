# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.Runtime.Routing do
  @moduledoc """
  The one place a process decides which way to go.

  Three separate implementations of "which outgoing flow do we take" had grown, and they had
  already drifted apart in ways nobody would find by reading any one of them:

    * `Interpreter.exclusive_gateway/4` — the correct one. Three-valued FEEL, `null` recorded
      as a `:condition_null` event, `{:error, _}` propagated so the job retries rather than
      guessing a branch, `default=` honoured.
    * `AshBpmn.advance_token_after_task/4` — collapsed `null` and `{:error, _}` into "branch
      not taken" with a bare `_ -> false`, so no `:condition_null` was ever recorded after a
      human task and a FEEL failure routed down `List.first(flows)`. Its default-flow lookup
      compared `f["id"]` against flows taken straight from `Map.values(graph["flows"])`, which
      carry no `"id"` at all — so the declared default was dead code and never selected.
    * `TimerWorker.fire_timer(_, _, "expire", _)` — evaluated nothing whatsoever and took the
      first outgoing flow, so a task that expired was misrouted whenever its diagram routed
      expiry anywhere other than first.

  That is engine hygiene #3 and #4 in `docs/bpmn-event-dimension/05-hygiene.md`, and #3 is
  literally the drift #4 predicted. This module is the fix: one router, called by all three.

  ## Why a module rather than exporting the interpreter's private

  Phase 3 adds a fourth and fifth caller — boundary events and timer catch nodes both route
  out of a node they did not enter normally. A private function made public for one caller
  becomes public for five, in a module that is already eight hundred lines about something
  else. Naming the concept costs one file and makes "there is exactly one router" a fact you
  can check rather than a convention you have to trust.

  ## The fallback chain, and why it is a parameter

  A gateway and a task do not fail the same way.

  An exclusive gateway whose conditions all answer `false` with no `default=` is a modelling
  error: the diagram says nothing about where the token goes, and inventing an answer is how a
  process silently does the wrong thing. That must surface.

  A task with one plain outgoing flow is not making a decision at all — BPMN gives it exactly
  one sequence flow and it is taken. Requiring a `default=` there would refuse every ordinary
  diagram.

  So `:fallback` says which of those two a caller is: `:none` for a gateway, and
  `:single_unconditioned` for a node whose single unconditioned flow is simply its continuation.
  Neither ever falls back to "the first flow", which is what both broken implementations did.
  """

  @type flow :: %{required(String.t()) => term()}
  @type decision :: %{flow: flow() | nil, nulls: [flow()], outgoing: [flow()]}

  @doc """
  The outgoing flows of `node_id`, each carrying its own `"id"`, in a stable order.

  The `"id"` matters more than it looks: flows are stored in the snapshot as a map keyed by
  id, so `Map.values/1` loses it — which is exactly how the facade's `default=` lookup came to
  compare against `nil` forever.
  """
  @spec outgoing(map(), String.t()) :: [flow()]
  def outgoing(graph, node_id) do
    graph["flows"]
    |> Enum.filter(fn {_id, flow} -> flow["from"] == node_id end)
    |> Enum.map(fn {id, flow} -> Map.put(flow, "id", id) end)
    |> Enum.sort_by(& &1["id"])
  end

  @doc """
  Chooses the outgoing flow from `node_id` under `expr_ctx`.

  Returns `{:ok, %{flow: flow | nil, nulls: [flow], outgoing: [flow]}}`. A `nil` flow means
  nothing was selected and the caller decides whether that is an error — a gateway says yes, a
  terminating path says no.

  `nulls` is every flow whose condition evaluated to FEEL `null`, returned rather than logged
  here so the caller records them with its own node and instance ids. A condition that is
  silently never true looks exactly like one that is legitimately false, and is a far worse
  bug; that distinction is the whole reason this returns three things instead of one.

  An `{:error, _}` from the expression engine propagates. It is not a FEEL value and must not
  degrade into "branch not taken": the job retries and the instance fails rather than routing
  itself down a path nobody chose.

  ## Options

    * `:fallback` — `:none` (default) or `:single_unconditioned`. See the moduledoc.
  """
  @spec choose(map(), String.t(), map(), keyword()) :: {:ok, decision()} | {:error, String.t()}
  def choose(graph, node_id, expr_ctx, opts \\ []) do
    fallback = Keyword.get(opts, :fallback, :none)
    flows = outgoing(graph, node_id)
    node = graph["nodes"][node_id] || %{}

    case evaluate(flows, expr_ctx) do
      {:error, reason} ->
        {:error, reason}

      {:ok, chosen, nulls} ->
        {:ok,
         %{
           flow: chosen || default_flow(flows, node) || fallback_flow(flows, fallback),
           nulls: nulls,
           outgoing: flows
         }}
    end
  end

  @doc """
  A one-line summary of null-valued conditions, for an error message.

  Empty string when there were none, so it can be appended unconditionally.
  """
  @spec null_summary([flow()]) :: String.t()
  def null_summary([]), do: ""

  def null_summary(nulls),
    do:
      " (#{length(nulls)} condition(s) evaluated to null: " <>
        Enum.map_join(nulls, ", ", & &1["id"]) <> ")"

  # Walks the flows in order and stops at the first condition that is *true*, collecting every
  # one that answered `null` on the way past.
  defp evaluate(flows, expr_ctx) do
    flows
    |> Enum.reduce_while({:ok, nil, []}, fn flow, {:ok, nil, nulls} = acc ->
      # An unconditioned flow is the default path, not a condition that failed to answer.
      #
      # Tested on `Map.get/2` rather than matched as `%{"condition" => nil}`, because the two
      # are not the same question: the pattern requires the key to be *present* and nil, and a
      # flow map that simply has no `"condition"` key falls through it. That flow then reaches
      # `evaluate_condition(nil, _)`, which answers `{:ok, nil}` -- so an ordinary unconditioned
      # sequence flow was being reported as a null condition and, with `fallback:
      # :single_unconditioned`, not selected at all. The compiler happens to write
      # `"condition" => nil` explicitly today, which is exactly why this would have sat here
      # undetected until something built a flow map by hand.
      case Map.get(flow, "condition") do
        nil ->
          {:cont, acc}

        condition ->
          case AshBpmn.Feel.evaluate_condition(condition, expr_ctx) do
            {:ok, true} -> {:halt, {:ok, flow, nulls}}
            {:ok, false} -> {:cont, {:ok, nil, nulls}}
            {:ok, nil} -> {:cont, {:ok, nil, [flow | nulls]}}
            {:error, reason} -> {:halt, {:error, "flow #{flow["id"]}: #{reason}"}}
          end
      end
    end)
    |> case do
      {:ok, flow, nulls} -> {:ok, flow, Enum.reverse(nulls)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp default_flow(flows, node) do
    case node["default_flow"] do
      nil -> nil
      id -> Enum.find(flows, &(&1["id"] == id))
    end
  end

  # The continuation of an ordinary node: exactly one flow, carrying no condition. Deliberately
  # narrow -- two flows, or one with a condition that did not answer true, is a decision the
  # diagram failed to make, and the caller should say so rather than pick.
  defp fallback_flow([only], :single_unconditioned) do
    # Same `Map.get/2` reasoning as in `evaluate/2` above: an absent key and an explicit nil
    # both mean "no condition", and a pattern match would only catch the second.
    if is_nil(Map.get(only, "condition")), do: only
  end

  defp fallback_flow(_flows, _fallback), do: nil
end
