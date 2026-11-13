# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.Triggers.Redrive do
  @moduledoc """
  The engine half of re-driving a failed trigger dispatch. `AshBpmn.Resources.Redrive`
  calls it; see there for the semantics a host relies on.

  `drive/3` takes one failed dispatch and, in order:

    1. checks it is a `:failed` start dispatch of this tenant that names a subscription;
    2. reads the subscription version on the row, whatever its status now;
    3. records `:already_started` when the event already started under that version;
    4. records `:not_started` (`"disabled"`) when the version is disabled;
    5. records `:no_authority` when the host's `:authority` callback refuses;
    6. fetches the event (`AshBpmn.EventSource.fetch_event/4`), `:not_started`
       (`"event_not_found"`) when the log no longer has it;
    7. runs the funnel for that event under that version alone
       (`AshBpmn.Triggers.Correlator.dispatch_event/4` with `redrive: true`), holding the
       tenant's sweep lock (`AshBpmn.Triggers.SweepWorker.lock_tenant/2`), in the caller's
       transaction;
    8. reads the outcome back from the dispatch ledger.

  The rows it reads are read with the engine's mark (`AshBpmn.Scope.engine/2`), scoped to
  the tenant.
  """

  require Ash.Query

  alias AshBpmn.Scope
  alias AshBpmn.Triggers.{Correlator, SweepWorker}

  @typedoc "What a re-drive records about one failed dispatch."
  @type result :: %{
          subscription_id: Ash.UUID.t(),
          event_id: Ash.UUID.t(),
          event_sequence: integer(),
          outcome: :started | :already_started | :not_started | :no_authority,
          reason: String.t() | nil,
          dispatch_id: Ash.UUID.t() | nil
        }

  @doc """
  Drives the failed dispatch `failed_dispatch_id` again, for the re-drive resource
  `redrive`. Call it inside a transaction.

  Options: `:tenant`, and `:authority`, an optional `{module, function, args}` called as
  `apply(module, function, [subscription, tenant | args])` before the funnel runs, which
  returns `:ok` or `{:error, reason}`.

  Returns `{:error, message}` when the id names no failed start dispatch of a subscription
  in this tenant, or a subscription that no longer exists.
  """
  @spec drive(module(), Ash.UUID.t(), keyword()) :: {:ok, result()} | {:error, String.t()}
  def drive(redrive, failed_dispatch_id, opts) do
    tenant = Keyword.get(opts, :tenant)
    ctx = SweepWorker.context(Ash.Resource.Info.domain(redrive), tenant)

    with {:ok, failed} <- failed_dispatch(ctx, failed_dispatch_id),
         {:ok, subscription} <- subscription(ctx, failed.subscription_id) do
      {:ok,
       Map.merge(
         %{
           subscription_id: subscription.id,
           event_id: failed.event_id,
           event_sequence: failed.event_sequence,
           reason: nil,
           dispatch_id: nil
         },
         drive_version(ctx, failed, subscription, Keyword.get(opts, :authority))
       )}
    end
  end

  @doc """
  The failed start dispatches of `tenant` whose event lies in `bounds`, for the re-drive
  resource `redrive`: the newest failed row of each (subscription, event), oldest event
  first.

  `bounds` may carry `:from_sequence` and `:to_sequence` (inclusive), `:since` (inclusive)
  and `:until` (exclusive); a `nil` bound is no bound.
  """
  @spec failed(module(), term(), map()) :: [struct()]
  def failed(redrive, tenant, bounds) do
    ctx = SweepWorker.context(Ash.Resource.Info.domain(redrive), tenant)

    ctx.resources.dispatch
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(status == :failed and kind == :start and not is_nil(subscription_id))
    |> bound(:from_sequence, bounds[:from_sequence])
    |> bound(:to_sequence, bounds[:to_sequence])
    |> bound(:since, bounds[:since])
    |> bound(:until, bounds[:until])
    |> Ash.Query.sort(event_sequence: :asc, inserted_at: :desc)
    |> Ash.read!(Scope.engine(ctx.scope))
    |> Enum.uniq_by(&{&1.subscription_id, &1.event_id})
  end

  defp bound(query, _bound, nil), do: query
  defp bound(query, :from_sequence, n), do: Ash.Query.filter(query, event_sequence >= ^n)
  defp bound(query, :to_sequence, n), do: Ash.Query.filter(query, event_sequence <= ^n)
  defp bound(query, :since, at), do: Ash.Query.filter(query, event_occurred_at >= ^at)
  defp bound(query, :until, at), do: Ash.Query.filter(query, event_occurred_at < ^at)

  defp drive_version(ctx, failed, subscription, authority) do
    with :none <- started(ctx, subscription.id, failed.event_id),
         :ok <- enabled(subscription),
         :ok <- authority(authority, subscription, ctx.tenant),
         {:ok, event} <- event(ctx, failed) do
      repo = AshPostgres.DataLayer.Info.repo(ctx.resources.dispatch)
      SweepWorker.lock_tenant(repo, ctx.tenant)

      before = failed_ids(ctx, subscription.id, failed.event_id)
      :ok = Correlator.dispatch_event(event, [subscription], ctx, redrive: true)
      outcome(ctx, subscription.id, failed.event_id, before)
    else
      {:started, dispatch_id} -> %{outcome: :already_started, dispatch_id: dispatch_id}
      {:not_started, reason} -> %{outcome: :not_started, reason: reason}
      {:no_authority, reason} -> %{outcome: :no_authority, reason: text(reason)}
    end
  end

  # What the funnel did this time: a start, or the row it wrote instead.
  defp outcome(ctx, subscription_id, event_id, before) do
    case started(ctx, subscription_id, event_id) do
      {:started, dispatch_id} ->
        %{outcome: :started, dispatch_id: dispatch_id}

      :none ->
        reason =
          ctx
          |> rows(subscription_id, event_id)
          |> Enum.reject(&(&1.id in before))
          |> Enum.map(&(&1.reason || &1.status))
          |> List.first(:no_dispatch)

        %{outcome: :not_started, reason: text(reason)}
    end
  end

  defp failed_dispatch(ctx, id) do
    ctx.resources.dispatch
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^id)
    |> Ash.read_one(Scope.engine(ctx.scope))
    |> case do
      {:ok, %{status: :failed, kind: :start, subscription_id: sid} = dispatch}
      when not is_nil(sid) ->
        {:ok, dispatch}

      {:ok, %{}} ->
        {:error, "is not a failed start dispatch of a subscription"}

      _missing ->
        {:error, "names no dispatch in this tenant"}
    end
  end

  # The version on the row, whatever its status now.
  defp subscription(ctx, id) do
    ctx.resources.subscription
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^id)
    |> Ash.read_one(Scope.engine(ctx.scope))
    |> case do
      {:ok, %{} = subscription} -> {:ok, subscription}
      _missing -> {:error, "names a subscription that no longer exists"}
    end
  end

  defp started(ctx, subscription_id, event_id) do
    ctx
    |> rows(subscription_id, event_id)
    |> Enum.find(&(&1.status == :started))
    |> case do
      nil -> :none
      dispatch -> {:started, dispatch.id}
    end
  end

  defp failed_ids(ctx, subscription_id, event_id) do
    for row <- rows(ctx, subscription_id, event_id), row.status == :failed, do: row.id
  end

  defp rows(ctx, subscription_id, event_id) do
    ctx.resources.dispatch
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(subscription_id == ^subscription_id and event_id == ^event_id)
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.read!(Scope.engine(ctx.scope))
  end

  defp enabled(%{enabled: true}), do: :ok
  defp enabled(_subscription), do: {:not_started, "disabled"}

  defp authority(nil, _subscription, _tenant), do: :ok

  defp authority({module, function, args}, subscription, tenant) do
    case apply(module, function, [subscription, tenant | args]) do
      :ok ->
        :ok

      {:error, reason} ->
        {:no_authority, reason}

      other ->
        raise ArgumentError,
              "#{inspect(module)}.#{function} must return :ok or {:error, reason}, " <>
                "got: #{inspect(other)}"
    end
  end

  defp event(ctx, failed) do
    case AshBpmn.EventSource.fetch_event(
           ctx.event_source,
           ctx.tenant,
           failed.event_id,
           failed.event_sequence
         ) do
      {:ok, event} -> {:ok, event}
      {:error, :not_found} -> {:not_started, "event_not_found"}
    end
  end

  defp text(reason) when is_atom(reason) or is_binary(reason), do: to_string(reason)
  defp text(reason), do: inspect(reason)
end
