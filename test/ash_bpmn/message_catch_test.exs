# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.MessageCatchTest do
  @moduledoc """
  A token parked waiting for something that happens elsewhere in the application.

  This is the wait the `:waiting` state was introduced for. There is no job scheduled for
  such a token and nothing will ever poll on its behalf; the correlator finds it when a
  matching event arrives, or it waits indefinitely, which is correct.
  """

  use AshBpmn.DataCase, async: false

  require Ash.Query

  alias AshBpmn.Runtime.Oban.TestJobs
  alias AshBpmn.Test.{Definition, Instance, ProcessEvent, Token}
  alias AshBpmn.Triggers.Correlator

  setup do
    AshBpmn.Test.Invoker.clear_calls()
    TestJobs.clear()
    :ok
  end

  describe "parking" do
    test "the key is computed from the subject and frozen onto the token" do
      {instance, subject} = start!()

      token = token_at(instance, "AwaitPayment")
      assert token.status == :waiting
      assert token.correlation_key == subject.id
      assert token.subscription_signature == "message:payment:create"

      # No job. That is the point: nothing is scheduled, nothing polls, and the token is
      # perfectly healthy sitting here for a month.
      assert TestJobs.all() == []
    end

    test "a correlate expression that answers null fails the branch rather than parking" do
      # A null key would match every other null key, which is a broadcast, not a
      # correlation. Better to fail where somebody can see it than to park a token
      # addressed to nobody.
      defn =
        publish_xml!(
          String.replace(
            File.read!("test/fixtures/message_catch.bpmn"),
            ~s(correlate="subject.id"),
            ~s(correlate="subject.nonexistent")
          )
        )

      {:ok, subject} =
        AshBpmn.Test.Subject.create!(%{name: "msg", amount: 0, is_privileged: false})

      # Surfaces as an error from the start rather than a parked token. Inline mode reports
      # the worker's error straight back; in production Oban retries and the instance ends
      # `:failed`. Either way the branch stops where somebody can see it, which is what is
      # being asserted -- not the delivery mechanism, which differs between the two.
      assert {:error, error} =
               AshBpmn.start_instance(AshBpmn.Test.Domain, definition: defn, subject: subject)

      assert Exception.message(error) =~ "correlate produced null"
    end
  end

  describe "delivery" do
    test "an event carrying the right key wakes the token and the process finishes" do
      {instance, subject} = start!()

      deliver!(%{invoice_id: subject.id})

      assert reload(instance).status == :completed
      assert token_at(instance, "AwaitPayment").status == :consumed
      assert invoked?("settle")

      assert [event] = Enum.filter(events(instance), &(&1.kind == :message_received))
      assert event.data["resource"] == "payment"
    end

    test "an event carrying a different key leaves the token waiting" do
      {instance, _subject} = start!()

      deliver!(%{invoice_id: Ash.UUID.generate()})

      assert token_at(instance, "AwaitPayment").status == :waiting
      refute invoked?("settle")
      assert reload(instance).status == :running
    end

    test "an event of the right kind that does not carry the field at all is an ordinary no" do
      # `match` evaluates to null. That is not an error to report -- plenty of payments will
      # have nothing to do with any waiting process -- so nothing is recorded and nothing
      # wakes.
      {instance, _subject} = start!()

      deliver!(%{something_else: "x"})

      assert token_at(instance, "AwaitPayment").status == :waiting
      assert events(instance) |> Enum.filter(&(&1.kind == :message_received)) == []
    end

    test "an event of a different kind is not even considered" do
      {instance, subject} = start!()

      deliver!(%{invoice_id: subject.id}, resource: "refund")

      assert token_at(instance, "AwaitPayment").status == :waiting
    end

    test "a redelivered event wakes the token once" do
      # The claim arbitrates. A replayed batch finds the token no longer waiting and loses,
      # which is what makes delivery idempotent without a lock.
      {instance, subject} = start!()

      deliver!(%{invoice_id: subject.id})
      deliver!(%{invoice_id: subject.id})

      assert length(Enum.filter(events(instance), &(&1.kind == :message_received))) == 1
    end

    test "one event wakes every instance correlated to it, and only those" do
      {instance_a, subject_a} = start!()
      {instance_b, _subject_b} = start!()

      deliver!(%{invoice_id: subject_a.id})

      assert reload(instance_a).status == :completed
      assert reload(instance_b).status == :running
      assert token_at(instance_b, "AwaitPayment").status == :waiting
    end
  end

  describe "lookback" do
    test "the default is BPMN-strict: no window, and an early event is missed" do
      {instance, _subject} = start!()

      token = token_at(instance, "AwaitPayment")
      refute token.lookback_until

      # And nothing is armed to go looking for one.
      assert TestJobs.all() == []
    end

    test "a declared window is stored as a watermark, resolved at park" do
      # The instant, not the minutes. A token that parked an hour ago keeps the window it
      # parked with rather than one measured from whenever somebody looks.
      {instance, _subject} = start_with_lookback!(30)

      token = token_at(instance, "AwaitPayment")
      assert token.lookback_until

      age = DateTime.diff(DateTime.utc_now(), token.lookback_until, :second)
      assert age >= 30 * 60 - 5 and age <= 30 * 60 + 5
    end

    test "an event that arrived before the token parked is delivered" do
      # The whole point. Without a window this event is lost: it happened while nothing was
      # listening, and BPMN says that is the end of it. With one, the token re-scans that much
      # history as it parks and finds it.
      with_seeded_source(fn ->
        invoice_id = Ash.UUID.generate()

        AshBpmn.Test.SeededEventSource.put(%{
          data: %{invoice_id: invoice_id},
          occurred_at: DateTime.add(DateTime.utc_now(), -60, :second)
        })

        instance = start_correlated!(invoice_id, lookback: 30)

        assert reload(instance).status == :completed
        assert token_at(instance, "AwaitPayment").status == :consumed
        assert [_] = Enum.filter(events(instance), &(&1.kind == :message_received))
      end)
    end

    test "an event older than the window is still missed, which is the default behaviour" do
      with_seeded_source(fn ->
        invoice_id = Ash.UUID.generate()

        AshBpmn.Test.SeededEventSource.put(%{
          data: %{invoice_id: invoice_id},
          occurred_at: DateTime.add(DateTime.utc_now(), -2, :hour)
        })

        instance = start_correlated!(invoice_id, lookback: 30)

        # Parked, not woken. A window is a window, not "everything that ever happened".
        assert token_at(instance, "AwaitPayment").status == :waiting
        assert reload(instance).status == :running
      end)
    end

    test "with no window declared, the same early event is missed" do
      # The control. Same event, same correlation, no lookback -- and the strict behaviour.
      with_seeded_source(fn ->
        invoice_id = Ash.UUID.generate()

        AshBpmn.Test.SeededEventSource.put(%{
          data: %{invoice_id: invoice_id},
          occurred_at: DateTime.add(DateTime.utc_now(), -60, :second)
        })

        instance = start_correlated!(invoice_id, lookback: nil)

        assert token_at(instance, "AwaitPayment").status == :waiting
      end)
    end

    test "a lookback that is not a whole number of minutes is refused" do
      # "30min" is the one that matters: it *parses*, as 30 with a remainder, so a guard that
      # only checks the number would accept it and quietly mean thirty minutes when the
      # modeller may well have meant something else. "soon" does not parse at all and is the
      # easy case.
      for value <- ["soon", "30min", "-5", "1.5"] do
        xml =
          String.replace(
            File.read!("test/fixtures/message_catch.bpmn"),
            ~s(match="data.invoice_id"),
            ~s(match="data.invoice_id" lookback="#{value}")
          )

        defn = Definition.create!(%{key: unique_key(), name: "M", xml: xml})
        refute defn.graph, "lookback=#{value} should be refused"

        message = Enum.map_join(defn.errors, " ", & &1["message"])
        assert message =~ "invalid lookback"
        assert message =~ "BPMN-strict"
      end
    end
  end

  describe "refusing" do
    test "a message catch with no ash:subscribe is refused" do
      xml =
        File.read!("test/fixtures/message_catch.bpmn")
        |> String.replace(~r|<bpmn2:extensionElements>.*?</bpmn2:extensionElements>|s, "",
          global: false
        )

      defn = Definition.create!(%{key: unique_key(), name: "M", xml: xml})
      refute defn.graph
      assert Enum.map_join(defn.errors, " ", & &1["message"]) =~ "no ash:subscribe"
    end

    test "a subscription without both correlate and match is refused as a broadcast" do
      xml =
        File.read!("test/fixtures/message_catch.bpmn")
        |> String.replace(~s(match="data.invoice_id"), "")

      defn = Definition.create!(%{key: unique_key(), name: "M", xml: xml})
      refute defn.graph

      message = Enum.map_join(defn.errors, " ", & &1["message"])
      assert message =~ "correlate and match"
      assert message =~ "broadcast"
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp unique_key, do: "mc_#{System.unique_integer([:positive])}"

  defp deliver!(data, opts \\ []) do
    event = %{
      id: "evt-#{System.unique_integer([:positive])}",
      sequence: System.unique_integer([:positive]),
      occurred_at: DateTime.utc_now(),
      resource: Keyword.get(opts, :resource, "payment"),
      action: :create,
      action_type: :create,
      record_id: Ash.UUID.generate(),
      version: 1,
      actor: nil,
      tenant: nil,
      data: data,
      changed: %{},
      metadata: %{}
    }

    {:ok, resources} = AshBpmn.Resources.for_domain(AshBpmn.Test.Domain)

    Correlator.dispatch_event(event, [], %{
      event_source: AshBpmn.Test.EventSource,
      resources: resources,
      scope: AshBpmn.Scope.system(:sweep)
    })
  end

  # The subject's id is the correlation key, so a seeded event carrying it as `invoice_id`
  # correlates. Creating the subject with a chosen id is how the event can be seeded *before*
  # the instance exists, which is the ordering the whole feature is about.
  defp start_correlated!(invoice_id, opts) do
    {:ok, subject} =
      AshBpmn.Test.Subject.create!(%{name: "look", amount: 0, is_privileged: false})

    xml =
      File.read!("test/fixtures/message_catch.bpmn")
      |> String.replace(~s(correlate="subject.id"), ~s(correlate="&quot;#{invoice_id}&quot;"))

    xml =
      case opts[:lookback] do
        nil ->
          xml

        m ->
          String.replace(
            xml,
            ~s(match="data.invoice_id"),
            ~s(match="data.invoice_id" lookback="#{m}")
          )
      end

    {:ok, instance} =
      AshBpmn.start_instance(AshBpmn.Test.Domain, definition: publish_xml!(xml), subject: subject)

    instance
  end

  defp with_seeded_source(fun) do
    previous = Application.get_env(:ash_bpmn, :event_source)
    Application.put_env(:ash_bpmn, :event_source, AshBpmn.Test.SeededEventSource)
    AshBpmn.Test.SeededEventSource.clear()

    try do
      fun.()
    after
      Application.put_env(:ash_bpmn, :event_source, previous)
      AshBpmn.Test.SeededEventSource.clear()
    end
  end

  defp start_with_lookback!(minutes) do
    xml =
      String.replace(
        File.read!("test/fixtures/message_catch.bpmn"),
        ~s(match="data.invoice_id"),
        ~s(match="data.invoice_id" lookback="#{minutes}")
      )

    {:ok, subject} =
      AshBpmn.Test.Subject.create!(%{name: "msg", amount: 0, is_privileged: false})

    {:ok, instance} =
      AshBpmn.start_instance(AshBpmn.Test.Domain, definition: publish_xml!(xml), subject: subject)

    {instance, subject}
  end

  defp start! do
    {:ok, subject} =
      AshBpmn.Test.Subject.create!(%{name: "msg", amount: 0, is_privileged: false})

    {:ok, instance} = start_instance(subject)
    {instance, subject}
  end

  defp start_instance(subject) do
    AshBpmn.start_instance(AshBpmn.Test.Domain, definition: publish!(), subject: subject)
  end

  defp publish!, do: publish_xml!(File.read!("test/fixtures/message_catch.bpmn"))

  defp publish_xml!(xml) do
    defn = Definition.create!(%{key: unique_key(), name: "MC", xml: xml})
    if is_nil(defn.graph), do: raise("compile failed: #{inspect(defn.errors)}")

    # Through the resource's own `publish` action, not an UPDATE. Raw SQL here would skip
    # `ErrorsEmpty`, which is the validation that stops a definition with compile errors
    # being published -- so a test using SQL could publish something the application never
    # would, and then assert on its behaviour.
    Definition.publish!(defn)
  end

  defp invoked?(action) do
    Enum.any?(AshBpmn.Test.Invoker.recorded_calls(), fn {_id, a, _ts} -> a == action end)
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

  defp events(instance) do
    ProcessEvent
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(instance_id == ^instance.id)
    |> Ash.read!(authorize?: false)
  end
end
