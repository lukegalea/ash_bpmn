# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn do
  @moduledoc """
  Public facade for the ash_bpmn runtime engine.

  Provides functions for starting process instances, completing tasks,
  claiming tasks, delegating, cancelling, querying, and retrying.
  """

  require Ash.Query

  alias AshBpmn.Config
  alias AshBpmn.Runtime.{AdvanceWorker, DomainResolver, Oban}

  # ── Instance lifecycle ───────────────────────────────────────────────────

  @doc """
  Starts a new process instance for the given process key.

  Options:
    * `:process` — process key (required)
    * `:subject` — the subject record (required)
    * `:actor` — the user starting the process
    * `:tenant` — organization/tenant id
  """
  @spec start_instance!(module(), keyword()) :: map()
  def start_instance!(domain, opts) do
    {:ok, instance} = start_instance(domain, opts)
    instance
  end

  @spec start_instance(module(), keyword()) :: {:ok, map()} | {:error, term()}
  def start_instance(domain, opts) do
    process_key = Keyword.fetch!(opts, :process)
    subject = Keyword.fetch!(opts, :subject)
    actor = Keyword.get(opts, :actor)
    _tenant = Keyword.get(opts, :tenant)

    {:ok, resources} = AshBpmn.Resources.for_domain(domain)

    # Get latest published definition
    definition_results = resources.definition.latest_published!(process_key)

    case definition_results do
      [] ->
        {:error, "no published definition found for process: #{process_key}"}

      [definition | _] ->
        # Create instance
        instance =
          resources.instance.create!(
            %{
              definition_id: definition.id,
              subject_type: subject.__struct__ |> to_string(),
              subject_id: subject.id,
              started_by_id: if(actor, do: actor.id, else: nil)
            },
            authorize?: false
          )

        # Reload instance to get fresh state
        instance =
          resources.instance
          |> Ash.Query.for_read(:read)
          |> Ash.Query.filter(id == ^instance.id)
          |> Ash.read_one!(authorize?: false)

        # Create initial token at the start node
        start_node = definition.graph["start"]

        token =
          resources.token.create!(
            %{
              instance_id: instance.id,
              node_id: start_node,
              status: :active
            },
            authorize?: false
          )

        # Record instance_started event
        resources.process_event.create!(
          %{
            instance_id: instance.id,
            kind: :instance_started,
            data: %{
              "process_key" => process_key,
              "definition_version" => definition.version
            }
          },
          authorize?: false
        )

        # Enqueue first advance
        Oban.insert(AdvanceWorker, %{
          "instance_id" => instance.id,
          "token_id" => token.id,
          "node_id" => start_node
        })

        # Reload instance to get fresh state
        fresh_instance =
          resources.instance
          |> Ash.Query.for_read(:read)
          |> Ash.Query.filter(id == ^instance.id)
          |> Ash.read_one!(authorize?: false)

        {:ok, fresh_instance}
    end
  rescue
    e -> {:error, e}
  end

  # ── Task operations ──────────────────────────────────────────────────────

  @doc """
  Completes a human task (process-bound or standalone).

  Options:
    * `:outcome` — required outcome atom
    * `:comment` — optional comment
    * `:actor` — required, the user completing the task
  """
  @spec complete_task!(map(), keyword()) :: map()
  def complete_task!(task, opts) do
    task |> complete_task(opts) |> unwrap!()
  end

  # The `{:ok, _} | {:error, _}` functions below rescue and return the exception
  # itself, so the bang variants can re-raise it and callers keep the original
  # error type — an `ArgumentError` from a candidacy check stays an
  # `ArgumentError` rather than becoming a `MatchError`.
  defp unwrap!({:ok, value}), do: value
  defp unwrap!({:error, exception}), do: raise(exception)

  @spec complete_task(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def complete_task(task, opts) do
    outcome = Keyword.fetch!(opts, :outcome)
    comment = Keyword.get(opts, :comment)
    actor = Keyword.fetch!(opts, :actor)

    resources = DomainResolver.resolve!()

    # Reload so we complete against current state, not a struct the caller may
    # have been holding since before the task's timers were attached.
    task = reload_task!(resources, task)

    # A task may be completed without an explicit claim; record the implicit
    # claim so the event log still shows who took it before deciding.
    task =
      if task.status == :open do
        {:ok, claimed} =
          resources.human_task.claim(
            task,
            %{assignee_type: :user, assignee_id: actor.id},
            authorize?: false
          )

        record_claim_event(resources, claimed, actor)
        claimed
      else
        task
      end

    completed =
      resources.human_task.complete!(
        task,
        %{outcome: outcome, comment: comment, decided_by_id: actor.id},
        authorize?: false
      )

    # Cancel timers
    Enum.each(completed.timer_job_ids || [], fn job_id ->
      AshBpmn.Runtime.Oban.cancel_job(job_id)
    end)

    record_task_event(resources, completed, :task_completed, %{
      "outcome" => outcome,
      "decided_by_id" => actor.id,
      "comment" => comment
    })

    # If this is a process task, advance the token
    if completed.token_id do
      advance_token_after_task(resources, completed, outcome, actor)
    end

    {:ok, completed}
  rescue
    e -> {:error, e}
  end

  @doc """
  Decides a standalone approval task.

  Identical to complete_task! but also fires the on_complete action ref
  for standalone approvals (where instance_id is nil).
  """
  @spec decide!(map(), keyword()) :: map()
  def decide!(task, opts) do
    task |> decide(opts) |> unwrap!()
  end

  @spec decide(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def decide(task, opts) do
    outcome = Keyword.fetch!(opts, :outcome)
    actor = Keyword.fetch!(opts, :actor)

    case complete_task(task, opts) do
      {:ok, completed} ->
        # Fire on_complete for standalone approvals
        if completed.instance_id == nil && completed.on_complete != nil &&
             completed.on_complete != %{} do
          action_ref = completed.on_complete[to_string(outcome)]

          if action_ref do
            invoker = Config.action_invoker!()

            # Load subject
            subject =
              if completed.subject_type && completed.subject_id do
                try do
                  # subject_type already includes "Elixir." prefix from to_string/1
                  mod = String.to_atom(completed.subject_type)

                  mod
                  |> Ash.Query.for_read(:read)
                  |> Ash.Query.filter(id == ^completed.subject_id)
                  |> Ash.read_one!(authorize?: false)
                rescue
                  _ -> nil
                end
              else
                nil
              end

            ctx = %{
              subject: subject,
              actor: actor,
              instance: nil,
              task: completed,
              assigns: %{"task" => %{"outcome" => outcome}}
            }

            invoker.invoke(action_ref, ctx)
          end
        end

        {:ok, completed}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Claims a human task, asserting the actor is a candidate.

  Raises if the actor's principal id is not in the TaskCandidate rows.
  """
  @spec claim_task!(map(), keyword()) :: map()
  def claim_task!(task, opts) do
    task |> claim_task(opts) |> unwrap!()
  end

  @spec claim_task(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def claim_task(task, opts) do
    actor = Keyword.fetch!(opts, :actor)
    resources = DomainResolver.resolve!()

    # Check candidacy
    candidates =
      resources.task_candidate
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(task_id == ^task.id)
      |> Ash.read!(authorize?: false)

    principal_ids = gather_principal_ids(actor)

    candidate_match =
      Enum.any?(candidates, fn c ->
        c.principal_type == :user && c.principal_id in principal_ids
      end)

    unless candidate_match do
      raise ArgumentError,
            "actor is not a candidate for task #{task.id}. " <>
              "Actor principal ids: #{inspect(principal_ids)}, " <>
              "Candidates: #{inspect(Enum.map(candidates, &{&1.principal_type, &1.principal_id}))}"
    end

    claimed =
      resources.human_task.claim!(
        reload_task!(resources, task),
        %{assignee_type: :user, assignee_id: actor.id},
        authorize?: false
      )

    record_claim_event(resources, claimed, actor)

    {:ok, claimed}
  rescue
    e -> {:error, e}
  end

  # Events are recorded for standalone approvals too — they have no instance,
  # but "who claimed, who decided" is exactly what the log is for.
  defp record_task_event(resources, task, kind, data) do
    resources.process_event.create!(
      %{
        instance_id: task.instance_id,
        token_id: task.token_id,
        node_id: task.node_id,
        task_id: task.id,
        kind: kind,
        data: data
      },
      authorize?: false
    )

    :ok
  end

  defp record_claim_event(resources, task, actor) do
    record_task_event(resources, task, :task_claimed, %{"assignee_id" => actor.id})
  end

  defp reload_task!(resources, task) do
    resources.human_task
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^task.id)
    |> Ash.read_one!(authorize?: false)
  end

  @doc "Delegates a claimed task to another principal."
  @spec delegate_task!(map(), keyword()) :: map()
  def delegate_task!(task, opts) do
    task |> delegate_task(opts) |> unwrap!()
  end

  @spec delegate_task(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def delegate_task(task, opts) do
    to_principal = Keyword.fetch!(opts, :to_principal)
    actor = Keyword.fetch!(opts, :actor)
    resources = DomainResolver.resolve!()

    # The action's RecordDelegatedFrom change captures the outgoing assignee as
    # `delegated_from_id` — the accountability trail delegation exists for.
    delegated =
      resources.human_task.delegate!(
        reload_task!(resources, task),
        to_principal.type,
        to_principal.id,
        authorize?: false
      )

    record_task_event(resources, delegated, :task_delegated, %{
      "from_id" => actor.id,
      "to_type" => to_principal.type,
      "to_id" => to_principal.id
    })

    {:ok, delegated}
  rescue
    e -> {:error, e}
  end

  # ── Instance operations ─────────────────────────────────────────────────

  @doc "Cancels a running instance."
  @spec cancel_instance!(map()) :: map()
  def cancel_instance!(instance) do
    {:ok, cancelled} = cancel_instance(instance)
    cancelled
  end

  @spec cancel_instance(map()) :: {:ok, map()} | {:error, term()}
  def cancel_instance(instance) do
    resources = DomainResolver.resolve!()

    # Kill all active/executing tokens
    active_tokens =
      resources.token
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(instance_id == ^instance.id)
      |> Ash.Query.filter(status in [:active, :executing])
      |> Ash.read!(authorize?: false)

    Enum.each(active_tokens, fn token ->
      resources.token.kill!(token, authorize?: false)
    end)

    # Cancel open tasks
    open_tasks =
      resources.human_task
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(instance_id == ^instance.id)
      |> Ash.Query.filter(status in [:open, :claimed])
      |> Ash.read!(authorize?: false)

    Enum.each(open_tasks, fn task ->
      Enum.each(task.timer_job_ids || [], &AshBpmn.Runtime.Oban.cancel_job/1)
      resources.human_task.cancel!(task, authorize?: false)
    end)

    cancelled = resources.instance.cancel!(instance, authorize?: false)

    resources.process_event.create!(
      %{
        instance_id: instance.id,
        kind: :instance_cancelled,
        data: %{}
      },
      authorize?: false
    )

    {:ok, cancelled}
  rescue
    e -> {:error, e}
  end

  @doc """
  Returns tasks where the given principal is a candidate.

  Opts: `:principal_ids` — list of UUIDs (required)
  """
  @spec my_tasks(module(), keyword()) :: [map()]
  def my_tasks(domain, opts) do
    principal_ids = Keyword.fetch!(opts, :principal_ids)

    {:ok, resources} = AshBpmn.Resources.for_domain(domain)

    tasks =
      resources.human_task
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(status in [:open, :claimed])
      |> Ash.read!(authorize?: false)

    # Filter to tasks where user is a candidate
    Enum.filter(tasks, fn task ->
      candidates =
        resources.task_candidate
        |> Ash.Query.for_read(:read)
        |> Ash.Query.filter(task_id == ^task.id)
        |> Ash.Query.filter(principal_type == :user)
        |> Ash.Query.filter(principal_id in ^principal_ids)
        |> Ash.read!(authorize?: false)

      candidates != []
    end)
  end

  @doc "Returns a full report of an instance (tokens, tasks, events)."
  @spec instance_report(map()) :: %{
          instance: map(),
          tokens: [map()],
          tasks: [map()],
          events: [map()]
        }
  def instance_report(instance) do
    resources = DomainResolver.resolve!()

    tokens =
      resources.token
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(instance_id == ^instance.id)
      |> Ash.read!(authorize?: false)

    tasks =
      resources.human_task
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(instance_id == ^instance.id)
      |> Ash.read!(authorize?: false)

    events =
      resources.process_event
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(instance_id == ^instance.id)
      |> Ash.Query.sort(recorded_at: :asc)
      |> Ash.read!(authorize?: false)

    %{
      instance: instance,
      tokens: tokens,
      tasks: tasks,
      events: events
    }
  end

  @doc "Retries a failed instance by reactivating dead tokens."
  @spec retry_instance!(map()) :: map()
  def retry_instance!(instance) do
    {:ok, retried} = retry_instance(instance)
    retried
  end

  @spec retry_instance(map()) :: {:ok, map()} | {:error, term()}
  def retry_instance(instance) do
    resources = DomainResolver.resolve!()

    dead_tokens =
      resources.token
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(instance_id == ^instance.id)
      |> Ash.Query.filter(status == :dead)
      |> Ash.read!(authorize?: false)

    Enum.each(dead_tokens, fn token ->
      reactivated = resources.token.reactivate!(token, authorize?: false)

      Oban.insert(AdvanceWorker, %{
        "instance_id" => instance.id,
        "token_id" => reactivated.id,
        "node_id" => reactivated.node_id
      })
    end)

    # Reload
    fresh =
      resources.instance
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(id == ^instance.id)
      |> Ash.read_one!(authorize?: false)

    {:ok, fresh}
  rescue
    e -> {:error, e}
  end

  # ── Private helpers ─────────────────────────────────────────────────────

  defp advance_token_after_task(resources, task, outcome, _actor) do
    token =
      resources.token
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(id == ^task.token_id)
      |> Ash.read_one!(authorize?: false)

    if token.status == :executing && task.instance_id do
      instance =
        resources.instance
        |> Ash.Query.for_read(:read)
        |> Ash.Query.filter(id == ^task.instance_id)
        |> Ash.read_one!(authorize?: false)

      definition =
        resources.definition
        |> Ash.Query.for_read(:read)
        |> Ash.Query.filter(id == ^instance.definition_id)
        |> Ash.read_one!(authorize?: false)

      graph = definition.graph

      # Find outgoing flows from the task's node
      outgoing =
        graph["flows"]
        |> Map.values()
        |> Enum.filter(fn flow -> flow["from"] == task.node_id end)

      # Determine which flow to follow based on outcome (for gateways after user tasks)
      case outgoing do
        [flow] ->
          follow_flow(resources, instance, token, graph, flow, outcome)

        flows when length(flows) > 1 ->
          # Multiple flows — check if this connects to a gateway
          # Use the first flow that has a matching condition or default
          node_config = graph["nodes"][task.node_id]
          default_flow = Enum.find(flows, fn f -> f["id"] == node_config["default_flow"] end)

          chosen =
            Enum.find(flows, fn flow ->
              cond = flow["condition"]

              if cond do
                {:ok, result} =
                  AshBpmn.Expr.eval(cond, %{
                    "task" => %{"outcome" => to_string(outcome)},
                    "subject" => nil
                  })

                result
              else
                false
              end
            end)

          target_flow = chosen || default_flow || List.first(flows)

          if target_flow do
            follow_flow(resources, instance, token, graph, target_flow, outcome)
          end

        _ ->
          :ok
      end
    end
  end

  defp follow_flow(resources, instance, token, graph, flow, outcome) do
    next_node_id = flow["to"]
    next_node = graph["nodes"][next_node_id]

    if next_node do
      # Check if this is a join — handle join semantics
      join_info = graph["joins"][next_node_id]

      if join_info do
        handle_join(resources, instance, token, graph, next_node_id, join_info, outcome)
      else
        # Consume current token via direct SQL (same status validation issue as in AdvanceWorker)
        consume_token_sql(token)

        new_token =
          resources.token.create!(
            %{
              instance_id: instance.id,
              node_id: next_node_id,
              status: :active
            },
            authorize?: false
          )

        Oban.insert(AshBpmn.Runtime.AdvanceWorker, %{
          "instance_id" => instance.id,
          "token_id" => new_token.id,
          "node_id" => next_node_id,
          "task_outcome" => outcome && to_string(outcome)
        })
      end
    end
  end

  defp handle_join(resources, instance, token, graph, join_node_id, join_info, _outcome) do
    # Consume this token via direct SQL (same status validation issue)
    consume_token_sql(token)

    # Count how many tokens have been consumed at this join node
    waits_for = join_info["waits_for"] || []

    _consumed_at_join =
      resources.token
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(instance_id == ^instance.id)
      |> Ash.Query.filter(node_id == ^join_node_id)
      |> Ash.Query.filter(status == :consumed)
      |> Ash.read!(authorize?: false)

    if length(waits_for) <= 1 do
      # Non-parallel join — always advance
      advance_through_join(resources, instance, token, graph, join_node_id)
    else
      # Parallel join — check if remaining sibling tokens exist.
      # If any sibling still has active/executing tokens, wait. Otherwise advance.
      incoming_nodes =
        graph["flows"]
        |> Map.values()
        |> Enum.filter(fn f -> f["to"] == join_node_id end)
        |> Enum.map(fn f -> f["from"] end)
        |> Enum.reject(fn from -> from == token.node_id end)

      has_active_siblings =
        Enum.any?(incoming_nodes, fn from_node ->
          resources.token
          |> Ash.Query.for_read(:read)
          |> Ash.Query.filter(instance_id == ^instance.id)
          |> Ash.Query.filter(node_id == ^from_node)
          |> Ash.Query.filter(status in [:active, :executing])
          |> Ash.read_one!(authorize?: false)
        end)

      if has_active_siblings do
        :ok
      else
        advance_through_join(resources, instance, token, graph, join_node_id)
      end
    end
  end

  defp advance_through_join(resources, instance, _token, graph, join_node_id) do
    outgoing =
      graph["flows"]
      |> Map.values()
      |> Enum.filter(fn flow -> flow["from"] == join_node_id end)

    case outgoing do
      [flow | _] ->
        next_node_id = flow["to"]

        new_token =
          resources.token.create!(
            %{
              instance_id: instance.id,
              node_id: next_node_id,
              status: :active
            },
            authorize?: false
          )

        Oban.insert(AshBpmn.Runtime.AdvanceWorker, %{
          "instance_id" => instance.id,
          "token_id" => new_token.id,
          "node_id" => next_node_id
        })

      _ ->
        :ok
    end
  end

  defp gather_principal_ids(%{id: id} = actor) do
    base = [id]

    # Check for team_ids on the actor struct
    base ++
      case Map.get(actor, :team_ids) do
        ids when is_list(ids) -> ids
        _ -> []
      end
  end

  defp gather_principal_ids(ctx) when is_map(ctx) do
    case Map.get(ctx, :id) do
      nil -> []
      id -> [id]
    end
  end

  defp gather_principal_ids(_), do: []

  # Directly updates a token's status to :consumed via SQL, bypassing the
  # Ash action system whose change-before-validation ordering prevents
  # the StatusIsExecuting validation from seeing the correct status.
  defp consume_token_sql(token) do
    repo = AshPostgres.DataLayer.Info.repo(token.__struct__)
    import Ecto.Query

    {1, _} =
      repo.update_all(
        from(t in "bpmn_tokens",
          where: t.id == type(^token.id, Ecto.UUID),
          update: [set: [status: ^to_string("consumed"), updated_at: fragment("NOW()")]]
        ),
        []
      )

    :ok
  end
end
