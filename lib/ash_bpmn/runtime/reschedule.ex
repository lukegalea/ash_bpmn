# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.Runtime.Reschedule do
  @moduledoc false

  # `AshBpmn.reschedule_timers/2` (DESIGN.md §11.3, "When the data changes later").
  #
  # An armed instant is a fact; nothing moves it by itself. This is the one call that does: it
  # re-evaluates every data-driven timer still armed for the live instances of a subject, under
  # each instance's lock, and moves the ones whose instant changed. It reads what is armed from
  # the timer ledger, because the ledger is the only place that says which timers are armed
  # and when they were armed; without it there is nothing to re-evaluate against.
  #
  # Every moment is resolved before anything is written, so a moment that cannot be resolved
  # leaves every timer of that instance as it was and the call returns the incident.

  require Ash.Query

  alias AshBpmn.Feel
  alias AshBpmn.Runtime.{BoundaryTimerWorker, CatchTimerWorker, DomainResolver, Oban}
  alias AshBpmn.Runtime.{Step, TimerLedger, TimerMoment, TimerWorker}
  alias AshBpmn.Scope

  @task_kinds [:remind, :escalate, :expire]

  @spec run(struct(), keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def run(subject, opts) do
    scope = %{Scope.from_record(subject, opts) | domain: domain(subject, opts)}
    resources = DomainResolver.resolve!(scope.domain)

    if resources.timer_job do
      subject
      |> instances(resources, scope)
      |> Enum.reduce_while({:ok, 0}, fn instance, {:ok, total} ->
        case reschedule_instance(resources, instance, scope) do
          {:ok, moved} -> {:cont, {:ok, total + moved}}
          {:error, _} = error -> {:halt, error}
        end
      end)
    else
      {:error, :timer_ledger_not_installed}
    end
  end

  # The subject is the host's record and usually lives in the host's own domain, not the one
  # holding the engine's resources. Its domain is used only when it is that one.
  defp domain(subject, opts), do: opts[:domain] || engine_domain(Map.get(subject, :__struct__))

  defp engine_domain(resource) when is_atom(resource) and not is_nil(resource) do
    domain = Ash.Resource.Info.domain(resource)

    case domain && AshBpmn.Resources.for_domain(domain) do
      {:ok, _} -> domain
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp engine_domain(_resource), do: nil

  defp instances(subject, resources, scope) do
    type = to_string(subject.__struct__)
    id = subject.id

    resources.instance
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(subject_type == ^type and subject_id == ^id and status == :running)
    |> Ash.read!(Scope.engine(scope))
  end

  defp reschedule_instance(resources, instance, scope) do
    resources
    |> Step.transaction(fn locked -> plan_and_apply(resources, locked, scope) end,
      lock: {instance.id, scope}
    )
    |> case do
      {:ok, {:ok, moved}} -> {:ok, moved}
      {:ok, {:error, _} = error} -> error
      {:error, :instance_gone} -> {:ok, 0}
      {:error, reason} -> {:error, reason}
    end
  end

  defp plan_and_apply(resources, instance, scope) do
    rows = armed_rows(resources, instance, scope)

    if rows == [] do
      {:ok, 0}
    else
      graph =
        AshBpmn.DefinitionLoader.load!(
          resources.definition,
          instance.definition_id,
          instance,
          scope
        ).graph

      now = DateTime.utc_now()

      rows
      |> Enum.map(&{&1, spec_for(graph, &1)})
      |> Enum.filter(fn {_row, spec} -> spec && TimerMoment.data_driven?(spec) end)
      |> reduce_ok(fn {row, spec} -> plan(resources, instance, graph, row, spec, now, scope) end)
      |> case do
        {:ok, plans} ->
          moves = Enum.reject(plans, &(&1 == :unchanged))
          Enum.each(moves, &apply_move(resources, &1, scope))
          record(resources, instance, moves, scope)
          {:ok, length(moves)}

        {:error, _} = error ->
          error
      end
    end
  end

  # Timers that have fired, or were cancelled, are not armed and are left alone.
  defp armed_rows(resources, instance, scope) do
    resources.timer_job
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(instance_id == ^instance.id and status == :scheduled)
    |> Ash.read!(Scope.engine(scope))
  end

  defp spec_for(graph, %{kind: kind} = row) when kind in @task_kinds do
    graph
    |> get_in(["nodes", row.node_id, "timers"])
    |> List.wrap()
    |> Enum.at(index_of(row) || -1)
  end

  defp spec_for(graph, %{kind: kind} = row) when kind in [:catch, :boundary],
    do: get_in(graph, ["nodes", row.node_id, "catch"])

  defp spec_for(_graph, _row), do: nil

  # Rows armed since §11 carry the index; the key carries it for any that do not.
  defp index_of(%{data: %{"index" => index}}) when is_integer(index), do: index

  defp index_of(%{data: %{"key" => key}}) when is_binary(key) do
    case key |> String.split("/") |> Enum.at(2) |> Integer.parse() do
      {index, ""} -> index
      _ -> nil
    end
  end

  defp index_of(_row), do: nil

  # ── planning: pure but for the reads ─────────────────────────────────────

  defp plan(resources, instance, graph, row, spec, now, scope) do
    token = row.token_id && read_one(resources.token, row.token_id, scope)
    task = row.task_id && read_one(resources.human_task, row.task_id, scope)
    load_node = if row.kind == :boundary, do: row.data["attached_to"], else: row.node_id

    ctx =
      %{
        "subject" =>
          Feel.to_feel_value(
            AshBpmn.Subject.load(
              instance,
              scope,
              get_in(graph, ["nodes", load_node, "load"]) || []
            )
          ),
        "routing" => Feel.to_feel_value((token && token.routing) || %{})
      }
      |> put_task(task)

    # A duration counts from when the timer was first armed, and so does a cycle with no start.
    # Not from this row's `inserted_at`: a row is rewritten by every reschedule and every
    # repetition, and counting from the last write would move the timer later on every call,
    # with the data unchanged.
    case TimerMoment.resolve(spec, ctx, TimerLedger.armed_at(row)) do
      {:ok, resolved} ->
        {:ok, move(row, spec, resolved, now, %{graph: graph, task: task, token: token})}

      {:error, reason} ->
        {:error,
         {:timer_unresolved,
          %{
            "node" => row.node_id,
            "timer" => index_of(row) || row.node_id,
            "reason" => reason,
            "expression" => TimerMoment.expression_text(spec)
          }}}
    end
  end

  defp put_task(ctx, nil), do: ctx

  defp put_task(ctx, task) do
    Map.put(ctx, "task", %{
      "inserted_at" => task.inserted_at,
      "due_at" => Map.get(task, :due_at),
      "follow_up_at" => Map.get(task, :follow_up_at)
    })
  end

  defp move(row, spec, %{cycle: cycle}, now, env) do
    next = TimerMoment.next_repetition(cycle, row.data["repetition"] || 1, now)

    cond do
      is_nil(next.due_at) ->
        %{row: row, spec: spec, env: env, due_at: nil, skip: next.missed, cycle: cycle}

      DateTime.compare(next.due_at, row.due_at) == :eq ->
        :unchanged

      true ->
        %{
          row: row,
          spec: spec,
          env: env,
          due_at: next.due_at,
          repetition: next.repetition,
          missed: next.missed,
          cycle: cycle,
          skip: false
        }
    end
  end

  defp move(row, spec, %{due_at: due_at}, now, env) do
    late = DateTime.compare(due_at, now) == :lt

    cond do
      DateTime.compare(due_at, row.due_at) == :eq ->
        :unchanged

      late and spec["if_past"] == "skip" ->
        %{row: row, spec: spec, env: env, due_at: due_at, skip: 1}

      true ->
        %{row: row, spec: spec, env: env, due_at: due_at, late: late, skip: false}
    end
  end

  # ── applying ─────────────────────────────────────────────────────────────

  defp apply_move(resources, %{row: row} = move, scope) do
    if row.oban_job_id, do: Oban.cancel_job(row.oban_job_id)

    resources.timer_job.record_cancelled(
      row,
      :rescheduled,
      Scope.engine(scope)
    )

    case move do
      %{skip: count} when is_integer(count) -> skip(resources, move, count, scope)
      _ -> arm(resources, move, scope)
    end
  end

  defp skip(resources, %{row: row} = move, count, scope) do
    due_at = move.due_at || last_due_at(move)

    new_row =
      TimerLedger.row(resources, scope, %{
        instance_id: row.instance_id,
        token_id: row.token_id,
        task_id: row.task_id,
        node_id: row.node_id,
        kind: row.kind,
        due_at: due_at,
        data: Map.put(row.data, "armed_at", DateTime.to_iso8601(TimerLedger.armed_at(row)))
      })

    new_row && resources.timer_job.record_cancelled(new_row, :past, Scope.engine(scope))

    TimerLedger.skipped!(
      resources,
      scope,
      event_attrs(row),
      Map.merge(row.data, %{"kind" => kind_name(row.kind)}),
      count,
      due_at
    )
  end

  defp last_due_at(%{cycle: %{"count" => count, "seconds" => seconds, "anchor" => anchor}}) do
    {:ok, anchor, _} = DateTime.from_iso8601(anchor)
    DateTime.add(anchor, count * seconds)
  end

  defp arm(resources, %{row: row} = move, scope) do
    repetition = Map.get(move, :repetition, row.data["repetition"] || 1)
    {worker, args, meta} = job(row, move, repetition)

    if Map.get(move, :missed, 0) > 0 do
      TimerLedger.skipped!(
        resources,
        scope,
        event_attrs(row),
        Map.merge(args, %{"kind" => kind_name(row.kind)}),
        move.missed,
        nil
      )
    end

    new_row =
      TimerLedger.row(resources, scope, %{
        instance_id: row.instance_id,
        token_id: row.token_id,
        task_id: row.task_id,
        node_id: row.node_id,
        kind: row.kind,
        due_at: move.due_at,
        data: TimerLedger.data(args)
      })

    args = Map.put(args, "timer_job_id", new_row.id)

    opts = [scheduled_at: move.due_at] ++ if(meta, do: [meta: Oban.timer_meta(meta)], else: [])
    {:ok, job} = Oban.insert(worker, Scope.to_job_args(scope, args), opts)
    resources.timer_job.attach_job!(new_row, job.id, Scope.engine(scope))

    if move.env.task do
      task = read_one(resources.human_task, move.env.task.id, scope)

      ids =
        (task.timer_job_ids || [])
        |> List.delete(row.oban_job_id)
        |> Kernel.++([job.id])

      resources.human_task.attach_timers!(task, ids, Scope.engine(scope))
    end
  end

  # The job a moved timer is re-armed as: the same worker, the same key, a new instant.
  defp job(%{kind: kind} = row, move, repetition) when kind in @task_kinds do
    key = TimerMoment.key(row.task_id, row.node_id, index_of(row), repetition)

    args =
      %{
        "task_id" => row.task_id,
        "kind" => kind_name(kind),
        "index" => index_of(row),
        "repetition" => repetition,
        "key" => key
      }
      |> put_present("signal", move.spec["signal"])
      |> put_present("until", move.spec["until"])
      |> common(move)

    meta =
      %{task_id: row.task_id, kind: "task"}
      |> then(&if(move.spec["until"], do: Map.put(&1, :until, move.spec["until"]), else: &1))
      |> then(&if(Map.has_key?(move, :cycle), do: Map.put(&1, :key, key), else: &1))

    {TimerWorker, args, meta}
  end

  defp job(%{kind: :catch} = row, move, repetition) do
    args =
      %{
        "instance_id" => row.instance_id,
        "token_id" => row.token_id,
        "node_id" => row.node_id,
        "key" => TimerMoment.key(row.token_id, row.node_id, 0, repetition),
        "repetition" => repetition
      }
      |> common(move)

    {CatchTimerWorker, args, nil}
  end

  defp job(%{kind: :boundary} = row, move, repetition) do
    attached = row.data["attached_to"]
    key = TimerMoment.key(row.token_id, attached, row.node_id, repetition)

    args =
      %{
        "instance_id" => row.instance_id,
        "token_id" => row.token_id,
        "boundary_id" => row.node_id,
        "attached_to" => attached,
        "interrupting" => get_in(move.env.graph, ["nodes", row.node_id, "interrupting"]) != false,
        "repetition" => repetition,
        "key" => key
      }
      |> common(move)

    {BoundaryTimerWorker, args, %{token_id: row.token_id, kind: "boundary", key: key}}
  end

  defp common(args, move) do
    args
    |> Map.put("armed_at", DateTime.to_iso8601(TimerLedger.armed_at(move.row)))
    |> Map.put("due_at", DateTime.to_iso8601(move.due_at))
    |> then(&if(Map.get(move, :late), do: Map.put(&1, "late", true), else: &1))
    |> then(&if(move[:cycle], do: Map.put(&1, "cycle", move.cycle), else: &1))
  end

  defp record(_resources, _instance, [], _scope), do: :ok

  defp record(resources, instance, moves, scope) do
    resources.process_event.create!(
      %{
        instance_id: instance.id,
        kind: :timers_rescheduled,
        data: %{
          "count" => length(moves),
          "timers" =>
            Enum.map(moves, fn %{row: row} = move ->
              %{
                "key" => row.data["key"],
                "node" => row.node_id,
                "from" => DateTime.to_iso8601(row.due_at),
                "to" => move.due_at && DateTime.to_iso8601(move.due_at),
                "skipped" => is_integer(move.skip)
              }
            end)
        }
      },
      Scope.engine(scope)
    )
  end

  defp event_attrs(row) do
    %{
      instance_id: row.instance_id,
      token_id: row.token_id,
      node_id: row.node_id,
      task_id: row.task_id
    }
  end

  defp kind_name(:boundary), do: "boundary"
  defp kind_name(:catch), do: "catch"
  defp kind_name(kind), do: Atom.to_string(kind)

  defp read_one(resource, id, scope) do
    resource
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^id)
    |> Ash.read_one!(Scope.engine(scope))
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp reduce_ok(list, fun) do
    list
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end
end
