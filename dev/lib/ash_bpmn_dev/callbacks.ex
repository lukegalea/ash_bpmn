# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmnDev.Resolver do
  @moduledoc """
  The demo's `AshBpmn.AssignmentResolver`.

  Candidate specs are opaque to the library — `kind="manager_of"
  of="subject.created_by_id"` means whatever this module says it means. Here it
  means the org chart in `AshBpmnDev.People`.
  """

  @behaviour AshBpmn.AssignmentResolver

  alias AshBpmnDev.People

  @impl true
  def candidates(specs, ctx) do
    {:ok, specs |> Enum.flat_map(&resolve(&1, ctx)) |> Enum.uniq()}
  end

  @impl true
  def exclusions(specs, ctx) do
    {:ok, specs |> Enum.flat_map(&exclude(&1, ctx)) |> Enum.uniq()}
  end

  @impl true
  def escalate(task, _ctx) do
    # A real host would notify; the demo records the intent in the log the
    # timer worker writes anyway.
    require Logger
    Logger.info("escalating task #{task.id} (#{task.name})")
    :ok
  end

  # A diagram's `ash:candidate` and a `RequireApproval` option both arrive in
  # this one normalized shape, so there is a single clause per kind.
  defp resolve(%{"kind" => "manager_of", "of" => path}, ctx) do
    case ctx |> subject_field(path) |> People.manager_of() do
      nil -> []
      manager_id -> [%{type: :user, id: manager_id}]
    end
  end

  defp resolve(%{"kind" => "team", "of" => "security"}, _ctx) do
    Enum.map(People.security_team(), &%{type: :user, id: &1})
  end

  defp resolve(_spec, _ctx), do: []

  defp exclude(%{"who" => path}, ctx), do: List.wrap(subject_field(ctx, path))
  defp exclude(_spec, _ctx), do: []

  # The library never interprets these strings itself; reading them as a field
  # of the subject is this host's convention.
  defp subject_field(ctx, path) do
    field =
      path
      |> to_string()
      |> String.replace_prefix("subject.", "")
      |> String.to_existing_atom()

    case Map.get(ctx, :subject) do
      nil -> nil
      subject -> Map.get(subject, field)
    end
  end
end

defmodule AshBpmnDev.Invoker do
  @moduledoc """
  The demo's `AshBpmn.ActionInvoker`.

  Service-task and `on_complete` action refs land here. A real host would call
  its own Ash actions; the demo logs, so the process event trail in the viewer
  shows the invocation without side effects.
  """

  @behaviour AshBpmn.ActionInvoker

  require Logger

  @impl true
  def invoke(action, ctx) do
    subject = ctx[:subject]
    Logger.info("invoking #{action} for #{inspect(subject && subject.id)}")
    :ok
  end
end
