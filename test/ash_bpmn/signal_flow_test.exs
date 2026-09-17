# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.SignalFlowTest do
  @moduledoc """
  Throwing and catching signals through the engine.

  The property that matters, and the one that separates a signal from a message, is that a
  throw wakes *every* listener. A message is addressed to one token by a correlation key; a
  signal has no addressee, and asking which token it was for is a question with no answer.
  """

  use AshBpmn.DataCase, async: false

  require Ash.Query

  alias AshBpmn.Runtime.Oban.TestJobs
  alias AshBpmn.Test.{Definition, Instance, ProcessEvent, Signal, Token}
  alias AshBpmn.Triggers.Correlator

  setup do
    AshBpmn.Test.Invoker.clear_calls()
    TestJobs.clear()
    :ok
  end

  describe "throwing" do
    test "a throw emits and the token carries straight on" do
      instance = start!("signal_throw.bpmn")

      assert [signal] = Ash.read!(Signal, authorize?: false)
      assert signal.name == "account.frozen"
      assert signal.instance_id == instance.id
      assert signal.node_id == "Announce"

      # A throw is not a wait. The process ran to completion in the same advance.
      assert reload(instance).status == :completed
      assert invoked?("react")
    end

    test "the name travels, not the id" do
      # A catch in another diagram has its own bpmn:signal with its own id, so an id could
      # never match across diagrams. The declaration is resolved at compile time and the name
      # is what is written on the row.
      defn = compile!("signal_throw.bpmn")
      throw_node = defn.graph["nodes"]["Announce"]["throw"]

      assert throw_node["ref"] == "Sig_Frozen"
      assert throw_node["name"] == "account.frozen"
    end
  end

  describe "catching" do
    test "a catch parks on the name with no correlation key" do
      instance = start!("signal_catch.bpmn")

      token = token_at(instance, "AwaitFreeze")
      assert token.status == :waiting
      assert token.subscription_signature == "signal:Sig_Frozen"

      # The absence is the point. A key would make it a message.
      refute token.correlation_key
    end

    test "a thrown signal wakes it" do
      instance = start!("signal_catch.bpmn")

      deliver_signal!("Sig_Frozen")

      assert reload(instance).status == :completed
      assert invoked?("react")
      assert [event] = Enum.filter(events(instance), &(&1.kind == :signal_received))
      assert event.data["resource"]
    end

    test "a different signal leaves it waiting" do
      instance = start!("signal_catch.bpmn")

      deliver_signal!("Sig_Something_Else")

      assert token_at(instance, "AwaitFreeze").status == :waiting
      refute invoked?("react")
    end
  end

  describe "broadcast" do
    test "one throw wakes every listener, and consumes none of them" do
      # The whole difference from a message. Three processes waiting on the same name all
      # proceed; a message would have woken exactly one and left the other two parked.
      instances = for _ <- 1..3, do: start!("signal_catch.bpmn")

      deliver_signal!("Sig_Frozen")

      for instance <- instances do
        assert reload(instance).status == :completed,
               "every listener should wake, not just the first"
      end

      assert length(
               Enum.filter(AshBpmn.Test.Invoker.recorded_calls(), fn {_, a, _} ->
                 a == "react"
               end)
             ) == 3
    end

    test "a signal nobody is listening for is an ordinary event, not an error" do
      # Throwing into an empty room is the normal case: a process announces something and
      # whether anyone cares is not its business.
      assert {:ok, signal} = AshBpmn.emit_signal("nobody.cares")
      assert signal.name == "nobody.cares"

      deliver_signal!("nobody.cares")
    end
  end

  describe "starting a process from a signal" do
    test "a signal subscription starts an instance; a message subscription does not" do
      # Signal subscriptions hear a name. The guard that matters is the negative one: a
      # message subscription that happened to match the signal resource would otherwise start
      # a process on every signal thrown anywhere, which is the failure mode of matching on
      # the event rather than on the subscription's own kind.
      defn = compile!("signal_catch.bpmn") |> Definition.publish!()

      signal_sub = %{
        id: Ash.UUID.generate(),
        kind: :signal,
        signal_name: "Sig_Frozen",
        match_resource: nil,
        match_action: nil,
        match_action_type: nil,
        key: "on_freeze",
        process_key: defn.key,
        guard: nil,
        target_kind: :static,
        decision_key: nil,
        max_starts_per_event: 1,
        subject_source: nil,
        variable_mapping: %{}
      }

      message_sub = %{
        signal_sub
        | id: Ash.UUID.generate(),
          kind: :message,
          signal_name: nil,
          match_resource: AshBpmn.Resources.Subscription.ResourceName.short(Signal),
          key: "on_any_signal_row"
      }

      assert Correlator.matches_for_test?(signal_sub, signal_ctx("Sig_Frozen"), signal?: true)

      refute Correlator.matches_for_test?(message_sub, signal_ctx("Sig_Frozen"), signal?: true),
             "a message subscription must not be offered a signal event"

      refute Correlator.matches_for_test?(signal_sub, signal_ctx("Something_Else"), signal?: true)
    end
  end

  describe "refusing" do
    test "a signalRef with no declaration is refused, and says where the declaration goes" do
      xml =
        String.replace(
          File.read!("test/fixtures/signal_catch.bpmn"),
          ~s(<bpmn2:signal id="Sig_Frozen" name="account.frozen"/>),
          ""
        )

      defn = Definition.create!(%{key: key(), name: "S", xml: xml})

      # The catch resolves its ref lazily -- it stores the ref and the correlator matches on
      # it -- so an undeclared ref is caught on the *throw* side. This fixture only catches,
      # so it compiles; the throw fixture is where the refusal bites.
      assert defn.graph

      throw_xml =
        String.replace(
          File.read!("test/fixtures/signal_throw.bpmn"),
          ~s(<bpmn2:signal id="Sig_Frozen" name="account.frozen"/>),
          ""
        )

      throwing = Definition.create!(%{key: key(), name: "S", xml: throw_xml})
      refute throwing.graph

      message = Enum.map_join(throwing.errors, " ", & &1["message"])
      assert message =~ "not declared"
      assert message =~ "beside the process"
    end

    test "a throw with no event definition is refused" do
      xml =
        String.replace(
          File.read!("test/fixtures/signal_throw.bpmn"),
          ~s(<bpmn2:signalEventDefinition id="SigDef_1" signalRef="Sig_Frozen"/>),
          ""
        )

      defn = Definition.create!(%{key: key(), name: "S", xml: xml})
      refute defn.graph
      assert Enum.map_join(defn.errors, " ", & &1["message"]) =~ "node that does nothing"
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp key, do: "sf_#{System.unique_integer([:positive])}"

  defp compile!(fixture) do
    xml = File.read!("test/fixtures/#{fixture}")
    defn = Definition.create!(%{key: key(), name: "SF", xml: xml})
    if is_nil(defn.graph), do: raise("compile failed: #{inspect(defn.errors)}")
    defn
  end

  defp start!(fixture) do
    defn = compile!(fixture) |> Definition.publish!()

    {:ok, subject} =
      AshBpmn.Test.Subject.create!(%{name: "sig", amount: 0, is_privileged: false})

    {:ok, instance} =
      AshBpmn.start_instance(AshBpmn.Test.Domain, definition: defn, subject: subject)

    instance
  end

  # Builds the event a signal row produces in the host's log and hands it to the correlator,
  # which is what the sweep does for real.
  defp deliver_signal!(ref) do
    event = %{
      id: "evt-#{System.unique_integer([:positive])}",
      sequence: System.unique_integer([:positive]),
      occurred_at: DateTime.utc_now(),
      resource: AshBpmn.Resources.Subscription.ResourceName.short(Signal),
      action: :emit,
      action_type: :create,
      record_id: Ash.UUID.generate(),
      version: 1,
      actor: nil,
      tenant: nil,
      data: %{name: ref},
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

  defp signal_ctx(name) do
    AshBpmn.Feel.to_feel_value(%{
      "event" => %{
        "resource" => AshBpmn.Resources.Subscription.ResourceName.short(Signal),
        "action" => "emit",
        "action_type" => "create"
      },
      "data" => %{"name" => name}
    })
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
