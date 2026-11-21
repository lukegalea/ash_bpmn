# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.Runtime.Notices do
  @moduledoc """
  Hands a fired timer's notice to the host's `AshBpmn.TaskNotifier` (DESIGN.md §11.7).

  Called by `AshBpmn.Runtime.TimerWorker` after the timer's own writes have committed, so a
  delivery that fails never undoes them. What is recorded:

    * `:notice_delivered` when the notifier answers `:ok`;
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
      tenant: tenant(task, scope)
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
          actor: Map.get(scope, :actor)
        }

        case call(notifier, notice, ctx) do
          :ok ->
            record(resources, task, :notice_delivered, notice, %{}, scope)
            :ok

          {:failed, message} ->
            if final_attempt?(job) do
              record(resources, task, :notice_failed, notice, %{"error" => message}, scope)
            end

            {:error, message}
        end
    end
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
      :ok -> :ok
      {:error, reason} -> {:failed, inspect(reason, limit: 5)}
      other -> {:failed, "deliver/2 returned an undeclared shape: #{inspect(other, limit: 5)}"}
    end
  rescue
    # Narrow by construction: this wraps the host's callback and nothing else.
    e -> {:failed, Exception.message(e)}
  end

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
