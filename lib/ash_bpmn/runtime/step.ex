# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.Runtime.Step do
  @moduledoc """
  One step of a process -- a token through a node -- committed as one transaction.

  Advancing a token writes several rows: the token's own transition, the tokens that replace
  it, the instance's status, the process events, the tasks and their candidates, and the Oban
  jobs that carry the next steps. Written one by one, a crash between two of them left a
  graph no recovery could read: a consumed token with no successor, a parked token whose
  child was never started, an instance marked done with a branch still live. `transaction/3`
  is the one place those writes are made to commit together.

  ## What is inside, and what is not

  Inside: every write the engine makes for the step, including `Oban.insert/2`. Oban inserts
  through the same Ecto repo, so in production a job row is part of the transaction and a
  rollback drops it with everything else -- **provided the host's Oban instance uses the repo
  the BPMN resources use**. A host running Oban on a different repo gets the jobs committed
  on their own, which is the behaviour from before this module existed.

  Outside: the work a node does for the host. A service task's action, a business rule's
  decision, an `ash:call` -- those run before the step opens, between the claim and the
  transaction, so a long or failing host call never holds the engine's locks and a rollback
  never pretends to undo something the host has already done.

  ## The instance lock

  `transaction/3` given an instance id takes that instance's row `FOR UPDATE` first, so the
  steps of one instance commit one at a time. It is what makes "am I the last branch?" a
  question with one answer. An end event asks whether any token is still live and a join asks
  how many siblings have arrived; two branches asking at once inside transactions would each
  miss the other's uncommitted write, and both would wait for the other forever. Serialized
  on the instance, the second asks after the first has committed. Only the writes are
  serialized: the host work each branch's node does still runs concurrently.

  ## After commit

  Two things must not happen until the step has committed, and `after_commit/1` defers them:
  a flight-view broadcast (a viewer must never see a move that rolled back) and, in inline
  test mode, running the job a step enqueued. Production Oban only runs a job after the
  insert commits; inline mode used to run it at insert, inside the enqueuing step, so a
  downstream failure would have rolled the upstream step back with it -- a behaviour no
  production system has. Deferred callbacks run in order once the outermost step commits,
  and are dropped if it rolls back.

  The queue lives in the process dictionary, scoped to the process that holds the
  transaction, for the same reason Ash keeps its queued notifications there: a transaction
  is a property of the process that opened it, and nothing else can commit it.
  """

  require Ash.Query

  alias AshBpmn.Scope

  @depth {__MODULE__, :depth}
  @pending {__MODULE__, :after_commit}
  @rollback {__MODULE__, :rollback}

  @doc """
  Runs `fun` as one transaction over the engine's resources.

  Returns `{:ok, result}` when it commits and `{:error, reason}` when `fun` called
  `rollback/2`. An exception raised by `fun` rolls the transaction back and is re-raised.

  Options:

    * `:lock` -- `{instance_id, scope}`: lock that instance's row `FOR UPDATE` before
      running `fun`, and pass the locked instance to it (`fun` is then arity 1). A missing
      instance rolls back with `:instance_gone`.
  """
  @spec transaction(map(), (-> term()) | (map() -> term()), keyword()) ::
          {:ok, term()} | {:error, term()}
  def transaction(resources, fun, opts \\ []) do
    depth = Process.get(@depth, 0)
    Process.put(@depth, depth + 1)

    result =
      try do
        resources
        |> engine_resources()
        |> Ash.transaction(fn -> run(resources, fun, opts[:lock]) end)
        |> rollback_reason()
      catch
        kind, reason ->
          if depth == 0, do: Process.delete(@pending)
          :erlang.raise(kind, reason, __STACKTRACE__)
      after
        restore_depth(depth)
      end

    if depth == 0, do: finish(result), else: result
  end

  @doc """
  Abandons the step: the transaction rolls back and `transaction/3` returns `{:error, reason}`.
  """
  @spec rollback(map(), term()) :: no_return()
  def rollback(resources, reason) do
    Process.put(@rollback, reason)
    Ash.DataLayer.rollback(resources.token, reason)
  end

  @doc """
  Runs `fun` once the outermost step commits; dropped if it rolls back. Outside a step it
  runs now.
  """
  @spec after_commit((-> term())) :: :ok
  def after_commit(fun) when is_function(fun, 0) do
    if in_step?() do
      Process.put(@pending, [fun | Process.get(@pending, [])])
    else
      fun.()
    end

    :ok
  end

  @doc "Whether the calling process is inside `transaction/3`."
  @spec in_step?() :: boolean()
  def in_step?, do: Process.get(@depth, 0) > 0

  # ── internals ────────────────────────────────────────────────────────────

  defp run(_resources, fun, nil) when is_function(fun, 0), do: fun.()

  defp run(resources, fun, {instance_id, scope}) when is_function(fun, 1) do
    case lock_instance(resources, instance_id, scope) do
      nil -> rollback(resources, :instance_gone)
      instance -> fun.(instance)
    end
  end

  defp lock_instance(resources, instance_id, scope) do
    resources.instance
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^instance_id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one!(Scope.engine(scope))
  end

  # The resources one step writes. Ash wants the list so it can open the transaction on each
  # data layer involved; they share a repo, so it is one transaction.
  defp engine_resources(resources) do
    [:instance, :token, :process_event, :human_task, :task_candidate, :timer_job]
    |> Enum.map(&Map.get(resources, &1))
    |> Enum.reject(&is_nil/1)
  end

  # `Ash.transaction/3` wraps a rollback value as an Ash error. The reason `rollback/2` was
  # given is what a caller needs to tell "lost the claim" from "instance gone".
  defp rollback_reason({:error, error}) do
    case Process.delete(@rollback) do
      nil -> {:error, error}
      reason -> {:error, reason}
    end
  end

  defp rollback_reason(other) do
    Process.delete(@rollback)
    other
  end

  defp restore_depth(0), do: Process.delete(@depth)
  defp restore_depth(depth), do: Process.put(@depth, depth)

  defp finish({:ok, _} = result) do
    @pending
    |> Process.delete()
    |> List.wrap()
    |> Enum.reverse()
    |> run_callbacks()

    result
  end

  defp finish(result) do
    Process.delete(@pending)
    result
  end

  # Every callback runs even when one raises, because in production each deferred job runs on
  # its own and one failing does not stop the others. The first failure is re-raised once the
  # rest have run, so inline mode still reports it to whoever started the chain.
  defp run_callbacks(callbacks) do
    failure =
      Enum.reduce(callbacks, nil, fn callback, failure ->
        try do
          callback.()
          failure
        catch
          kind, reason -> failure || {kind, reason, __STACKTRACE__}
        end
      end)

    case failure do
      nil -> :ok
      {kind, reason, stacktrace} -> :erlang.raise(kind, reason, stacktrace)
    end
  end
end
