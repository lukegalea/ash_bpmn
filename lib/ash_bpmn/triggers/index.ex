# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.Triggers.Index do
  @moduledoc """
  The ETS interest index: which resources any published, enabled subscription
  is listening on (TRD §5.2).

  ## Why this is not an optimisation

  Without it, the `AshBpmn.Triggers.Nudge` on the host's event log would
  enqueue a sweep job for **every audited write in the application** — a cost
  imposed on the whole system for a feature most tenants will not use. With it,
  the overwhelmingly common case is one ETS lookup that finds nothing and
  returns. The correlator uses the same index as its funnel's step one: an
  event nobody is listening for costs one context build and one lookup, then
  nothing — no subscription query, no guard evaluation, no rows.

  ## Deliberately stale, and safe because of what it feeds

  The index is rebuilt on a TTL (~60s, the reference application's stance) and
  on an explicit `refresh/0`/`reload!/0`, so a newly published subscription can
  be invisible to the *nudge* for up to a minute. That is acceptable only
  because the nudge is a nudge and not the driver: the cron sweep reaches those
  events regardless, so the cost of staleness is latency rather than a missed
  process. This is the same reasoning that lets the nudge be non-transactional,
  and both are safe for the same underlying reason — the cursor is what makes
  dispatch complete.

  **Host wiring.** The library owns no supervision tree, so the host starts the
  index itself:

      children = [AshBpmn.Triggers.Index, ...]

  and, for prompt invalidation beyond the TTL, calls `reload!/0` (synchronous)
  or `refresh/0` (async) after subscription `publish`/`retire`/`enable`/
  `disable`. If the index is not running at all, `interested?/2` answers `false`
  and the *nudge* simply does not fire; the *correlator* checks `started?/0`
  first and proceeds through the subscription query instead, so a missing index
  costs queries, never correctness.

  ## Shape

  An ETS bag of `{match_resource, match_action_type}` pairs — the action type
  is `:any` when the subscription does not narrow it — built from published
  **and enabled** `kind: :message` subscriptions, deliberately cross-tenant:
  the index answers "does *anyone* care about this resource", and the
  per-tenant question is answered later by the sweep, inside that tenant's
  scope. A resource name is not customer data. (Signal subscriptions are a
  later phase and are not indexed.)
  """

  use GenServer

  require Ash.Query
  require Logger

  alias AshBpmn.Runtime.DomainResolver
  alias AshBpmn.Scope

  @table :ash_bpmn_trigger_index
  @refresh_ms :timer.seconds(60)

  @doc "Whether any published, enabled subscription anywhere matches this resource."
  @spec interested?(String.t(), term()) :: boolean()
  def interested?(resource, action_type \\ :any) when is_binary(resource) do
    case :ets.whereis(@table) do
      :undefined ->
        # Not started -- in a test that does not need it, or during boot. Say
        # no: the cron sweep is the driver, so the only consequence is that the
        # nudge does not fire (and the correlator, which checks started?/0
        # first, falls back to its subscription query).
        false

      _ ->
        given = normalize(action_type)

        @table
        |> :ets.lookup(resource)
        |> Enum.any?(fn {_resource, at} -> at == :any or at == given end)
    end
  rescue
    ArgumentError -> false
  end

  @doc "Whether the index process is running and its table exists."
  @spec started?() :: boolean()
  def started? do
    :ets.whereis(@table) != :undefined
  rescue
    ArgumentError -> false
  end

  @doc "Rebuilds now, asynchronously. A host calls this after publish/retire/enable/disable."
  @spec refresh() :: :ok
  def refresh, do: GenServer.cast(__MODULE__, :refresh)

  @doc """
  Rebuilds now, synchronously, and returns `:ok` once the table reflects the
  database. The spelling tests and hosts that want the invalidation visible
  in their own next statement use.
  """
  @spec reload!() :: :ok
  def reload!, do: GenServer.call(__MODULE__, :reload)

  @doc false
  def table, do: @table

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :bag, read_concurrency: true])
    {:ok, %{}, {:continue, :load}}
  end

  @impl true
  def handle_continue(:load, state) do
    load()
    schedule()
    {:noreply, state}
  end

  @impl true
  def handle_call(:reload, _from, state) do
    load()
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast(:refresh, state) do
    load()
    {:noreply, state}
  end

  @impl true
  def handle_info(:refresh, state) do
    load()
    schedule()
    {:noreply, state}
  end

  defp schedule, do: Process.send_after(self(), :refresh, @refresh_ms)

  defp load do
    entries =
      Enum.flat_map(domains_with_subscriptions(), fn {_domain, mapping} ->
        mapping.subscription
        |> Ash.Query.for_read(:read)
        |> Ash.Query.filter(status == :published and enabled == true and kind == :message)
        |> Ash.read!(Scope.engine(Scope.system(:sweep)))
        |> Enum.map(&{&1.match_resource, normalize(&1.match_action_type)})
      end)

    :ets.delete_all_objects(@table)
    :ets.insert(@table, entries)
    :ok
  rescue
    e ->
      # A failed rebuild leaves the previous contents rather than emptying the table: stale is
      # better than silent, and the sweep covers both.
      Logger.warning("ash_bpmn trigger index refresh failed: #{Exception.message(e)}")
      :ok
  end

  defp domains_with_subscriptions do
    Enum.flat_map(DomainResolver.domains(), fn domain ->
      case AshBpmn.Resources.for_domain(domain) do
        {:ok, mapping} ->
          if is_nil(mapping.subscription), do: [], else: [{domain, mapping}]

        {:error, _, _} ->
          []
      end
    end)
  rescue
    _ -> []
  end

  defp normalize(nil), do: :any
  defp normalize(at) when is_atom(at), do: to_string(at)
  defp normalize(at) when is_binary(at), do: at
  defp normalize(_other), do: :any
end
