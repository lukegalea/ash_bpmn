# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.StateExportTest do
  @moduledoc """
  The in-flight state export, and the canonical form its digests are taken over.

  Two properties carry the weight here, and neither is about the export's field list.

  The first is that **the digest is stable for the same state and different for different
  state**, in the specific senses a migration cares about: a renamed task is the same shape, a
  rewritten gateway condition is not. A digest that moved on a rename would make every
  classification say "needs attention" and would be switched off within a week; one that did
  not move on a condition change would say "safe to continue" about an instance that is about
  to route somewhere nobody designed.

  The second is that **the export does not contain business data**. A parked token's
  correlation key is a host value -- an invoice number, an account reference -- and an
  artefact meant to be stored, mailed and retained indefinitely must not carry it by default.
  """

  use AshBpmn.DataCase, async: false

  require Ash.Query

  alias AshBpmn.Canonical
  alias AshBpmn.Runtime.Oban.TestJobs
  alias AshBpmn.StateExport
  alias AshBpmn.Test.{Definition, Domain, Instance, Token}

  setup do
    AshBpmn.Test.Invoker.clear_calls()
    TestJobs.clear()
    :ok
  end

  describe "the canonical form" do
    test "key order does not reach the digest" do
      # The whole point. Two maps built in different orders are the same map, and a digest
      # that disagreed would report a change every time a map was rebuilt.
      a = %{"b" => 1, "a" => 2, "c" => %{"z" => 1, "y" => 2}}
      b = %{"c" => %{"y" => 2, "z" => 1}, "a" => 2, "b" => 1}

      assert Canonical.encode(a) == Canonical.encode(b)
      assert Canonical.digest(a) == Canonical.digest(b)
    end

    test "list order does reach the digest" do
      refute Canonical.digest(["a", "b"]) == Canonical.digest(["b", "a"])
    end

    test "an explicit null is not the same document as an absent key" do
      # In a compiled graph `"condition" => nil` is an unconditional flow and a missing
      # `"condition"` key is a node that cannot carry one. Collapsing them would digest two
      # different diagrams the same.
      refute Canonical.digest(%{"condition" => nil}) == Canonical.digest(%{})
    end

    test "an atom and its string digest alike" do
      # Token status arrives as an atom from Ash and as a string from a JSON round trip, and
      # it is the same fact both times.
      assert Canonical.digest(%{"status" => :waiting}) ==
               Canonical.digest(%{"status" => "waiting"})
    end

    test "a float is refused rather than given a printed form" do
      assert_raise ArgumentError, ~r/float/, fn -> Canonical.encode(%{"a" => 1.5}) end
    end

    test "an unrecognised struct is refused rather than digested by field order" do
      assert_raise ArgumentError, ~r/cannot encode/, fn ->
        Canonical.encode(%{"a" => %URI{}})
      end
    end

    test "the digest is prefixed, lower hex and 128 bits" do
      assert "sha256:" <> hex = Canonical.digest(%{"a" => 1})
      assert String.length(hex) == 32
      assert hex == String.downcase(hex)
    end

    test "nothing digests to nil, so 'not captured' stays distinguishable from 'empty'" do
      assert Canonical.digest_or_nil(nil) == nil
      assert Canonical.digest_or_nil(%{}) == nil
      assert Canonical.digest_or_nil([]) == nil
      assert Canonical.digest_or_nil(%{"a" => 1})
    end
  end

  describe "element digests" do
    test "a rename does not change the occupancy digest, and the name is still exported" do
      before = elements!("test/fixtures/exclusive.bpmn")

      renamed =
        "test/fixtures/exclusive.bpmn"
        |> File.read!()
        |> String.replace(~s(name="Task A"), ~s(name="Task Alpha"))
        |> elements_from_xml!()

      for {id, element} <- before do
        assert element["digest"] == renamed[id]["digest"],
               "renaming a node must not change what a token standing on #{id} experiences"
      end

      refute before == renamed, "the names themselves must still be in the export"
    end

    test "rewriting a gateway condition changes the digest of the node it routes from" do
      before = elements!("test/fixtures/exclusive.bpmn")

      after_ =
        "test/fixtures/exclusive.bpmn"
        |> File.read!()
        |> String.replace("subject.amount > 100", "subject.amount > 500")
        |> elements_from_xml!()

      gateway = gateway_id(before)

      refute before[gateway]["digest"] == after_[gateway]["digest"]
      # The node's own config did not move; the flows out of it did. The classifier reports
      # those differently, so the export has to be able to tell them apart.
      assert before[gateway]["node_digest"] == after_[gateway]["node_digest"]
      refute before[gateway]["outgoing_digest"] == after_[gateway]["outgoing_digest"]
    end

    test "a node that routes on a condition is marked, and one that does not is not" do
      elements = elements!("test/fixtures/exclusive.bpmn")

      assert elements[gateway_id(elements)]["conditional_outgoing"]
      refute elements["Start_1"]["conditional_outgoing"]
    end
  end

  describe "the wait spec mirrors what the interpreter actually parks" do
    # The classifier compares a parked token's frozen signature against the signature the
    # *target* definition would produce, so `wait_spec/2` has to agree with
    # `AshBpmn.Runtime.Interpreter` exactly. Asserting that against the interpreter's real
    # output -- a token parked by running the process -- is the only way that stays true when
    # one of them is edited.
    test "for a message catch" do
      {instance, _subject} = start_message_catch!()
      token = token_at(instance, "AwaitPayment")

      elements = elements!("test/fixtures/message_catch.bpmn")

      assert token.subscription_signature == elements["AwaitPayment"]["wait"]["signature"]
      assert elements["AwaitPayment"]["wait"]["kind"] == "message"
    end

    test "for a user task, which parks with no signature at all" do
      elements = elements!("test/fixtures/access_request.bpmn")
      user_task = Enum.find_value(elements, fn {id, e} -> e["type"] == "userTask" && id end)

      assert elements[user_task]["wait"]["kind"] == "human_task"
      refute elements[user_task]["wait"]["signature"]
    end

    test "a node that does not park has no wait spec" do
      elements = elements!("test/fixtures/linear.bpmn")
      assert elements["Start_1"]["wait"] == nil
    end
  end

  describe "exporting" do
    test "a parked instance comes out with its token, its wait and its definition" do
      {instance, _subject} = start_message_catch!()

      export = StateExport.export!(Domain, instance_ids: [instance.id])

      assert export["format"] == "ash_bpmn.in_flight_state"
      assert export["format_version"] == 1

      [exported] = export["instances"]
      assert exported["id"] == instance.id
      assert exported["status"] == "running"
      assert exported["definition_version"] == 1

      [token] = Enum.filter(exported["tokens"], &(&1["node_id"] == "AwaitPayment"))
      assert token["status"] == "waiting"
      assert token["node_type"] == "intermediateCatchEvent"
      assert token["waiting"]["waits_for"] == "message"
      assert token["waiting"]["subscription_signature"] == "message:payment:create"
      assert token["waiting"]["since"]
      assert token["element_digest"]

      [definition] = export["definitions"]
      assert definition["id"] == instance.definition_id
      assert definition["elements"]["AwaitPayment"]["digest"] == token["element_digest"]
    end

    test "the correlation key is digested, not exported" do
      {instance, subject} = start_message_catch!()

      export = StateExport.export!(Domain, instance_ids: [instance.id])
      waiting = waiting_token(export)["waiting"]

      assert export["correlation_keys"] == "digested"
      refute waiting["correlation_key"]
      assert waiting["correlation_key_digest"] == Canonical.digest(subject.id)

      # And nowhere else on the token either -- a digest on one field is no use if the value
      # leaks through another. Scoped to the token rather than to the whole document because
      # this fixture correlates on `subject.id`, and the instance's `subject_id` is exported
      # in the clear on purpose: it is a join key the system issued, not a host value the
      # modeller chose to correlate on.
      refute Canonical.encode(waiting_token(export)) =~ subject.id
    end

    test "an operator can ask for the key in the clear, and the export says so" do
      {instance, subject} = start_message_catch!()

      export =
        StateExport.export!(Domain, instance_ids: [instance.id], include_correlation_keys: true)

      assert export["correlation_keys"] == "included"
      assert waiting_token(export)["waiting"]["correlation_key"] == subject.id
    end

    test "two exports of unchanged state are byte-identical" do
      {instance, _subject} = start_message_catch!()
      now = ~U[2026-09-21 12:00:00.000000Z]
      opts = [instance_ids: [instance.id], now: now]

      assert StateExport.to_json(StateExport.export!(Domain, opts)) ==
               StateExport.to_json(StateExport.export!(Domain, opts))
    end

    test "completed instances are out of scope by default and askable for" do
      {instance, _subject} = start_message_catch!()

      assert StateExport.export!(Domain, instance_ids: [instance.id])["instances"] != []

      Instance.cancel!(instance)

      assert StateExport.export!(Domain, instance_ids: [instance.id])["instances"] == []

      assert [_] =
               StateExport.export!(Domain, instance_ids: [instance.id], statuses: [:cancelled])[
                 "instances"
               ]
    end

    test "a call activity's child is followed into the export and named on the parent's token" do
      # The parent parks with no signature and no correlation key, so the child is reachable
      # only through its own `parent_token_id`. An export that could not follow it would
      # report a token waiting for nothing at all.
      parent = start_call_activity!()

      export = StateExport.export!(Domain)
      parent_entry = Enum.find(export["instances"], &(&1["id"] == parent.id))
      parked = Enum.find(parent_entry["tokens"], &(&1["waiting"] != nil))

      assert parked["waiting"]["waits_for"] == "child_process"
      assert [child] = parked["waiting"]["children"]
      assert Enum.any?(export["instances"], &(&1["id"] == child["instance_id"]))
    end

    test "a domain missing BPMN resources is reported, not raised past" do
      assert {:error, :missing_resources, kinds} =
               StateExport.export(AshBpmn.Test.CallablesDomain)

      assert :definition in kinds
    end
  end

  describe "the read actions behind it" do
    test "in_flight on tokens defaults to the live statuses and loads the definition" do
      {instance, _subject} = start_message_catch!()

      tokens = Token.in_flight!(%{instance_ids: [instance.id]})

      assert Enum.all?(tokens, &(&1.status in [:active, :executing, :waiting]))
      assert Enum.all?(tokens, &(&1.instance.definition.key != nil))
    end

    test "in_flight on instances finds children by the token that started them" do
      parent = start_call_activity!()

      [parked] =
        Enum.filter(Token.in_flight!(%{instance_ids: [parent.id]}), &(&1.status == :waiting))

      assert [child] =
               Instance.in_flight!(%{
                 parent_token_ids: [parked.id],
                 statuses: [:running, :completed, :failed, :errored, :cancelled]
               })

      assert child.parent_instance_id == parent.id
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp unique_key, do: "se_#{System.unique_integer([:positive])}"

  defp elements!(path), do: path |> File.read!() |> elements_from_xml!()

  defp elements_from_xml!(xml) do
    xml |> AshBpmn.Compiler.compile!() |> StateExport.elements()
  end

  defp gateway_id(elements) do
    Enum.find_value(elements, fn {id, e} -> e["type"] == "exclusiveGateway" && id end)
  end

  defp start_message_catch!(xml \\ nil) do
    xml = xml || File.read!("test/fixtures/message_catch.bpmn")
    definition = publish!(xml)

    {:ok, subject} =
      AshBpmn.Test.Subject.create!(%{name: "se", amount: 0, is_privileged: false})

    {:ok, instance} = AshBpmn.start_instance(Domain, definition: definition, subject: subject)
    {instance, subject}
  end

  defp start_call_activity! do
    # The child parks on an approval rather than running straight through: a child that
    # completes immediately releases the parent, and then there is no parked call activity
    # left for the export to find.
    child_key = unique_key()
    publish!(File.read!("test/fixtures/access_request.bpmn"), child_key)

    parent_xml =
      "test/fixtures/call_parent.bpmn"
      |> File.read!()
      |> String.replace("CHILD_KEY", child_key)

    parent = publish!(parent_xml)

    {:ok, subject} =
      AshBpmn.Test.Subject.create!(%{name: "se", amount: 0, is_privileged: true})

    {:ok, instance} = AshBpmn.start_instance(Domain, definition: parent, subject: subject)
    instance
  end

  defp publish!(xml, key \\ nil) do
    definition = Definition.create!(%{key: key || unique_key(), name: "SE", xml: xml})
    if is_nil(definition.graph), do: raise("compile failed: #{inspect(definition.errors)}")
    Definition.publish!(definition)
  end

  defp waiting_token(export) do
    export["instances"]
    |> Enum.flat_map(& &1["tokens"])
    |> Enum.find(&(&1["waiting"] != nil))
  end

  defp token_at(instance, node_id) do
    Token
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(instance_id == ^instance.id and node_id == ^node_id)
    |> Ash.read!(authorize?: false)
    |> List.first()
  end
end
