# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.Compiler.Timer do
  @moduledoc false

  # The compiler's half of DESIGN.md §11.3: what a timer's moment may be written as, and the
  # shape it is stored in.
  #
  # Two vocabularies reach here. `ash:timer` on a user task's `ash:taskConfig`, and BPMN's
  # `timerEventDefinition` on an intermediate catch event or a boundary event. Both end in the
  # same `moment` map, which the runtime (`AshBpmn.Runtime.TimerMoment`) turns into one instant
  # when the timer is armed.
  #
  # A definition compiled before §11 carries `minutes` on a task timer and `seconds` on a catch;
  # those snapshots are immutable and still running. So a timer written in the old forms keeps
  # exactly the old shape here -- no `moment`, no `index` -- and a republished diagram that
  # changed nothing compiles to the graph it compiled to before. `AshBpmn.Diff` and the
  # migration classifier compare graphs, and a format change would otherwise show up to them as
  # a change to every timer in every diagram.

  alias AshBpmn.Compiler.Errors
  alias AshBpmn.Compiler.Xml

  @kinds ~w(remind escalate expire)
  @unit_minutes %{"minutes" => 1, "hours" => 60, "days" => 1440}
  @moment_attrs ~w(minutes hours days duration date cycle)
  @known_attrs ~w(kind minutes hours days duration date cycle signal ifPast until)
  @if_past ~w(fire skip)
  @until ~w(completed claimed)

  @doc false
  # Every attribute an `ash:timer` may carry. The designer's moddle descriptor must declare each
  # one, or bpmn-js drops it on save (pinned by `AshBpmn.DesignerModdleTest`).
  @spec known_attributes() :: [String.t()]
  def known_attributes, do: @known_attrs

  @doc false
  @spec ash_timer(tuple(), String.t(), non_neg_integer()) :: {:ok, map()} | {:error, map()}
  def ash_timer(el, node_id, index) do
    attrs = Map.new(Xml.element_attrs(el))
    kind = attrs["kind"]
    where = "ash:timer #{index + 1} on userTask '#{node_id}'"

    with :ok <- known_attrs(node_id, where, attrs),
         :ok <- check_kind(node_id, where, kind),
         {:ok, moment_attr} <- single_moment(node_id, where, attrs),
         {:ok, if_past} <- one_of(node_id, where, "ifPast", attrs["ifPast"], @if_past),
         {:ok, until} <- one_of(node_id, where, "until", attrs["until"], @until),
         :ok <- expire_rules(node_id, where, kind, if_past, until),
         :ok <- signal_rules(node_id, where, kind, attrs["signal"]),
         {:ok, shape} <- ash_moment(node_id, where, kind, moment_attr) do
      {:ok,
       %{"kind" => kind}
       |> Map.merge(shape)
       |> put_if("signal", attrs["signal"])
       |> put_if("if_past", if(if_past == "skip", do: "skip"))
       |> put_if("until", if(until == "claimed", do: "claimed"))}
    end
  end

  # A timer event definition's moment, for an intermediate catch event or a boundary event.
  #
  # `context` is `:catch` or `{:boundary, interrupting?}`. It decides where a cycle is allowed,
  # which is nowhere yet.
  @doc false
  @spec event_definition(String.t(), tuple(), :catch | {:boundary, boolean()}) ::
          {:ok, map()} | {:error, map()}
  def event_definition(id, definition, _context) do
    children =
      definition
      |> Xml.get_element_children()
      |> Enum.map(&{Xml.normalize_name(Xml.local_name(&1)), &1})
      |> Enum.filter(fn {name, _} -> name in ~w(timeDuration timeDate timeCycle) end)

    case children do
      [] ->
        {:error,
         Errors.error(
           id,
           "timer '#{id}' has no timeDuration or timeDate; a timer needs a moment to fire at"
         )}

      [_, _ | _] ->
        names = Enum.map_join(children, ", ", &elem(&1, 0))

        {:error,
         Errors.error(
           id,
           "timer '#{id}' declares #{names}; BPMN makes them mutually exclusive, so a timer " <>
             "takes exactly one"
         )}

      [{"timeCycle", _}] ->
        {:error,
         Errors.error(
           id,
           "timer '#{id}' uses 'timeCycle', which is not supported; use timeDuration " <>
             "(an ISO 8601 duration such as PT4H or P2D) or a timeDate expression"
         )}

      [{name, element}] ->
        source = element |> Xml.element_text() |> to_string() |> String.trim()
        event_moment(id, name, source)
    end
  end

  # ── ash:timer ────────────────────────────────────────────────────────────

  defp known_attrs(node_id, where, attrs) do
    case Enum.reject(Map.keys(attrs), &(&1 in @known_attrs)) do
      [] ->
        :ok

      unknown ->
        {:error,
         Errors.error(
           node_id,
           "#{where} has unknown attribute(s) #{Enum.join(unknown, ", ")}. Known: " <>
             Enum.join(@known_attrs, ", ")
         )}
    end
  end

  defp check_kind(node_id, where, nil),
    do:
      {:error,
       Errors.error(node_id, "#{where} has no kind; it must be one of remind, escalate, expire")}

  defp check_kind(_node_id, _where, kind) when kind in @kinds, do: :ok

  defp check_kind(node_id, where, kind),
    do:
      {:error,
       Errors.error(
         node_id,
         "#{where} has kind '#{kind}', which is not one of remind, escalate, expire"
       )}

  defp single_moment(node_id, where, attrs) do
    case Enum.filter(@moment_attrs, &Map.has_key?(attrs, &1)) do
      [name] ->
        {:ok, {name, attrs[name]}}

      [] ->
        {:error,
         Errors.error(
           node_id,
           "#{where} has no moment; give it one of minutes, hours, days, duration or date"
         )}

      names ->
        {:error,
         Errors.error(
           node_id,
           "#{where} has more than one moment (#{Enum.join(names, ", ")}); a timer fires at " <>
             "one moment, so give it exactly one"
         )}
    end
  end

  defp one_of(_node_id, _where, _attr, nil, [default | _]), do: {:ok, default}

  defp one_of(node_id, where, attr, value, allowed) do
    if value in allowed do
      {:ok, value}
    else
      {:error,
       Errors.error(
         node_id,
         "#{where} has #{attr}=\"#{value}\"; it must be one of #{Enum.join(allowed, ", ")}"
       )}
    end
  end

  # An expiry is an outcome: it routes the graph and closes the task. Skipping one leaves a task
  # open past its own deadline with nobody told, and ending one at a claim leaves a claimed task
  # with no completion deadline at all.
  defp expire_rules(node_id, where, "expire", "skip", _until),
    do:
      {:error,
       Errors.error(
         node_id,
         ~s(#{where} is an expire timer with ifPast="skip". An expiry is an outcome; skipping ) <>
           "it would leave the task open past its own deadline with nobody told"
       )}

  defp expire_rules(node_id, where, "expire", _if_past, "claimed"),
    do:
      {:error,
       Errors.error(
         node_id,
         ~s(#{where} is an expire timer with until="claimed". An expiry is the task's ) <>
           "completion deadline; ending it at a claim would leave the claimed task with none"
       )}

  defp expire_rules(_node_id, _where, _kind, _if_past, _until), do: :ok

  defp signal_rules(_node_id, _where, _kind, nil), do: :ok
  defp signal_rules(_node_id, _where, "escalate", _signal), do: :ok

  defp signal_rules(node_id, where, kind, _signal),
    do:
      {:error,
       Errors.error(
         node_id,
         "#{where} is a #{kind} timer with a signal; only an escalate timer throws a signal"
       )}

  # minutes / hours / days: the original vocabulary, stored exactly as before (see moduledoc).
  defp ash_moment(node_id, where, _kind, {unit, raw}) when is_map_key(@unit_minutes, unit) do
    case Integer.parse(String.trim(raw)) do
      {n, ""} when n > 0 ->
        {:ok, %{"minutes" => n * Map.fetch!(@unit_minutes, unit)}}

      _ ->
        {:error,
         Errors.error(
           node_id,
           ~s(#{where} has #{unit}="#{raw}"; it must be a whole number greater than zero)
         )}
    end
  end

  defp ash_moment(node_id, where, _kind, {"duration", raw}) do
    case duration_moment(raw) do
      {:ok, moment} ->
        {:ok, Map.merge(%{"moment" => moment}, legacy_minutes(moment))}

      {:error, reason} ->
        {:error, Errors.error(node_id, ~s(#{where} has duration="#{raw}": #{reason}))}
    end
  end

  defp ash_moment(node_id, where, _kind, {"date", raw}) do
    case date_moment(raw) do
      {:ok, moment} ->
        {:ok, %{"moment" => moment}}

      {:error, reason} ->
        {:error, Errors.error(node_id, ~s(#{where} has date="#{raw}": #{reason}))}
    end
  end

  defp ash_moment(node_id, where, _kind, {"cycle", _raw}) do
    {:error,
     Errors.error(
       node_id,
       "#{where} has a cycle, which is not supported yet; use duration, date, minutes, hours " <>
         "or days"
     )}
  end

  # Kept beside the moment when a literal is a whole number of minutes, so the snapshot still
  # arms on an engine that predates `moment`.
  defp legacy_minutes(%{"seconds" => s}) when rem(s, 60) == 0, do: %{"minutes" => div(s, 60)}
  defp legacy_minutes(_moment), do: %{}

  # ── timerEventDefinition ────────────────────────────────────────────────

  defp event_moment(id, "timeDuration", source) do
    cond do
      source == "" ->
        {:error,
         Errors.error(
           id,
           "timer '#{id}' has an empty timeDuration; an ISO 8601 duration is required"
         )}

      expression?(source) ->
        case compile_expression(source) do
          {:ok, expr} ->
            {:ok,
             %{
               "catch" => %{
                 "kind" => "timer",
                 "duration" => source,
                 "moment" => %{"form" => "duration", "expr" => expr}
               }
             }}

          {:error, reason} ->
            {:error,
             Errors.error(id, "timer '#{id}' has an invalid timeDuration expression: #{reason}")}
        end

      true ->
        # The literal keeps the shape it always had: `seconds` is what an engine that predates
        # `moment` schedules with, and `duration` is what the modeller typed.
        case parse_duration(source) do
          {:ok, seconds} ->
            {:ok, %{"catch" => %{"kind" => "timer", "duration" => source, "seconds" => seconds}}}

          {:error, reason} ->
            {:error,
             Errors.error(id, "timer '#{id}' has an invalid duration '#{source}': #{reason}")}
        end
    end
  end

  defp event_moment(id, "timeDate", source) do
    case date_moment(source) do
      {:ok, moment} ->
        {:ok, %{"catch" => %{"kind" => "timer", "date" => source, "moment" => moment}}}

      {:error, reason} ->
        {:error, Errors.error(id, "timer '#{id}' has timeDate '#{source}': #{reason}")}
    end
  end

  # ── moments ─────────────────────────────────────────────────────────────

  defp duration_moment(raw) do
    source = String.trim(raw)

    if expression?(source) do
      with {:ok, expr} <- compile_expression(source) do
        {:ok, %{"form" => "duration", "expr" => expr}}
      end
    else
      with {:ok, seconds} <- parse_duration(source) do
        {:ok, %{"form" => "duration", "literal" => source, "seconds" => seconds}}
      end
    end
  end

  # A literal date is refused, for the reason the refusal has always given: a date typed into a
  # diagram published months before the token arrives is a deadline that may already be gone.
  # An expression is a date computed from the case in front of the engine.
  defp date_moment(raw) do
    source = String.trim(raw)

    cond do
      source == "" ->
        {:error, "it is empty"}

      expression?(source) ->
        with {:ok, expr} <- compile_expression(source) do
          {:ok, %{"form" => "date", "expr" => expr}}
        end

      true ->
        {:error,
         "a literal date is not supported, because a date typed into a diagram may be gone " <>
           "before a token arrives; write it as an expression computed from the case, such as " <>
           ~s(= subject.notice_at)}
    end
  end

  defp expression?(source), do: String.starts_with?(source, "=")

  defp compile_expression("=" <> body) do
    case String.trim(body) do
      "" -> {:error, "the expression after '=' is empty"}
      text -> AshBpmn.Feel.compile(text)
    end
  end

  @doc false
  # Months and years are refused rather than approximated. ISO 8601 allows them, but their
  # length depends on when you start counting, and a process that fires "in one month" at a
  # different instant depending on the day it parked is not a thing to hand an auditor. A
  # modeller who wants a month writes P30D and means it, or writes the calendar arithmetic as a
  # date expression, where FEEL defines it and the result is recorded as an instant.
  @spec parse_duration(String.t()) :: {:ok, pos_integer()} | {:error, String.t()}
  def parse_duration(source) do
    case Duration.from_iso8601(source) do
      {:ok, %Duration{month: m, year: y}} when m != 0 or y != 0 ->
        {:error, "months and years are not supported because their length is not fixed; use days"}

      {:ok, duration} ->
        seconds =
          duration.week * 604_800 + duration.day * 86_400 + duration.hour * 3600 +
            duration.minute * 60 + duration.second

        if seconds > 0 do
          {:ok, seconds}
        else
          {:error, "a timer must wait for a positive amount of time"}
        end

      {:error, reason} ->
        {:error, to_string(reason)}
    end
  end

  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)
end
