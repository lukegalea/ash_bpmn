# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.Web.TaskActions do
  @moduledoc """
  Behaviour for task action operations.

  The host application can implement this behaviour to add custom logic
  around task actions (claim, complete, delegate).  The default implementation
  calls the HumanTask resource actions directly.

  All handlers in the web layer call through this behaviour so the host can
  wrap the actions with their own policy layer, audit logging, or notifications.

  ## Implementation

      defmodule MyApp.Bpmn.TaskActions do
        @behaviour AshBpmn.Web.TaskActions

        @impl true
        def claim(task_id, principal, opts) do
          # Add custom logic, then call default
          AshBpmn.Web.DefaultTaskActions.claim(task_id, principal, opts)
        end

        @impl true
        def complete(task_id, outcome, comment, opts) do
          AshBpmn.Web.DefaultTaskActions.complete(task_id, outcome, comment, opts)
        end

        @impl true
        def delegate(task_id, principal_id, opts) do
          AshBpmn.Web.DefaultTaskActions.delegate(task_id, principal_id, opts)
        end
      end

  Every callback takes the web layer's `opts`, which always carry `:domain`.
  """

  @doc "Claim a task for the given principal."
  @callback claim(task_id :: String.t(), principal :: map(), opts :: keyword()) ::
              {:ok, Ash.Resource.record()} | {:error, term()}

  @doc "Complete a task with an outcome and optional comment."
  @callback complete(
              task_id :: String.t(),
              outcome :: atom() | String.t(),
              comment :: String.t() | nil,
              opts :: keyword()
            ) :: {:ok, Ash.Resource.record()} | {:error, term()}

  @doc "Delegate a task to another principal."
  @callback delegate(task_id :: String.t(), principal_id :: String.t(), opts :: keyword()) ::
              {:ok, Ash.Resource.record()} | {:error, term()}
end

defmodule AshBpmn.Web.DefaultTaskActions do
  @moduledoc """
  Default implementation of `AshBpmn.Web.TaskActions`.

  Calls the HumanTask resource actions directly.  Requires `domain:` option
  pointing to the host Ash domain.

  ## Note on authorization

  These handlers use `authorize?: false` by design. The host's `TaskActions`
  swap point is where policy enforcement belongs. The web layer only provides
  the generic UI; hosts wrap it with their own auth context.
  """

  @behaviour AshBpmn.Web.TaskActions

  require Ash.Query

  @impl true
  def claim(task_id, principal, opts) do
    {:ok, %{human_task: human_task_mod, task_candidate: task_candidate_mod}} =
      AshBpmn.Resources.for_domain(Keyword.fetch!(opts, :domain))

    # Verify candidacy before claiming
    task =
      human_task_mod
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(id == ^task_id)
      |> Ash.read_one!(authorize?: false)

    candidates =
      task_candidate_mod
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(task_id == ^task_id)
      |> Ash.read!(authorize?: false)

    is_candidate =
      Enum.any?(candidates, fn c ->
        c.principal_type == principal[:type] && c.principal_id == principal[:id]
      end)

    if is_candidate do
      human_task_mod.claim(
        task,
        %{
          assignee_type: principal[:type],
          assignee_id: principal[:id]
        },
        authorize?: false
      )
    else
      {:error, "not a candidate for this task"}
    end
  end

  @impl true
  def complete(task_id, outcome, comment, opts) do
    {:ok, %{human_task: human_task_mod}} =
      AshBpmn.Resources.for_domain(Keyword.fetch!(opts, :domain))

    task =
      human_task_mod
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(id == ^task_id)
      |> Ash.read_one!(authorize?: false)

    outcome_atom =
      if is_atom(outcome), do: outcome, else: String.to_atom(outcome)

    human_task_mod.complete(
      task,
      %{
        outcome: outcome_atom,
        comment: comment
      },
      authorize?: false
    )
  end

  @impl true
  def delegate(task_id, principal_id, opts) do
    {:ok, %{human_task: human_task_mod}} =
      AshBpmn.Resources.for_domain(Keyword.fetch!(opts, :domain))

    task =
      human_task_mod
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(id == ^task_id)
      |> Ash.read_one!(authorize?: false)

    human_task_mod.delegate(task, :user, principal_id, authorize?: false)
  end
end
