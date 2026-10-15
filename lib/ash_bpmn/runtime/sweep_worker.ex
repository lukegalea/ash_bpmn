# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.Runtime.SweepWorker do
  @moduledoc """
  Oban worker that recovers stuck tokens, and reports waits nothing will ever end.

  Three conditions that look alike in a token table and are not alike at all, which is why
  they get three quite different responses:

    * An `:active` token is mid-flight and nothing is carrying it -- a restart dropped the
      job. Re-enqueueing an advance is safe: the claim gate makes it idempotent, so a
      needless re-enqueue costs a losing claim rather than a doubled advance.

    * An `:executing` token whose claim is older than `AshBpmn.Config.claim_timeout/0` was
      claimed by a worker that is gone -- killed by a deploy, the OOM killer, a node lost
      mid-job. Nothing will ever hand that claim back, so the sweep takes it back
      (`:recover`, a compare-and-set on the status and attempt count it read) and re-enqueues
      the advance. The attempt count survives, so a node that kills its worker every time
      still reaches `max_attempts` and fails its instance rather than looping. See
      `recover_stale_claim/4` for why a worker that is merely slow cannot be double-advanced.

    * A `:waiting` token is *parked*. No job is queued for it by design, and it may sit
      that way for months. It is not stuck, and re-enqueueing an advance for it would
      carry it past a wait that never happened. The only thing that can be wrong with a
      parked token is that the thing meant to wake it is gone -- see
      `orphaned_timer_wait?/1`, which detects that and deliberately does not repair it.

  ## Finding out whether a job exists

  Production matches on `oban_jobs.args` containment; inline test mode reads the ETS store
  that stands in for the table. That split is `AshBpmn.Runtime.Oban`'s, not a second one
  invented here -- see `live_wake_job?/1` for why the match is on `args` and not on the
  `meta` that `AshBpmn.Runtime.Oban.cancel_all/1` uses.
  """

  use Oban.Worker, max_attempts: 1

  require Ash.Query

  alias AshBpmn.Config
  alias AshBpmn.Runtime.CatchTimerWorker
  alias AshBpmn.Runtime.Oban.TestJobs
  alias AshBpmn.Runtime.Step
  alias AshBpmn.Scope

  # A parked token with no job is only suspicious once it has had time to acquire one. The
  # advance worker parks the token and inserts the wake job as two separate effects, so a
  # sweep landing between them sees a parked token with nothing scheduled and is entirely
  # wrong about it. A minute is orders of magnitude longer than that window and orders of
  # magnitude shorter than any wait worth modelling.
  @orphan_grace_seconds 60

  # Only a timer wait can be judged by the absence of a job. `subscription_signature` is
  # `"timer:<node_id>"` for a timer catch and nil for a user task (see
  # `Interpreter.intermediate_catch_event/4` and the user task clause above it). A user
  # task's token is woken by someone completing the task, and a correlated wait by an
  # arriving event; for both, no job was ever supposed to exist, so its absence says
  # nothing.
  @timer_signature_prefix "timer:"

  # Every state from which a job will still run. `executing` is in the list on purpose: a
  # job running right now is emphatically not missing, and omitting it would report every
  # wait whose timer happened to be firing while the sweep read the table.
  @live_job_states ~w(scheduled available executing retryable)

  def queue, do: Config.queue()

  @impl true
  def perform(_job) do
    resources = AshBpmn.Runtime.DomainResolver.resolve!()

    # The sweep is deliberately cross-tenant: it recovers work stranded by a
    # restart, and a restart does not respect tenant boundaries. The resource
    # macros declare `global? true`, so this read is legal without a tenant --
    # and each instance's own scope is picked up below, so every *write* the
    # sweep makes lands in the right tenant.
    scope = Scope.system(:sweep)

    # Find all running instances
    running_instances =
      resources.instance
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(status == :running)
      |> Ash.read!(Scope.engine(scope))

    Enum.each(running_instances, fn instance ->
      sweep_instance(resources, instance, Scope.from_record(instance, actor: scope.actor))
    end)

    {:ok, :swept}
  end

  defp sweep_instance(resources, instance, scope) do
    # One read for both conditions rather than one each: the instance is already in hand and
    # the two statuses are the only live ones, so splitting it would double the round trips
    # to produce the same rows.
    tokens =
      resources.token
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(instance_id == ^instance.id)
      |> Ash.Query.filter(status in [:active, :executing, :waiting])
      |> Ash.read!(Scope.engine(scope))

    Enum.each(tokens, fn token ->
      case token.status do
        :active -> re_enqueue_token(resources, token, instance, scope)
        :executing -> recover_stale_claim(resources, token, instance, scope)
        :waiting -> report_orphaned_wait(resources, token, instance, scope)
      end
    end)
  end

  # The event and the job commit together, so a sweep that dies between them leaves neither
  # rather than a recovery the log claims and nothing carries out.
  defp re_enqueue_token(resources, token, instance, scope) do
    Step.transaction(resources, fn ->
      resources.process_event.create!(
        %{
          instance_id: instance.id,
          token_id: token.id,
          node_id: token.node_id,
          kind: :sweep_recovered,
          data: %{}
        },
        Scope.engine(scope)
      )

      enqueue_advance(token, instance, scope)
    end)
  end

  # A claim nobody is carrying any more, taken back.
  #
  # Only once it is older than `claim_timeout`, which is the same promise the advance worker's
  # own retry keeps: a node is given that long before anything concludes its worker is gone.
  # Keep the timeout longer than the slowest service task, because the sweep cannot tell a
  # dead worker from a slow one by looking -- both are an `:executing` row with an old
  # `updated_at`, and `oban_jobs` says `executing` for both until Oban's Lifeline rescues the
  # dead one.
  #
  # What it can do is make being wrong about a slow worker harmless to the graph:
  #
  #   * the take-back is a compare-and-set (`:recover`) on the status and attempt count read
  #     above, so a worker that finished in the meantime, or a retry that took the claim back
  #     first, turns it into a no-op -- two sweeps racing each other included;
  #   * the slow worker's own step re-reads its token under a row lock and goes ahead only if
  #     the attempt count is still the one it claimed at. Once the sweep's job has claimed
  #     again it is not, so the slow worker writes nothing and its job ends `:claim_lost`.
  #
  # The host action can run twice in that case -- once in each worker. The token cannot move
  # twice.
  #
  # The attempt count is kept, and the re-claim increments it, so a node that kills its worker
  # every time is recovered `max_attempts` times and then failed by the claim itself, with the
  # `:action_failed` event every other exhausted node gets.
  defp recover_stale_claim(resources, token, instance, scope) do
    age = claim_age(token)

    if age >= Config.claim_timeout() do
      Step.transaction(resources, fn ->
        opts = Keyword.put(Scope.engine(scope), :rollback_on_error?, false)

        case resources.token.recover(token, opts) do
          {:ok, recovered} ->
            resources.process_event.create!(
              %{
                instance_id: instance.id,
                token_id: token.id,
                node_id: token.node_id,
                kind: :sweep_recovered,
                data: %{
                  "problem" => "stale_claim",
                  "claimed_for_seconds" => age,
                  "attempts" => token.attempts
                }
              },
              Scope.engine(scope)
            )

            AshBpmn.FlightView.token_moved(instance, recovered)
            enqueue_advance(recovered, instance, scope)
            :recovered

          {:error, _} ->
            :lost_race
        end
      end)
    end
  end

  defp enqueue_advance(token, instance, scope) do
    AshBpmn.Runtime.Oban.insert(
      AshBpmn.Runtime.AdvanceWorker,
      Scope.to_job_args(scope, %{
        "instance_id" => instance.id,
        "token_id" => token.id,
        "node_id" => token.node_id
      })
    )
  end

  # Seconds since the claim. `updated_at` is the claim's timestamp because the claim is the
  # last write a token in `:executing` receives.
  defp claim_age(%{updated_at: %DateTime{} = at}),
    do: DateTime.diff(DateTime.utc_now(), at, :second)

  defp claim_age(%{updated_at: %NaiveDateTime{} = at}),
    do: NaiveDateTime.diff(NaiveDateTime.utc_now(), at, :second)

  # Reported, never repaired -- and that is a decision, not a gap.
  #
  # Re-arming the timer means inventing a deadline, because the one the modeller wrote is in
  # the job that vanished. Both available guesses are wrong in ways the engine cannot detect
  # from here. Firing immediately runs the entire downstream of the process -- host actions,
  # not the engine's -- on the strength of the sweep's belief that the wait elapsed, and
  # nothing the engine does afterwards can un-send what the host sent. Waiting the full
  # duration again silently doubles a deadline someone wrote down, invisibly, which is how a
  # two-day escalation becomes a four-day one that nobody can account for. Recomputing
  # `parked_at + seconds` from the definition looks like a third option and is the first one
  # wearing a hat: for any orphan old enough to be detectable, that instant is already past,
  # so the timer fires immediately.
  #
  # So the row says what is wrong and how long it has been wrong, and a person decides. A
  # timer that never fires is a stalled process, which is bad. A timer fired on the sweep's
  # guess is a process that did the wrong thing, which is worse and is not reversible.
  defp report_orphaned_wait(resources, token, instance, scope) do
    if orphaned_timer_wait?(token) and not already_reported?(resources, token, scope) do
      resources.process_event.create!(
        %{
          instance_id: instance.id,
          token_id: token.id,
          node_id: token.node_id,
          kind: :sweep_recovered,
          data: %{
            # Named, because the other writer of `:sweep_recovered` above means the opposite
            # thing -- "this was recovered" versus "this cannot be recovered from here".
            "problem" => "orphaned_wait",
            "subscription_signature" => token.subscription_signature,
            "parked_at" => token.parked_at && DateTime.to_iso8601(token.parked_at),
            # The point of the row. "Parked" is not a condition; "parked for forty days
            # against a four-hour timer" is, and that is the difference between something a
            # monitor catches and something a customer reports.
            "age_seconds" => age_seconds(token)
          }
        },
        Scope.engine(scope)
      )
    end
  end

  defp orphaned_timer_wait?(token) do
    timer_wait?(token) and past_grace?(token) and not live_wake_job?(token)
  end

  defp timer_wait?(%{subscription_signature: signature}) when is_binary(signature),
    do: String.starts_with?(signature, @timer_signature_prefix)

  defp timer_wait?(_token), do: false

  # A `:waiting` token with no `parked_at` was not written by the `:park` action -- a hand
  # edited row, or a migration that moved a status without the columns that give it meaning.
  # It therefore cannot be inside the park-then-insert window the grace period guards, and is
  # judged on the job alone.
  defp past_grace?(%{parked_at: nil}), do: true
  defp past_grace?(token), do: age_seconds(token) >= @orphan_grace_seconds

  defp age_seconds(%{parked_at: nil}), do: nil
  defp age_seconds(%{parked_at: at}), do: DateTime.diff(DateTime.utc_now(), at, :second)

  # The sweep runs on a cron and repairs nothing, so without this one orphan writes one row
  # per tick forever: at a minute's cadence a wait stuck for a month buries its own diagnosis
  # under forty thousand copies of itself, and the log stops being the place you look.
  defp already_reported?(resources, token, scope) do
    resources.process_event
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(token_id == ^token.id and kind == :sweep_recovered)
    |> Ash.read!(Scope.engine(scope))
    |> Enum.any?(&(Map.get(&1.data || %{}, "problem") == "orphaned_wait"))
  end

  # Matching on `args`, not on the `meta` that `AshBpmn.Runtime.Oban.cancel_all/1` matches
  # on, and the difference matters: timer catch jobs are inserted with no `meta` at all
  # (`Interpreter.timer_catch_job/3`), so a `meta` match would find nothing for any token and
  # report every parked wait in the system as orphaned. Oban's own migration puts a GIN index
  # on `args` as well as on `meta`, so containment here is indexed exactly as it is there.
  defp live_wake_job?(token) do
    if Config.oban_testing() == :inline do
      Enum.any?(TestJobs.all(), fn record ->
        args = Map.get(record, :args)

        Map.get(record, :worker) == CatchTimerWorker and is_map(args) and
          args["token_id"] == token.id
      end)
    else
      import Ecto.Query, only: [where: 3, limit: 2]

      # Derived rather than written out, so renaming the worker breaks the build instead of
      # quietly turning every live timer into a reported orphan.
      worker = Oban.Worker.to_string(CatchTimerWorker)

      query =
        Oban.Job
        |> where([j], j.state in ^@live_job_states)
        |> where([j], j.worker == ^worker)
        |> where([j], fragment("? @> ?", j.args, ^%{"token_id" => token.id}))
        |> limit(1)

      Oban.Repo.all(Oban.config(), query) != []
    end
  end
end
