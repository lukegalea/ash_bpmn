# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.TimerCatchTest do
  @moduledoc """
  Intermediate timer catch events: a token that stops and waits for a length of time.
  """

  use AshBpmn.DataCase, async: false

  require Ash.Query

  alias AshBpmn.Runtime.Oban.TestJobs
  alias AshBpmn.Test.{Definition, Instance, ProcessEvent, Token}

  setup do
    AshBpmn.Test.Invoker.clear_calls()
    TestJobs.clear()
    :ok
  end

  describe "compiling the duration" do
    test "an ISO 8601 duration is read from the diagram and resolved at publish time" do
      defn = compile!("timer_catch.bpmn")
      catch_spec = defn.graph["nodes"]["Wait_1"]["catch"]

      assert catch_spec["kind"] == "timer"
      # Both are kept: the seconds are what the engine schedules with, the source string is
      # what a properties panel shows and what the modeller typed. Storing only the seconds
      # would mean the diagram and the snapshot disagree about what was written.
      assert catch_spec["seconds"] == 4 * 3600
      assert catch_spec["duration"] == "PT4H"
    end

    test "a cycle is refused by name, not as an unknown element" do
      # A modeller who drew a repeating timer needs to be told cycles are unsupported. Being
      # told "unrecognized BPMN element" sends them looking for a typo.
      errors = errors_for!("refusal_timer_cycle.bpmn")
      assert errors =~ "timeCycle"
      assert errors =~ "timeDuration"
    end

    test "a catch event with no event definition is refused as the deadlock it is" do
      errors = errors_for!("refusal_catch_no_definition.bpmn")
      assert errors =~ "no event definition"
    end

    test "a duration in months is refused, because a month is not a length of time" do
      # P1M is legal ISO 8601 and a legal BPMN timer, and it is still refused: how long it
      # lasts depends on when you start counting, so two instances that park a day apart
      # would fire a day and a bit apart. A modeller who wants a month writes P30D.
      errors = errors_for!("refusal_timer_month.bpmn")
      assert errors =~ "not fixed" or errors =~ "months"
    end
  end

  describe "waiting" do
    test "the token parks and nothing else happens until the timer is due" do
      defn = publish!("timer_catch.bpmn")
      {:ok, instance} = start!(defn)

      token = token_at(instance, "Wait_1")
      assert token.status == :waiting
      assert token.parked_at
      assert token.subscription_signature == "timer:Wait_1"

      # The instance is still running, and the task past the wait has not been invoked. If a
      # scheduled job ran on insert this would pass anyway, which is why the assertion is on
      # the *absence* of the downstream effect rather than on the token alone.
      assert reload(instance).status == :running
      refute Enum.any?(AshBpmn.Test.Invoker.recorded_calls(), &(elem(&1, 1) == "after_wait"))
    end

    test "nothing fires early" do
      defn = publish!("timer_catch.bpmn")
      {:ok, instance} = start!(defn)

      # Three hours and fifty-nine minutes in. A wait that fires here is not a wait.
      assert TestJobs.fire_due!(DateTime.add(DateTime.utc_now(), 4 * 3600 - 60, :second)) == 0
      assert token_at(instance, "Wait_1").status == :waiting
    end

    test "when the timer is due the token wakes and the process finishes" do
      defn = publish!("timer_catch.bpmn")
      {:ok, instance} = start!(defn)

      assert TestJobs.fire_due!(DateTime.add(DateTime.utc_now(), 4 * 3600 + 60, :second)) == 1

      assert reload(instance).status == :completed
      assert Enum.any?(AshBpmn.Test.Invoker.recorded_calls(), &(elem(&1, 1) == "after_wait"))
      assert token_at(instance, "Wait_1").status == :consumed

      events = events_for(instance)
      fired = Enum.filter(events, &(&1.kind == :timer_fired))
      assert [event] = fired
      assert event.data["timer_kind"] == "catch"
    end

    test "a second delivery of the same timer job does nothing" do
      # Oban retries a worker whose node died mid-run, so the wake must be idempotent. The
      # claim is what makes it so: the redelivery finds the token no longer waiting.
      defn = publish!("timer_catch.bpmn")
      {:ok, instance} = start!(defn)

      [job] = TestJobs.all()
      assert TestJobs.fire_due!(DateTime.add(DateTime.utc_now(), 5 * 3600, :second)) == 1

      assert {:ok, :not_waiting} =
               AshBpmn.Runtime.CatchTimerWorker.perform(%Oban.Job{args: job.args})

      assert length(Enum.filter(events_for(instance), &(&1.kind == :timer_fired))) == 1
    end

    test "a cancelled instance's parked token is not woken later" do
      defn = publish!("timer_catch.bpmn")
      {:ok, instance} = start!(defn)

      Token.kill!(token_at(instance, "Wait_1"))

      assert TestJobs.fire_due!(DateTime.add(DateTime.utc_now(), 5 * 3600, :second)) == 1

      # The job ran, found the token dead, and stopped. Nothing advanced.
      refute Enum.any?(AshBpmn.Test.Invoker.recorded_calls(), &(elem(&1, 1) == "after_wait"))
      assert reload(instance).status == :running
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp unique_key(prefix), do: "#{prefix}_#{System.unique_integer([:positive])}"

  defp compile!(fixture) do
    defn = create(fixture)
    if is_nil(defn.graph), do: raise("compile failed: #{inspect(defn.errors)}")
    defn
  end

  defp errors_for!(fixture) do
    defn = create(fixture)
    refute defn.graph
    Enum.map_join(defn.errors, " ", & &1["message"])
  end

  defp create(fixture) do
    xml = File.read!("test/fixtures/#{fixture}")
    Definition.create!(%{key: unique_key("tc"), name: "TC", xml: xml})
  end

  defp publish!(fixture) do
    defn = compile!(fixture)

    AshBpmn.TestRepo.query!(
      "UPDATE bpmn_definitions SET status = 'published' WHERE id = '#{defn.id}'"
    )

    Definition.by_key_version!(defn.key, defn.version)
  end

  defp start!(defn) do
    {:ok, subject} =
      AshBpmn.Test.Subject.create!(%{name: "timer", amount: 0, is_privileged: false})

    AshBpmn.start_instance(AshBpmn.Test.Domain, definition: defn, subject: subject)
  end

  defp reload(instance) do
    Instance
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^instance.id)
    |> Ash.read_one!(authorize?: false)
  end

  defp token_at(instance, node_id) do
    Token
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(instance_id == ^instance.id and node_id == ^node_id)
    |> Ash.read!(authorize?: false)
    |> List.first()
  end

  defp events_for(instance) do
    ProcessEvent
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(instance_id == ^instance.id)
    |> Ash.Query.sort(recorded_at: :asc)
    |> Ash.read!(authorize?: false)
  end
end
