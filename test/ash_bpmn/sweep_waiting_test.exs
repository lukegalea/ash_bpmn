# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.SweepWaitingTest do
  @moduledoc """
  What the recovery sweep does, and mostly does not do, to a parked token.

  A parked token is the one live token the sweep must not touch. It has no job by design and
  may have none for months, so every naive form of "recover it" is a bug: it would carry the
  token past a wait that never happened. The tests below are therefore weighted towards the
  absence of an effect -- an implementation that swept waiting tokens like active ones would
  pass a test that only checked the orphan case.
  """

  use AshBpmn.DataCase, async: false

  require Ash.Query

  alias AshBpmn.Runtime.Oban.TestJobs
  alias AshBpmn.Runtime.SweepWorker
  alias AshBpmn.Test.{Definition, Instance, ProcessEvent, Token}

  # Long enough that no grace window could plausibly cover it, and recognisable in a failure
  # message as "this has been waiting forever" rather than as an arbitrary number.
  @stale_days 40

  setup do
    AshBpmn.Test.Invoker.clear_calls()
    TestJobs.clear()
    :ok
  end

  describe "a wait that is working" do
    test "a parked token whose wake job is still queued is left entirely alone" do
      defn = publish!("timer_catch.bpmn")
      {:ok, instance} = start!(defn)

      token = token_at(instance, "Wait_1")
      assert token.status == :waiting

      # Aged deliberately. A sweep that ignores parked tokens only because they are young
      # would pass without this, and the thing under test is that *age is not the signal* --
      # the presence of the job is.
      backdate_park!(token, @stale_days)

      sweep!()

      # Nothing happened, asserted from four directions, because "did nothing" is the whole
      # claim and a single assertion would let most wrong implementations through.
      assert token_at(instance, "Wait_1").status == :waiting
      assert sweep_events(instance) == []
      assert reload(instance).status == :running
      refute Enum.any?(AshBpmn.Test.Invoker.recorded_calls(), &(elem(&1, 1) == "after_wait"))

      # The job is untouched, so the wait will still end normally when it comes due.
      assert [job] = TestJobs.all()
      assert job.args["token_id"] == token.id
    end

    test "a token parked moments ago with no job yet is not reported" do
      # The advance worker parks the token and inserts the wake job as two separate effects.
      # A sweep landing between them sees exactly the orphan signature -- parked, no job --
      # and is completely wrong about it, which is what the grace window exists for.
      defn = publish!("timer_catch.bpmn")
      {:ok, instance} = start!(defn)

      TestJobs.clear()

      sweep!()

      assert sweep_events(instance) == []
      assert token_at(instance, "Wait_1").status == :waiting
    end
  end

  describe "a wait that nothing will ever end" do
    test "a parked timer token whose job has vanished is reported, with its age" do
      defn = publish!("timer_catch.bpmn")
      {:ok, instance} = start!(defn)

      token = token_at(instance, "Wait_1")
      backdate_park!(token, @stale_days)

      # The failure being modelled: the job is gone -- cancelled by hand, pruned after a
      # crash, lost in a migration -- and the token is left listening to nothing.
      TestJobs.clear()

      sweep!()

      assert [event] = sweep_events(instance)
      assert event.token_id == token.id
      assert event.node_id == "Wait_1"
      assert event.data["problem"] == "orphaned_wait"
      assert event.data["subscription_signature"] == "timer:Wait_1"

      # The number that turns a support ticket into a monitored condition.
      assert event.data["age_seconds"] > (@stale_days - 1) * 86_400
    end

    test "reporting an orphan does not advance the token or fire anything" do
      # The point of the whole design. Detecting the orphan must not become repairing it:
      # re-arming means inventing a deadline, and firing on a guess runs the rest of the
      # process -- host actions included -- on the strength of that guess.
      defn = publish!("timer_catch.bpmn")
      {:ok, instance} = start!(defn)

      backdate_park!(token_at(instance, "Wait_1"), @stale_days)
      TestJobs.clear()

      sweep!()

      assert token_at(instance, "Wait_1").status == :waiting
      assert reload(instance).status == :running
      refute Enum.any?(AshBpmn.Test.Invoker.recorded_calls(), &(elem(&1, 1) == "after_wait"))

      # No replacement timer was armed either. A re-armed wait would show up here as a job
      # nobody can explain the deadline of.
      assert TestJobs.all() == []
    end

    test "an orphan is reported once, however many times the sweep runs" do
      # The sweep is a cron and this condition is never repaired, so an un-deduplicated report
      # writes a row per tick until someone intervenes -- burying the diagnosis in copies of
      # itself at exactly the moment someone goes looking for it.
      defn = publish!("timer_catch.bpmn")
      {:ok, instance} = start!(defn)

      backdate_park!(token_at(instance, "Wait_1"), @stale_days)
      TestJobs.clear()

      sweep!()
      sweep!()
      sweep!()

      assert length(sweep_events(instance)) == 1
    end
  end

  describe "waits that are not a timer's" do
    test "a user task's parked token is never treated as orphaned" do
      # A user task parks with no signature at all, because it is woken by someone completing
      # the task rather than by a job. For that token the absence of a job is the normal case
      # and carries no information, so judging it the way a timer is judged would report every
      # open user task in the system as broken.
      defn = publish!("timer_catch.bpmn")
      {:ok, instance} = start!(defn)

      task_token =
        Token.create!(
          %{instance_id: instance.id, node_id: "Review_1", status: :executing},
          authorize?: false
        )
        |> Token.park!(%{}, authorize?: false)

      assert task_token.status == :waiting
      refute task_token.subscription_signature

      backdate_park!(task_token, @stale_days)

      # No job exists for it and none ever did -- the same table state the orphaned timer had.
      TestJobs.clear()

      sweep!()

      assert sweep_events(instance) == []
      assert reload_token(task_token).status == :waiting
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp sweep!, do: SweepWorker.perform(%Oban.Job{args: %{}})

  # Only the orphan reports, not the `:sweep_recovered` rows the active-token path writes.
  # Both kinds share `:sweep_recovered` -- the kind list is the host's schema, not this
  # test's to extend -- so `data["problem"]` is what tells them apart.
  defp sweep_events(instance) do
    ProcessEvent
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(instance_id == ^instance.id and kind == :sweep_recovered)
    |> Ash.Query.sort(recorded_at: :asc)
    |> Ash.read!(authorize?: false)
    |> Enum.filter(&(Map.get(&1.data || %{}, "problem") == "orphaned_wait"))
  end

  # Raw SQL, deliberately, and this is the justification the house rule asks for.
  #
  # `parked_at` is written by the `:park` action and accepted by nothing else, which is
  # correct: a writable park timestamp is exactly how a token stuck for a month starts
  # looking like it parked this morning. Adding an action to move it, or an accept on the
  # existing one, would put that capability in the application's surface to serve a test.
  #
  # So the ageing happens here, against the test repo, where it cannot leak. Parameterised
  # rather than interpolated -- a test that builds SQL by string concatenation teaches the
  # habit even when its inputs are safe.
  defp backdate_park!(token, days) do
    at = DateTime.add(DateTime.utc_now(), -days * 86_400, :second)

    AshBpmn.TestRepo.query!(
      "UPDATE bpmn_tokens SET parked_at = $1 WHERE id = $2",
      [at, Ecto.UUID.dump!(token.id)]
    )

    :ok
  end

  defp unique_key(prefix), do: "#{prefix}_#{System.unique_integer([:positive])}"

  defp publish!(fixture) do
    xml = File.read!("test/fixtures/#{fixture}")
    defn = Definition.create!(%{key: unique_key("sw"), name: "SW", xml: xml})

    if is_nil(defn.graph), do: raise("compile failed: #{inspect(defn.errors)}")

    # Through the resource's own `publish` action, not an UPDATE. Raw SQL would skip
    # `ErrorsEmpty`, the validation that stops a definition with compile errors being
    # published -- so a test using it could publish something the application never would.
    Definition.publish!(defn)
  end

  defp start!(defn) do
    {:ok, subject} =
      AshBpmn.Test.Subject.create!(%{name: "sweep", amount: 0, is_privileged: false})

    AshBpmn.start_instance(AshBpmn.Test.Domain, definition: defn, subject: subject)
  end

  defp reload(instance) do
    Instance
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^instance.id)
    |> Ash.read_one!(authorize?: false)
  end

  defp reload_token(token) do
    Token
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^token.id)
    |> Ash.read_one!(authorize?: false)
  end

  defp token_at(instance, node_id) do
    Token
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(instance_id == ^instance.id and node_id == ^node_id)
    |> Ash.read!(authorize?: false)
    |> List.first()
  end
end
