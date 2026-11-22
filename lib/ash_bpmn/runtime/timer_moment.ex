# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.Runtime.TimerMoment do
  @moduledoc false

  # The runtime's half of DESIGN.md §11.3: a timer's moment, resolved to one instant when the
  # timer is armed. From then on the instant is a fact recorded in the ledger and in Oban's
  # `scheduled_at`, not a formula anyone re-evaluates.
  #
  # Pure: it reads the compiled spec and an expression context and returns an instant or the
  # reason there is none. Everything that writes (the incident, the skip, the ledger) is the
  # caller's.
  #
  # Missing or ill-typed data is never a moment. An expression that returns FEEL `null`, a
  # `date` with no time, a date-time with no offset, a duration of zero or less, or a
  # years-and-months duration where a duration is required is an `{:error, reason}`, and the
  # caller turns it into a timer incident. Nothing parks without its deadline.

  alias Boxic.FEEL.DateTime, as: FeelDateTime
  alias Boxic.FEEL.Duration, as: FeelDuration

  @type resolved :: %{
          required(:due_at) => DateTime.t() | nil,
          required(:late) => boolean(),
          optional(:cycle) => map(),
          optional(:repetition) => pos_integer(),
          optional(:missed) => non_neg_integer()
        }

  @doc """
  Resolves a compiled timer (an `ash:timer` map or a catch spec) to its instant.

  `now` is the arming instant. A moment already past is returned with `late: true`; whether to
  fire it at once or skip it is the caller's rule (`ifPast`).
  """
  @spec resolve(map(), map(), DateTime.t()) :: {:ok, resolved()} | {:error, String.t()}
  def resolve(%{"moment" => %{"form" => "cycle"} = moment}, expr_ctx, now) do
    with {:ok, cycle} <- cycle(moment, expr_ctx, now) do
      {:ok, Map.merge(%{late: false, cycle: cycle}, next_repetition(cycle, 1, now))}
    end
  end

  def resolve(spec, expr_ctx, now) do
    with {:ok, due_at} <- instant(spec, expr_ctx, now) do
      {:ok, %{due_at: due_at, late: DateTime.compare(due_at, now) == :lt}}
    end
  end

  @doc """
  The next repetition of a cycle at or after `now`, counting from repetition `from`.

  `cycle` is `%{"count", "seconds", "anchor"}`, where repetition `k` is due at
  `anchor + k * seconds`. Repetitions already past are missed, not fired: a cycle whose start
  is in the past, or a firing that ran late, skips them and arms the next one still ahead, and
  `missed` says how many. When none is left, `due_at` is nil, every repetition from `from` on
  is missed, and `last_due_at` is when the last of them was due.
  """
  @spec next_repetition(map(), pos_integer(), DateTime.t()) :: %{
          required(:due_at) => DateTime.t() | nil,
          required(:repetition) => pos_integer(),
          required(:missed) => non_neg_integer(),
          optional(:last_due_at) => DateTime.t()
        }
  def next_repetition(%{"count" => count, "seconds" => seconds, "anchor" => anchor}, from, now) do
    {:ok, anchor, _} = DateTime.from_iso8601(anchor)
    elapsed = DateTime.diff(now, anchor, :microsecond)

    # The first k with anchor + k * seconds >= now.
    first_ahead = max(from, ceil_div(elapsed, seconds * 1_000_000))

    if first_ahead > count do
      %{
        due_at: nil,
        repetition: count,
        missed: max(count - from + 1, 0),
        last_due_at: DateTime.add(anchor, count * seconds)
      }
    else
      %{
        due_at: DateTime.add(anchor, first_ahead * seconds),
        repetition: first_ahead,
        missed: first_ahead - from
      }
    end
  end

  defp ceil_div(a, b) when a <= 0, do: div(a, b)
  defp ceil_div(a, b), do: div(a + b - 1, b)

  # A cycle with no start counts from the arming instant (`R3/PT1H` fires one, two and three
  # hours after it is armed); a cycle with a start fires its first repetition at the start.
  defp cycle(%{"count" => count, "seconds" => seconds}, _ctx, now),
    do: {:ok, cycle_map(count, seconds, now)}

  defp cycle(%{"expr" => expr}, ctx, now) do
    with {:ok, value} <- evaluate(expr, ctx),
         {:ok, text} <- cycle_text(value),
         {:ok, parsed} <- parse_cycle(text) do
      anchor = if parsed.start, do: DateTime.add(parsed.start, -parsed.seconds), else: now
      {:ok, cycle_map(parsed.count, parsed.seconds, anchor)}
    end
  end

  defp cycle_text(value) when is_binary(value), do: {:ok, value}

  defp cycle_text(other),
    do:
      {:error,
       "the expression returned #{describe(other)}, not a cycle such as \"R3/PT1H\" or " <>
         "\"R3/2026-01-01T09:00:00Z/P1D\""}

  defp parse_cycle(text) do
    case AshBpmn.Compiler.Timer.parse_cycle(text) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, reason} -> {:error, "the expression returned the cycle '#{text}': #{reason}"}
    end
  end

  defp cycle_map(count, seconds, anchor),
    do: %{"count" => count, "seconds" => seconds, "anchor" => DateTime.to_iso8601(anchor)}

  @doc "The args a repeating timer carries: its cycle and the repetitions it skipped."
  @spec cycle_args(map(), resolved()) :: map()
  def cycle_args(args, %{cycle: cycle} = resolved) do
    args
    |> Map.put("cycle", cycle)
    |> Map.put("repetition", resolved.repetition)
    |> then(&if(resolved.missed > 0, do: Map.put(&1, "missed", resolved.missed), else: &1))
  end

  def cycle_args(args, _resolved), do: args

  @doc "Whether the timer's moment is an expression (and so moves under `reschedule_timers/2`)."
  @spec data_driven?(map()) :: boolean()
  def data_driven?(%{"moment" => %{"expr" => _}}), do: true
  def data_driven?(_spec), do: false

  @doc "The expression text of a data-driven timer, for an incident's event; nil for a literal."
  @spec expression_text(map()) :: String.t() | nil
  def expression_text(%{"moment" => %{"expr" => %{"text" => text}}}), do: "=" <> text
  def expression_text(_spec), do: nil

  @doc """
  The stable key of one firing: `<task or token id>/<node id>/<timer index>/<repetition>`.

  The same on every retry of a firing and different for every repetition, so it is the
  idempotency key a host deduplicates on. It does not depend on the timer ledger.
  """
  @spec key(term(), String.t(), term(), pos_integer()) :: String.t()
  def key(owner_id, node_id, index, repetition),
    do: "#{owner_id}/#{node_id}/#{index}/#{repetition}"

  # ── instants ─────────────────────────────────────────────────────────────

  # Snapshots compiled before §11: a task timer carries `minutes`, a catch carries `seconds`.
  defp instant(%{"moment" => moment}, expr_ctx, now), do: moment_instant(moment, expr_ctx, now)
  defp instant(%{"seconds" => s}, _ctx, now) when is_integer(s), do: {:ok, DateTime.add(now, s)}

  defp instant(%{"minutes" => m}, _ctx, now) when is_integer(m),
    do: {:ok, DateTime.add(now, m, :minute)}

  defp instant(_spec, _ctx, _now), do: {:error, "the timer has no moment"}

  defp moment_instant(%{"form" => "duration", "seconds" => s}, _ctx, now) when is_integer(s),
    do: {:ok, DateTime.add(now, s)}

  defp moment_instant(%{"form" => "duration", "expr" => expr}, ctx, now) do
    with {:ok, value} <- evaluate(expr, ctx),
         {:ok, seconds} <- duration_seconds(value) do
      {:ok, DateTime.add(now, seconds)}
    end
  end

  defp moment_instant(%{"form" => "date", "expr" => expr}, ctx, _now) do
    with {:ok, value} <- evaluate(expr, ctx) do
      to_instant(value)
    end
  end

  defp moment_instant(moment, _ctx, _now),
    do: {:error, "the timer's moment #{inspect(moment)} is not one this engine knows"}

  defp evaluate(expr, ctx) do
    case AshBpmn.Feel.evaluate(expr, ctx) do
      {:ok, nil} ->
        {:error,
         "the expression returned null: a path it reads is missing, not declared in the " <>
           "node's ash:load, or of the wrong type"}

      {:ok, value} ->
        {:ok, value}

      {:error, reason} ->
        {:error, "the expression could not be evaluated: #{reason}"}
    end
  end

  @doc false
  @spec duration_seconds(term()) :: {:ok, pos_integer()} | {:error, String.t()}
  def duration_seconds(%FeelDuration{kind: :year_month}),
    do:
      {:error,
       "the expression returned a years-and-months duration, whose length is not fixed; " <>
         "a timer duration must be days and time, or the calendar arithmetic written as a date"}

  def duration_seconds(%FeelDuration{kind: :day_time, seconds: seconds}) do
    whole =
      case seconds do
        %Decimal{} = d -> d |> Decimal.round(0, :ceiling) |> Decimal.to_integer()
        n when is_integer(n) -> n
      end

    if whole > 0 do
      {:ok, whole}
    else
      {:error, "the expression returned a duration of zero or less"}
    end
  end

  def duration_seconds(other),
    do: {:error, "the expression returned #{describe(other)}, not a duration"}

  @doc false
  @spec to_instant(term()) :: {:ok, DateTime.t()} | {:error, String.t()}
  def to_instant(%DateTime{} = dt), do: {:ok, DateTime.shift_zone!(dt, "Etc/UTC")}

  def to_instant(%FeelDateTime{time: %{zone: :floating}}),
    do:
      {:error,
       "the expression returned a date-time with no offset, which names no instant; give it " <>
         "an offset or a zone"}

  def to_instant(%FeelDateTime{} = dt) do
    case FeelDateTime.instant_seconds(dt) do
      {:ok, seconds} ->
        micros =
          seconds |> Decimal.mult(1_000_000) |> Decimal.round(0, :floor) |> Decimal.to_integer()

        {:ok,
         DateTime.from_gregorian_seconds(
           div(micros, 1_000_000),
           {rem(micros, 1_000_000), 6}
         )}

      :error ->
        {:error, "the expression returned a date-time whose zone could not be resolved"}
    end
  end

  def to_instant(%NaiveDateTime{}),
    do:
      {:error,
       "the expression returned a date-time with no offset, which names no instant; give it " <>
         "an offset or a zone"}

  def to_instant(%Date{}),
    do:
      {:error,
       "the expression returned a date with no time; a timer fires at an instant, so return " <>
         "a date and time with an offset"}

  def to_instant(other),
    do: {:error, "the expression returned #{describe(other)}, not a date and time"}

  defp describe(%FeelDuration{}), do: "a duration"
  defp describe(%FeelDateTime{}), do: "a date and time"
  defp describe(%Date{}), do: "a date"
  defp describe(%DateTime{}), do: "a date and time"
  defp describe(value) when is_binary(value), do: "a string"
  defp describe(value) when is_boolean(value), do: "a boolean"
  defp describe(%Decimal{}), do: "a number"
  defp describe(value) when is_number(value), do: "a number"
  defp describe(value) when is_list(value), do: "a list"
  defp describe(value) when is_map(value), do: "a context"
  defp describe(_value), do: "a value of another type"
end
