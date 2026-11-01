# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.Runtime.CallTree do
  @moduledoc false

  # The running instances a set of call-activity tokens started, and the ones those started, all
  # the way down. Stopping a parent's wait on a child means stopping the child too: a child left
  # running after the parent stopped waiting does its work for nobody, and its completion finds
  # the parent's token gone.
  #
  # ## Lock first, write second
  #
  # The locks take every descendant's row `FOR UPDATE`, top down, before the caller
  # writes anything, and the caller must claim or kill the parent's token only afterwards.
  # Reversed, it deadlocks against a child finishing at the same moment: the child's step
  # holds the child's lock and then writes the parent's token, so a parent step that had
  # already written its token and then asked for the child's lock would wait on a step waiting
  # on it. In this order the parent waits for the child's step to commit, finds the child no
  # longer running, and skips it -- and then its own claim loses, because the child's
  # completion already woke the token.

  require Ash.Query

  alias AshBpmn.Scope

  # The children a set of call-activity tokens started, then everything below them. Below the
  # first level the walk is by instance rather than by token: a parent being stopped wants
  # every running descendant gone, including one whose own waiting token was already pruned.
  @doc false
  @spec lock_running(map(), [term()], Scope.t()) :: [map()]
  def lock_running(_resources, [], _scope), do: []

  def lock_running(resources, token_ids, scope) do
    children = lock(resources, [parent_token_id: [in: token_ids]], scope)
    children ++ lock_descendants(resources, children, scope)
  end

  @doc false
  @spec lock_descendants(map(), [map()], Scope.t()) :: [map()]
  def lock_descendants(_resources, [], _scope), do: []

  def lock_descendants(resources, instances, scope) do
    ids = Enum.map(instances, & &1.id)
    children = lock(resources, [parent_instance_id: [in: ids]], scope)
    children ++ lock_descendants(resources, children, scope)
  end

  # Cancels what the locks returned: tokens killed, tasks and their clocks closed, each
  # instance marked `:cancelled` with an `:instance_cancelled` event carrying `data`.
  @doc false
  @spec cancel(map(), [map()], map(), Scope.t()) :: :ok
  def cancel(resources, instances, data, scope) do
    Enum.each(instances, fn instance ->
      instance_scope = Scope.from_record(instance, actor: Map.get(scope, :actor))

      AshBpmn.halt_instance_work(resources, instance, :instance_cancelled, instance_scope)
      resources.instance.cancel!(instance, Scope.engine(instance_scope))

      resources.process_event.create!(
        %{instance_id: instance.id, kind: :instance_cancelled, data: data},
        Scope.engine(instance_scope)
      )
    end)
  end

  defp lock(resources, filter, scope) do
    resources.instance
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(^filter)
    |> Ash.Query.filter(status == :running)
    |> Ash.Query.sort(id: :asc)
    |> Ash.Query.lock(:for_update)
    |> Ash.read!(Scope.engine(scope))
  end
end
