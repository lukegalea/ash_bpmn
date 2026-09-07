# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.EventSourceTest do
  use ExUnit.Case, async: true

  @double AshBpmn.Test.EventSource

  describe "the behaviour contract" do
    test "the double declares the behaviour and implements all six callbacks" do
      # The behaviour defines the contract...
      callbacks = AshBpmn.EventSource.behaviour_info(:callbacks)

      assert {:stream, 3} in callbacks
      assert {:context, 1} in callbacks
      assert {:sequence, 1} in callbacks
      assert {:occurred_at, 1} in callbacks
      assert {:order_guarantee, 1} in callbacks
      assert {:audited?, 1} in callbacks

      # ...and the double declares it, so dialyzer checks conformance.
      assert AshBpmn.EventSource in @double.module_info(:attributes)[:behaviour]

      for {name, arity} <- callbacks do
        assert function_exported?(@double, name, arity)
      end
    end

    test "stream/3 returns events above the cursor, ascending, bounded" do
      assert {:ok, {[first, second], 2}} = @double.stream("org-1", 0, 10)
      assert first.sequence == 1
      assert second.sequence == 2

      assert {:ok, {[after_first], 2}} = @double.stream("org-1", 1, 10)
      assert after_first.sequence == 2

      assert {:ok, {[only], 1}} = @double.stream("org-1", 0, 1)
      assert only.sequence == 1

      assert {:ok, {[], nil}} = @double.stream("org-1", 2, 10)
    end

    test "context/1 builds the published contract with string keys and short resource names" do
      {:ok, {[event | _], _}} = @double.stream("org-1", 0, 1)
      context = @double.context(event)

      assert %{"event" => event_ctx, "actor" => _, "tenant" => _, "data" => _, "changed" => _} =
               context

      assert event_ctx["resource"] == "payout"
      assert event_ctx["action"] == "approve"
      assert event_ctx["record_id"] == "rec-1"
      assert Map.keys(context) |> Enum.all?(&is_binary/1)
    end

    test "sequence/1 and occurred_at/1 read the event's position and watermark" do
      {:ok, {[event | _], _}} = @double.stream("org-1", 0, 1)
      assert @double.sequence(event) == 1
      assert %DateTime{} = @double.occurred_at(event)
    end

    test "order_guarantee/1 is per-chain: real tenants commit-ordered, NULL tenant not" do
      assert @double.order_guarantee("org-1") == :commit_order
      assert @double.order_guarantee(nil) == :best_effort
    end

    test "audited?/1 backs the publish-time refusal" do
      assert @double.audited?(AshBpmn.Test.CallablesResource)
      refute @double.audited?(String)
    end
  end

  describe "AshBpmn.Config.event_source!/0" do
    test "raises an instructive error when unset" do
      previous = Application.get_env(:ash_bpmn, :event_source)
      Application.delete_env(:ash_bpmn, :event_source)

      on_exit(fn ->
        restore_event_source(previous)
      end)

      error = assert_raise(RuntimeError, fn -> AshBpmn.Config.event_source!() end)

      assert error.message =~ ":event_source is not configured"
      assert error.message =~ "AshBpmn.EventSource"
    end

    test "returns the configured module" do
      previous = Application.get_env(:ash_bpmn, :event_source)
      Application.put_env(:ash_bpmn, :event_source, @double)

      on_exit(fn ->
        restore_event_source(previous)
      end)

      assert AshBpmn.Config.event_source!() == @double
    end

    defp restore_event_source(previous) do
      if previous do
        Application.put_env(:ash_bpmn, :event_source, previous)
      else
        Application.delete_env(:ash_bpmn, :event_source)
      end
    end
  end
end
