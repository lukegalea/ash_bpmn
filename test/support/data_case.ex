# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.DataCase do
  @moduledoc """
  Case template for tests that talk to a real PostgreSQL server.

  Each test runs inside the Ecto SQL sandbox with automatic checkout/return.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import AshBpmn.DataCase
      alias AshBpmn.TestRepo
    end
  end

  @doc """
  An actor who may decide `task`: one of its `:user` candidates.

  `AshBpmn.complete_task/2` refuses anyone who is not a candidate of an open task, so a test
  that only needs a decision made takes its decider from the task's own candidate rows.
  """
  def candidate_actor(task) do
    require Ash.Query

    candidate =
      task.__struct__
      |> Ash.Resource.Info.domain()
      |> AshBpmn.Resources.for_domain()
      |> then(fn {:ok, resources} -> resources.task_candidate end)
      |> Ash.Query.filter(task_id == ^task.id and principal_type == :user)
      |> Ash.Query.limit(1)
      |> Ash.read_one!(authorize?: false)

    if is_nil(candidate), do: raise("task #{task.id} has no :user candidate")

    %{id: candidate.principal_id}
  end

  setup tags do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(AshBpmn.TestRepo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end
end
