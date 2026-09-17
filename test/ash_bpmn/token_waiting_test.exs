# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.TokenWaitingTest do
  @moduledoc """
  The parked-token state machine.

  These tests are mostly about transitions that must be *refused*. A state machine whose only
  tests are of its legal moves is not tested at all: the implementation that accepts every
  move passes all of them, and the whole value of `:waiting` being a distinct status is that
  certain moves into and out of it are impossible.
  """

  use AshBpmn.DataCase, async: false

  require Ash.Query

  alias AshBpmn.Test.{Definition, Instance, Token}

  describe "parking" do
    test "an executing token parks, recording what it listens for and when it began" do
      token = executing_token!()

      parked =
        Token.park!(token, %{
          correlation_key: "invoice-42",
          subscription_signature: "message:AshBpmn.Test.Subject:update"
        })

      assert parked.status == :waiting
      assert parked.correlation_key == "invoice-42"
      assert parked.subscription_signature == "message:AshBpmn.Test.Subject:update"
      assert parked.parked_at
      # Nil, not "now minus something". BPMN-strict is the default: an event that arrived
      # before the token parked is missed, and a subscription must opt into lookback.
      refute parked.lookback_until
    end

    test "an active token cannot park" do
      # The park is a transition *out of* a claim. A token that parks without having been
      # claimed was never handed to anything, so nothing decided it should wait -- which in
      # practice means a worker skipped the claim and two of them are now on the same token.
      token = token!(:active)

      assert {:error, error} = Token.park(token, %{correlation_key: "k"})
      assert Exception.message(error) =~ "must be executing"
    end

    test "a token already waiting cannot park again" do
      # Re-parking would move `parked_at` forward, which is how a token that has been stuck for
      # a month starts looking like it parked this morning.
      token = executing_token!() |> Token.park!(%{correlation_key: "k"})

      assert {:error, error} = Token.park(token, %{correlation_key: "k2"})
      assert Exception.message(error) =~ "must be executing"
    end

    test "a consumed token cannot park" do
      token = executing_token!() |> Token.consume!()

      assert {:error, _} = Token.park(token, %{correlation_key: "k"})
    end
  end

  describe "waking" do
    test "a waiting token is woken into executing, and its attempt count rises" do
      token = executing_token!() |> Token.park!(%{correlation_key: "k"})
      before = token.attempts

      woken = Token.claim_waiting!(token)

      assert woken.status == :executing
      assert woken.attempts == before + 1

      # A running token must not still advertise what it was waiting for. The wait is over;
      # leaving the key behind makes the next reader of this table believe a live subscription
      # exists. What woke it is recorded in the event log, which is where history goes.
      refute woken.correlation_key
      refute woken.parked_at
      refute woken.subscription_signature
    end

    test "the second delivery of the same event loses" do
      # This is what makes catch delivery redelivery-safe without a lock: Oban will re-run a
      # worker after a crash, a correlator may see the same event twice, and the loser must
      # fail rather than advance the token a second time.
      token = executing_token!() |> Token.park!(%{correlation_key: "k"})

      assert %{status: :executing} = Token.claim_waiting!(token)

      # Deliberately the *stale* struct, which is what a redelivery actually holds: it read the
      # token before the first delivery won. The in-memory validation passes here; only the
      # re-read inside the transaction catches it.
      assert {:error, error} = Token.claim_waiting(token)
      assert Exception.message(error) =~ "no longer waiting"
    end

    test "an active token cannot be woken by an event" do
      # `:claim` and `:claim_waiting` are distinct actions precisely so an advance worker and a
      # correlator cannot race into the same token through one door.
      token = token!(:active)

      assert {:error, error} = Token.claim_waiting(token)
      assert Exception.message(error) =~ "must be waiting"
    end

    test "a waiting token cannot be claimed as if it were active" do
      token = executing_token!() |> Token.park!(%{correlation_key: "k"})

      assert {:error, error} = Token.claim(token)
      assert Exception.message(error) =~ "must be active"
    end
  end

  describe "leaving the waiting state by force" do
    test "a waiting token can be consumed" do
      # An interrupting boundary event, a terminate end event and a cancelled instance all
      # prune live branches, and a parked token is a live branch. If waiting could only be left
      # through its own event, none of the three could be implemented.
      token = executing_token!() |> Token.park!(%{correlation_key: "k"})

      assert %{status: :consumed} = Token.consume!(token)
    end

    test "a waiting token can be killed, and reactivating it forgets the stale wait" do
      token = executing_token!() |> Token.park!(%{correlation_key: "k"})

      dead = Token.kill!(token)
      assert dead.status == :dead

      # A dead token keeps its columns -- its status says the wait is over and the record is
      # history. Reactivating it puts it back in flight, though, and an in-flight token
      # carrying a correlation key would be a live-looking subscription for an event the token
      # is no longer positioned to receive. The sweep re-advances it to the catch node, where
      # it parks again with a freshly computed key.
      assert dead.correlation_key == "k"

      revived = Token.reactivate!(dead)
      assert revived.status == :active
      refute revived.correlation_key
    end
  end

  describe "the correlator's query shape" do
    test "waiting tokens are found by signature, and non-waiting ones are not" do
      # Guards the predicate the partial index is built for. If this query ever stops filtering
      # on `status`, the index silently stops being used and the correlator degrades to a full
      # scan with no test failing.
      instance = instance!()
      sig = "message:Subject:approve"

      waiting =
        instance
        |> token_in!(:executing)
        |> Token.park!(%{correlation_key: "a", subscription_signature: sig})

      # Same signature, but consumed: it must not come back.
      consumed =
        instance
        |> token_in!(:executing)
        |> Token.park!(%{correlation_key: "b", subscription_signature: sig})
        |> Token.consume!()

      found =
        Token
        |> Ash.Query.for_read(:read)
        |> Ash.Query.filter(status == :waiting and subscription_signature == ^sig)
        |> Ash.read!(authorize?: false)
        |> Enum.map(& &1.id)

      assert waiting.id in found
      refute consumed.id in found
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp instance! do
    xml = File.read!("test/fixtures/linear.bpmn")

    defn =
      Definition.create!(%{
        key: "waiting_#{System.unique_integer([:positive])}",
        name: "W",
        xml: xml
      })

    if is_nil(defn.graph), do: raise("definition failed to compile: #{inspect(defn.errors)}")

    # `create!` here returns an ok-tuple rather than the record -- the test subject predates
    # the code interface convention. Matched rather than unwrapped blindly so it fails loudly
    # if that is ever fixed.
    {:ok, subject} =
      AshBpmn.Test.Subject.create!(%{name: "waiting", amount: 0, is_privileged: false})

    Instance.create!(%{
      subject_type: "AshBpmn.Test.Subject",
      subject_id: subject.id,
      definition_id: defn.id
    })
  end

  defp token!(status), do: instance!() |> token_in!(status)

  defp token_in!(instance, status) do
    Token.create!(%{
      node_id: "Node_#{System.unique_integer([:positive])}",
      status: status,
      instance_id: instance.id
    })
  end

  defp executing_token!, do: token!(:executing)
end
