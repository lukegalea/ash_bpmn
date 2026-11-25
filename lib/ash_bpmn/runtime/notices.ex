# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.Runtime.Notices do
  @moduledoc """
  Hands a fired timer's notice to the host's `AshBpmn.TaskNotifier` (DESIGN.md §11.7).

  Called by `AshBpmn.Runtime.TimerWorker` after the timer's own writes have committed, so a
  delivery that fails never undoes them. What is recorded:

    * `:notice_delivered` when the notifier answers `:ok`;
    * `:notice_delivered` naming only the principals reached, with `"not_reached"`, when it
      answers `{:ok, %{not_reached: [{principal, reason}]}}`; `:notice_failed` with
      `"final" => true` when that leaves nobody reached;
    * `:notice_failed` with `"final" => true`, at once and not retried, when it answers
      `{:error, {:final, reason}}`: the host has decided not to try again;
    * nothing but the returned error when it fails and the job has attempts left, so Oban
      retries the job and delivery is asked again with the same key;
    * `:notice_failed` when it fails on the job's final attempt;
    * `:notice_undelivered`, with telemetry, when no notifier is configured. Missing is never
      recorded as a pass. An expiry with no notifier records nothing: an expiry is an outcome
      the graph routes on, not a notice anyone declared.

  The engine computes the recipients: the assignee when the task is claimed (or was, for an
  expiry), otherwise its candidates, plus the principals an escalation just added, always
  minus the task's exclusions.
  """

  require Ash.Query

  alias AshBpmn.Config
  alias AshBpmn.Notice
  alias AshBpmn.Scope

  @undelivered [:ash_bpmn, :notice, :undelivered]

  @doc "The telemetry event emitted when a notice has nowhere to go."
  @spec undelivered_event() :: [atom()]
  def undelivered_event, do: @undelivered

  @doc """
  Delivers one notice.

  `timer` is `%{kind:, index:, repetition:, key:}`; `added` the principals an escalation added.
  Returns `:ok`, or `{:error, message}` for Oban to retry.
  """
  @spec deliver(map(), map(), Notice.kind(), map(), list(), Scope.t(), Oban.Job.t(), keyword()) ::
          :ok | {:error, String.t()}
  def deliver(resources, task, kind, timer, added, scope, job, opts \\ []) do
    notice = %Notice{
      key: timer.key,
      kind: kind,
      task: task,
      recipients: recipients(resources, task, added, scope),
      added: added,
      due_at: Map.get(task, :due_at),
      late: Keyword.get(opts, :late, false),
      repetition: timer.repetition,
      tenant: tenant(task, scope),
      holder: holder(task)
    }

    case Config.task_notifier() do
      nil when kind == :expired ->
        :ok

      nil ->
        undelivered(resources, notice, scope)

      notifier ->
        ctx = %{
          tenant: notice.tenant,
          instance: Keyword.get(opts, :instance),
          timer: timer,
          actor: Map.get(scope, :actor),
          # The last attempt Oban will make: a host that retries a recipient it missed answers
          # with what it reached instead, so the record names who was and who was not told.
          final_attempt?: final_attempt?(job)
        }

        case call(notifier, notice, ctx) do
          :ok ->
            record(resources, task, :notice_delivered, notice, %{}, scope)
            :ok

          {:partial, not_reached} ->
            partial(resources, task, notice, not_reached, scope)

          {:final, message} ->
            record(
              resources,
              task,
              :notice_failed,
              notice,
              %{"error" => message, "final" => true},
              scope
            )

            :ok

          {:failed, message} ->
            if final_attempt?(job) do
              record(resources, task, :notice_failed, notice, %{"error" => message}, scope)
            end

            {:error, message}
        end
    end
  end

  # Some recipients were reached and some were not, and the host will not try those again.
  # Recorded as delivered to the ones reached, naming the others; reaching nobody is a failure.
  defp partial(resources, task, notice, not_reached, scope) do
    missed = Enum.map(not_reached, fn {principal, _reason} -> key(principal) end)
    reached = Enum.reject(notice.recipients, &(key(&1) in missed))

    detail = %{
      "not_reached" =>
        Enum.map(not_reached, fn {principal, reason} ->
          principal |> principal_data() |> Map.put("reason", inspect(reason, limit: 5))
        end)
    }

    if reached == [] do
      record(resources, task, :notice_failed, notice, Map.put(detail, "final", true), scope)
    else
      record(resources, task, :notice_delivered, %{notice | recipients: reached}, detail, scope)
    end

    :ok
  end

  defp key(%{type: type, id: id}), do: {to_string(type), id}

  @doc """
  Whether the notice with this key is settled for the task: delivered, or failed with a final
  answer the host will not retry. A redelivered firing whose notice is settled asks nobody
  again.
  """
  @spec settled?(map(), map(), String.t(), Scope.t()) :: boolean()
  def settled?(resources, task, key, scope) do
    resources.process_event
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(task_id == ^task.id and kind in [:notice_delivered, :notice_failed])
    |> Ash.read!(Scope.engine(scope))
    |> Enum.any?(fn event ->
      event.data["key"] == key and
        (event.kind == :notice_delivered or event.data["final"] == true)
    end)
  end

  @doc """
  Whether a notice with this key has already been delivered for the task.
  """
  @spec delivered?(map(), map(), String.t(), Scope.t()) :: boolean()
  def delivered?(resources, task, key, scope) do
    resources.process_event
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(task_id == ^task.id and kind == :notice_delivered)
    |> Ash.read!(Scope.engine(scope))
    |> Enum.any?(&(&1.data["key"] == key))
  end

  @doc """
  The principals a notice about `task` goes to: the assignee when it has one, otherwise its
  candidate principals, plus `added`, minus the task's exclusions.
  """
  @spec recipients(map(), map(), list(), Scope.t()) :: [AshBpmn.AssignmentResolver.principal()]
  def recipients(resources, task, added, scope) do
    excluded = Map.get(task, :excluded_principal_ids) || []

    holders =
      case task do
        %{assignee_type: type, assignee_id: id} when not is_nil(type) and not is_nil(id) ->
          [%{type: type, id: id}]

        _ ->
          candidates(resources, task, scope)
      end

    (holders ++ added)
    |> Enum.reject(&(&1.id in excluded))
    |> Enum.uniq_by(&{&1.type, &1.id})
  end

  @doc "The task's current candidate principals, oldest first."
  @spec candidates(map(), map(), Scope.t()) :: [AshBpmn.AssignmentResolver.principal()]
  def candidates(resources, task, scope) do
    resources.task_candidate
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(task_id == ^task.id)
    |> Ash.Query.sort(inserted_at: :asc, id: :asc)
    |> Ash.read!(Scope.engine(scope))
    |> Enum.map(&%{type: &1.principal_type, id: &1.principal_id})
  end

  defp undelivered(resources, notice, scope) do
    record(
      resources,
      notice.task,
      :notice_undelivered,
      notice,
      %{"reason" => "no_notifier"},
      scope
    )

    :telemetry.execute(@undelivered, %{count: 1}, %{
      key: notice.key,
      kind: notice.kind,
      task_id: notice.task.id,
      tenant: notice.tenant,
      reason: :no_notifier
    })

    :ok
  end

  defp call(notifier, notice, ctx) do
    case notifier.deliver(notice, ctx) do
      :ok ->
        :ok

      {:ok, %{not_reached: not_reached}} when is_list(not_reached) ->
        partial_answer(notice, not_reached)

      {:error, {:final, reason}} ->
        {:final, inspect(reason, limit: 5)}

      {:error, reason} ->
        {:failed, inspect(reason, limit: 5)}

      other ->
        {:failed, "deliver/2 returned an undeclared shape: #{inspect(other, limit: 5)}"}
    end
  rescue
    # Narrow by construction: this wraps the host's callback and nothing else.
    e -> {:failed, Exception.message(e)}
  end

  # A partial answer names recipients of this notice, each with a reason. Anything else is an
  # answer the engine cannot record truthfully, and is retried like any other failure.
  defp partial_answer(notice, not_reached) do
    recipients = Enum.map(notice.recipients, &key/1)

    cond do
      not Enum.all?(not_reached, &match?({%{type: _, id: _}, _reason}, &1)) ->
        {:failed,
         "deliver/2 answered not_reached entries of an undeclared shape: " <>
           inspect(not_reached, limit: 5) <> "; each is {principal, reason}"}

      not Enum.all?(not_reached, fn {principal, _} -> key(principal) in recipients end) ->
        {:failed,
         "deliver/2 answered not_reached naming a principal that is not a recipient of " <>
           "this notice: " <> inspect(not_reached, limit: 5)}

      true ->
        {:partial, Enum.uniq_by(not_reached, fn {principal, _} -> key(principal) end)}
    end
  end

  defp holder(%{status: :claimed, assignee_type: type, assignee_id: id})
       when not is_nil(type) and not is_nil(id),
       do: %{type: type, id: id}

  defp holder(_task), do: nil

  defp record(resources, task, kind, notice, extra, scope) do
    resources.process_event.create!(
      %{
        instance_id: task.instance_id,
        token_id: task.token_id,
        node_id: task.node_id,
        task_id: task.id,
        kind: kind,
        data:
          Map.merge(
            %{
              "key" => notice.key,
              "notice" => to_string(notice.kind),
              "recipients" => Enum.map(notice.recipients, &principal_data/1)
            },
            extra
          )
      },
      Scope.engine(scope)
    )
  end

  defp principal_data(%{type: type, id: id}), do: %{"type" => to_string(type), "id" => id}

  defp final_attempt?(%Oban.Job{attempt: attempt, max_attempts: max})
       when is_integer(attempt) and is_integer(max),
       do: attempt >= max

  defp final_attempt?(_job), do: false

  defp tenant(task, scope), do: scope.tenant || Map.get(task, :organization_id)
end
