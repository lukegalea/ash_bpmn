# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.Runtime.LookbackWorker do
  @moduledoc """
  Re-scans recent history for a token that has just parked with a `lookback` window.

  Job args: `%{"instance_id" => id, "token_id" => id, "catch_node_id" => binary}`.

  ## The race this buys back, and the one it does not

  BPMN is strict: a catch event receives what arrives while it is listening, and an event
  that came first is missed. That is right for a message meant to be awaited, and wrong for a
  reply that can legitimately beat the wait — a process that starts, does a little work, and
  only then reaches its catch event can lose a response that came back in between.

  A declared window says "this interaction is the second kind", and the answer is a re-scan
  rather than a buffer. A buffer is memory that a restart empties; the log is already durable
  and already ordered, so reading it again is the same answer without the new failure mode.

  It does **not** make delivery retroactive in general. Only a token that declared a window
  scans, only back as far as that window, and only once — at park. An event older than the
  window is missed exactly as BPMN says it should be.

  ## Bounded, and honest about it

  `AshBpmn.EventSource.stream/3` reads forward from a sequence, so a scan starts from the
  tenant's cursor less `@scan_events` and walks forward, keeping what occurred at or after the
  watermark. That bounds the work by a fixed number of rows rather than by how long the log
  is — but it means a tenant busy enough to write more than `@scan_events` inside its own
  window will not reach the whole of it. That is a real limit and it is stated here rather
  than discovered: a five-minute window on a stream doing thousands of events a minute is not
  the five minutes it looks like.
  """

  use Oban.Worker, max_attempts: 3

  require Ash.Query

  alias AshBpmn.Config
  alias AshBpmn.Runtime.DomainResolver
  alias AshBpmn.Scope
  alias AshBpmn.Triggers.Correlator

  # One batch's worth. Generous for the windows this is meant for and small enough that a
  # misconfigured window cannot turn a park into a table scan.
  @scan_events 1_000

  def queue, do: Config.queue()

  @impl true
  def perform(%Oban.Job{args: args}) do
    scope = Scope.from_job(args, :sweep)
    resources = DomainResolver.resolve!(scope.domain)

    token =
      resources.token
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(id == ^args["token_id"])
      |> Ash.read_one!(Scope.engine(scope))

    cond do
      is_nil(token) -> {:cancel, :token_gone}
      token.status != :waiting -> {:ok, :not_waiting}
      is_nil(token.lookback_until) -> {:ok, :no_window}
      true -> scan(resources, token, scope)
    end
  end

  defp scan(resources, token, scope) do
    # A host with no event source has no log to re-scan, and the token is already parked
    # correctly. `Config.event_source!/0` raises by design -- the sweep refuses to start
    # without one -- but this is bookkeeping after the fact, and failing here would retry a
    # scan that can never succeed against a configuration that is not wrong.
    case Config.event_source() do
      nil -> {:ok, :no_event_source}
      source -> scan_with(source, resources, token, scope)
    end
  end

  defp scan_with(source, resources, token, scope) do
    instance =
      resources.instance
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(id == ^token.instance_id)
      |> Ash.read_one!(Scope.engine(scope))

    graph =
      AshBpmn.DefinitionLoader.load!(
        resources.definition,
        instance.definition_id,
        instance,
        scope
      ).graph

    ctx = %{event_source: source, resources: resources, scope: scope}

    delivered =
      scope.tenant
      |> eligible_events(source, token, resources, scope)
      # Oldest first, so if more than one historical event correlates, the token takes the
      # earliest -- the one it would have received had it been listening.
      |> Enum.sort_by(&source.sequence/1)
      |> Enum.reduce_while(:missed, fn event, _acc ->
        Correlator.deliver_one(
          token,
          graph,
          AshBpmn.Feel.to_feel_value(source.context(event)),
          ctx
        )

        # Stop at the first delivery that took. The claim is what decides, so re-reading the
        # token is how this knows whether it is still looking -- and the outcome is returned
        # rather than discarded, so a scan that found nothing is visible in the job's result
        # instead of looking identical to one that woke the process.
        if still_waiting?(resources, token, scope),
          do: {:cont, :missed},
          else: {:halt, :delivered}
      end)

    {:ok, delivered}
  end

  defp eligible_events(tenant, source, token, resources, scope) do
    after_sequence = max(cursor_sequence(resources, scope) - @scan_events, 0)

    tenant
    |> source.stream(after_sequence, @scan_events)
    |> Enum.filter(fn event ->
      DateTime.compare(source.occurred_at(event), token.lookback_until) != :lt
    end)
  end

  # The scan starts relative to where this tenant's dispatcher has already reached, because
  # that is the only position obtainable without searching the log by timestamp -- and the
  # event source's contract is `stream(tenant, after_sequence, limit)`, deliberately, so that
  # the cursor protocol has one shape.
  #
  # No cursor yet means nothing has been dispatched, so there is no history to re-scan and
  # zero is the honest answer rather than a fallback.
  # `nil` when the host has not installed the trigger kinds -- they are optional, and every
  # reader has to treat their absence as "not installed" rather than crashing. Scanning from
  # zero is then correct rather than a fallback: without a dispatcher there is no cursor to be
  # behind, and whatever the source returns from the start is all the history there is.
  defp cursor_sequence(%{cursor: nil}, _scope), do: 0

  defp cursor_sequence(resources, scope) do
    resources.cursor
    |> Ash.Query.for_read(:read)
    |> Ash.read!(Scope.engine(scope))
    |> case do
      [cursor | _] -> cursor.last_sequence || 0
      [] -> 0
    end
  end

  defp still_waiting?(resources, token, scope) do
    resources.token
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^token.id)
    |> Ash.read_one!(Scope.engine(scope))
    |> case do
      nil -> false
      current -> current.status == :waiting
    end
  end
end
