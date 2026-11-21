# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.Moment do
  @moduledoc """
  A point in time a diagram declares: a task's due date or follow-up date (DESIGN.md §11.5).

  A moment is written in one of two forms. A value that begins with `=` is a FEEL
  expression; anything else is a literal ISO 8601 duration, counted from the instant the
  moment is resolved:

      <ash:schedule due="P30D"/>
      <ash:schedule due="= subject.received_at + duration(&quot;P30D&quot;)"/>

  `compile/1` runs at publish time, so a malformed moment is a compile error naming the node.
  `resolve/3` runs once, when the moment is armed (a task's schedule when the task is
  created), and turns it into one UTC instant. From then on the instant is a fact recorded on
  the row, not a formula re-read later.

  ## What a moment refuses

  A literal date is refused: a date typed into a diagram published months before anybody
  reaches it is a deadline that may already be gone. A date is an expression over the case in
  front of the engine.

  A duration literal is refused when it is zero or less, and when it names months or years,
  whose length depends on the day you start counting. Inside an expression, months and years
  are FEEL's calendar arithmetic and are allowed, because the result is recorded as an instant
  before anyone relies on it.

  An expression that answers `null`, a `date` with no time, a date-time with no offset, a
  duration, or anything else that is not a zoned date-time, cannot be resolved. `resolve/3`
  returns `{:error, reason}`, and the caller treats it as an incident rather than guessing a
  deadline: nothing is armed without its moment.
  """

  alias AshBpmn.Feel

  @typedoc "A compiled moment, as stored in a definition snapshot."
  @type compiled ::
          %{required(String.t()) => String.t() | pos_integer() | Feel.stored()}

  # Seconds from 0000-01-01 (the gregorian epoch `Boxic.FEEL.DateTime.instant_seconds/1`
  # counts from) to 1970-01-01.
  @unix_epoch_gregorian_seconds 62_167_219_200

  @doc """
  Compiles a moment's source text into the form stored in the snapshot.

  Returns `{:ok, %{"form" => "duration", "source" => s, "seconds" => n}}` for a duration
  literal, `{:ok, %{"form" => "expression", "source" => s, "feel" => stored}}` for a FEEL
  expression, or `{:error, reason}`.
  """
  @spec compile(String.t() | nil) :: {:ok, compiled()} | {:error, String.t()}
  def compile(nil), do: {:error, "is empty"}

  def compile(source) when is_binary(source) do
    case String.trim(source) do
      "" ->
        {:error, "is empty"}

      "=" <> expression ->
        case Feel.compile(expression) do
          {:ok, stored} ->
            {:ok, %{"form" => "expression", "source" => String.trim(source), "feel" => stored}}

          {:error, reason} ->
            {:error, "is not a valid FEEL expression: #{reason}"}
        end

      literal ->
        case parse_duration(literal) do
          {:ok, seconds} ->
            {:ok, %{"form" => "duration", "source" => literal, "seconds" => seconds}}

          {:error, :not_a_duration} ->
            {:error,
             "'#{literal}' is neither an ISO 8601 duration (such as P30D or PT4H) nor a FEEL " <>
               "expression (which begins with '='); a literal date is not accepted, because " <>
               "it may be gone before the task exists"}

          {:error, reason} ->
            {:error, "'#{literal}' #{reason}"}
        end
    end
  end

  @doc """
  Parses an ISO 8601 duration literal into whole seconds.

  Refuses months and years (their length is not fixed) and durations of zero or less.
  """
  @spec parse_duration(String.t()) ::
          {:ok, pos_integer()} | {:error, :not_a_duration | String.t()}
  def parse_duration(literal) when is_binary(literal) do
    case Duration.from_iso8601(literal) do
      {:ok, %Duration{month: m, year: y}} when m != 0 or y != 0 ->
        {:error,
         "names months or years, whose length is not fixed; use days, or a FEEL expression " <>
           "for calendar arithmetic"}

      {:ok, duration} ->
        {microseconds, _precision} = duration.microsecond

        seconds =
          duration.week * 604_800 + duration.day * 86_400 + duration.hour * 3600 +
            duration.minute * 60 + duration.second + div(microseconds, 1_000_000)

        if seconds > 0, do: {:ok, seconds}, else: {:error, "must be longer than zero"}

      {:error, _reason} ->
        {:error, :not_a_duration}
    end
  end

  @doc """
  Resolves a compiled moment to one UTC instant.

  `from` is the instant a duration literal counts from (a task's creation). `context` is the
  FEEL context an expression reads, already converted with `AshBpmn.Feel.to_feel_value/1`.
  """
  @spec resolve(compiled(), DateTime.t(), map()) :: {:ok, DateTime.t()} | {:error, String.t()}
  def resolve(%{"form" => "duration", "seconds" => seconds}, %DateTime{} = from, _context)
      when is_integer(seconds) and seconds > 0 do
    {:ok, from |> DateTime.add(seconds, :second) |> to_utc()}
  end

  def resolve(%{"form" => "expression", "feel" => feel}, _from, context) when is_map(context) do
    case Feel.evaluate(feel, context) do
      {:ok, value} -> instant(value)
      {:error, reason} -> {:error, "could not be evaluated: #{reason}"}
    end
  end

  def resolve(other, _from, _context),
    do: {:error, "is not a compiled moment: #{inspect(other, limit: 5)}"}

  defp instant(nil),
    do: {:error, "returned null, so there is no instant to record"}

  defp instant(%DateTime{} = value), do: {:ok, to_utc(value)}

  defp instant(%Boxic.FEEL.DateTime{time: %{zone: :floating}}),
    do: {:error, "returned a date-time with no offset, which names no single instant"}

  defp instant(%Boxic.FEEL.DateTime{} = value) do
    case Boxic.FEEL.DateTime.instant_seconds(value) do
      {:ok, seconds} ->
        microseconds =
          seconds
          |> Decimal.sub(@unix_epoch_gregorian_seconds)
          |> Decimal.mult(1_000_000)
          |> Decimal.round(0, :floor)
          |> Decimal.to_integer()

        {:ok, DateTime.from_unix!(microseconds, :microsecond)}

      :error ->
        {:error, "returned a date-time whose zone could not be resolved to an offset"}
    end
  end

  defp instant(%Date{}),
    do: {:error, "returned a date with no time; return a date and time with an offset"}

  defp instant(%NaiveDateTime{}),
    do: {:error, "returned a date-time with no offset, which names no single instant"}

  defp instant(%Boxic.FEEL.Duration{}),
    do: {:error, "returned a duration where a date-time is required"}

  defp instant(other),
    do: {:error, "returned #{inspect(other, limit: 5)}, which is not a date-time"}

  defp to_utc(%DateTime{} = value) do
    value
    |> DateTime.to_unix(:microsecond)
    |> DateTime.from_unix!(:microsecond)
  end
end
