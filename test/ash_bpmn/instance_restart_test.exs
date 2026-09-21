# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.InstanceRestartTest do
  @moduledoc """
  Moving a running instance onto a new definition by restarting it under a new one.

  `AshBpmn.Migration.Classifier` answers `needs_restart` and had nothing to hand that verdict
  to. These tests pin what "restart" was decided to mean — supersede, from the start, carrying
  identity and nothing about progress — and, just as importantly, that everything the restart
  threw away is written down where an operator will find it.

  They run against real Postgres and a real definition lifecycle rather than against exported
  documents, which is the opposite choice from `AshBpmn.MigrationClassifierTest` and for the
  opposite reason: the classifier's contract is with a document, and a restart's contract is
  with the database. The thing most worth catching here is a parked token left alive on a
  superseded instance, and that is only observable in rows.
  """

  use AshBpmn.DataCase, async: false

  require Ash.Query

  alias AshBpmn.Migration.Restart
  alias AshBpmn.Runtime.Oban.TestJobs
  alias AshBpmn.Scope
  alias AshBpmn.Test.{Definition, HumanTask, Instance, ProcessEvent, Token}

  alias AshBpmn.TenantTest.Definition, as: TenantDefinition
  alias AshBpmn.TenantTest.ProcessEvent, as: TenantProcessEvent
  alias AshBpmn.TenantTest.Token, as: TenantToken

  setup do
    AshBpmn.Test.Invoker.clear_calls()
    TestJobs.clear()
    :ok
  end

  describe "superseding a parked instance" do
    test "the successor starts from the beginning and parks on the target's signature" do
      # The case the whole thing exists for. The old token is parked on a signature the new
      # definition would never produce, so nothing will ever wake it; the successor runs the
      # new diagram from its start event and parks on the signature the new diagram declares.
      {instance, _subject} = parked_on_payment!()

      assert token_at(instance, "AwaitPayment").subscription_signature == "message:payment:create"

      target = republish!(instance, ~s(resource="payment"), ~s(resource="settlement"))

      {:ok, %{successor: successor}} = AshBpmn.restart_instance(instance)

      assert successor.id != instance.id
      assert successor.definition_id == target.id
      assert reload(successor).status == :running

      parked = token_at(successor, "AwaitPayment")
      assert parked.status == :waiting
      assert parked.subscription_signature == "message:settlement:create"
    end

    test "the old instance is superseded, not cancelled, and names its successor" do
      {instance, _subject} = parked_on_payment!()
      republish!(instance, ~s(resource="payment"), ~s(resource="settlement"))

      {:ok, %{superseded: superseded, successor: successor}} =
        AshBpmn.restart_instance(instance)

      assert superseded.status == :superseded
      assert superseded.superseded_by_instance_id == successor.id
      assert superseded.superseded_at

      # Reloaded, because a returned struct proves what the action built and not what was
      # written. The link is the thing an operator follows a year later.
      assert reload(instance).superseded_by_instance_id == successor.id
    end

    test "the old instance keeps its tokens, dead, and its events" do
      # Nothing is deleted and nothing is rewritten. A superseded instance exists to answer
      # "what was running before we moved it?", and one edited to resemble its successor
      # cannot answer it.
      {instance, _subject} = parked_on_payment!()
      republish!(instance, ~s(resource="payment"), ~s(resource="settlement"))

      {:ok, _} = AshBpmn.restart_instance(instance)

      old_token = token_at(instance, "AwaitPayment")
      assert old_token.status == :dead
      assert old_token.node_id == "AwaitPayment"

      assert :instance_started in event_kinds(instance)
      assert :instance_superseded in event_kinds(instance)
    end

    test "no live token survives on the superseded instance" do
      # The sharp one. The correlator finds waiting tokens by signature and knows nothing
      # about instance status, so a parked token left behind would be woken by an arriving
      # event and would resume a process nobody is running any more.
      {instance, _subject} = parked_on_payment!()
      republish!(instance, ~s(resource="payment"), ~s(resource="settlement"))

      {:ok, _} = AshBpmn.restart_instance(instance)

      statuses = instance |> tokens() |> Enum.map(& &1.status) |> Enum.uniq()
      refute :waiting in statuses
      refute :active in statuses
      refute :executing in statuses
    end

    test "an open human task is closed with the instance" do
      instance = awaiting_approval!()
      assert open_tasks(instance) != []

      republish_same!(instance)
      {:ok, _} = AshBpmn.restart_instance(instance)

      assert open_tasks(instance) == []
    end
  end

  describe "the decision record" do
    test "a wait that would never be woken is recorded as unsafe, by name" do
      {instance, _subject} = parked_on_payment!()
      republish!(instance, ~s(resource="payment"), ~s(resource="settlement"))

      {:ok, %{decision: decision}} = AshBpmn.restart_instance(instance)

      assert decision["classification"] == "needs_manual_attention"
      assert [dropped] = decision["dropped_tokens"]

      assert dropped["node_id"] == "AwaitPayment"
      assert dropped["disposition"] == "unsafe_in_target"
      assert dropped["waits_for"] == "message"
      assert "wait_signature_changed" in dropped["reasons"]
    end

    test "a token standing somewhere the target spells identically says so" do
      # Not a silent pass. The restart re-runs this node by running the diagram, and an
      # operator reading the record needs to see which of the abandoned tokens that is true
      # of and which it is not.
      {instance, _subject} = parked_on_payment!()
      republish_same!(instance)

      {:ok, %{decision: decision}} = AshBpmn.restart_instance(instance)

      assert decision["classification"] == "safe_to_continue"
      assert [dropped] = decision["dropped_tokens"]
      assert dropped["disposition"] == "identical_in_target"
      assert dropped["reasons"] == []
    end

    test "it names both definitions, and is written on both instances" do
      {instance, _subject} = parked_on_payment!()
      target = republish!(instance, ~s(resource="payment"), ~s(resource="settlement"))

      {:ok, %{successor: successor, decision: decision}} = AshBpmn.restart_instance(instance)

      assert decision["format"] == Restart.format()
      assert decision["from_instance_id"] == instance.id
      assert decision["to_instance_id"] == successor.id
      assert decision["from_definition"]["version"] == 1
      assert decision["to_definition"]["version"] == target.version

      # Two rows, because an operator reading either instance must not have to find the other
      # one to learn that a restart happened at all.
      assert [%{data: old_side}] = events_of_kind(instance, :instance_superseded)
      assert [%{data: new_side}] = events_of_kind(successor, :instance_restarted)

      assert old_side["to_instance_id"] == successor.id
      assert new_side["from_instance_id"] == instance.id
    end

    test "it carries no business data, only the identifiers the export already carries" do
      # The record is assembled from an `AshBpmn.StateExport` document rather than from the
      # token rows, precisely so this holds by construction rather than by review.
      {instance, _subject} = parked_on_payment!()
      republish!(instance, ~s(resource="payment"), ~s(resource="settlement"))

      {:ok, %{decision: decision}} = AshBpmn.restart_instance(instance)

      [dropped] = decision["dropped_tokens"]
      refute Map.has_key?(dropped, "correlation_key")
      refute Map.has_key?(dropped, "routing")
      assert dropped["routing_keys"] == []
    end

    test "children left behind by the restart are named" do
      # A parent parked on a call activity has children still running, and stopping the parent
      # leaves them with nobody to return to. The restart does not stop them -- that is the
      # operator's call -- but it refuses to be quiet about them.
      parent = parent_awaiting_child!()

      {:ok, %{decision: decision}} = AshBpmn.restart_instance(parent)

      assert [orphan] = decision["orphaned_children"]
      assert orphan["status"] == "running"
      assert orphan["parent_token_id"] == token_at(parent, "Onboard").id
    end
  end

  describe "what crosses" do
    test "the case, the trace and the accountability, and a new identity" do
      {instance, subject} = parked_on_payment!()
      republish!(instance, ~s(resource="payment"), ~s(resource="settlement"))

      {:ok, %{successor: successor, decision: decision}} = AshBpmn.restart_instance(instance)

      assert successor.subject_id == subject.id
      assert successor.subject_type == instance.subject_type
      assert successor.correlation_id == instance.correlation_id
      assert successor.started_by_id == instance.started_by_id

      # Carried, not reset. The depth is the bound that stops a subscription cycle, and
      # re-basing it at every restart would hand a cycle a way around it.
      assert successor.trigger_depth == instance.trigger_depth
      assert decision["carried"]["trigger_depth"] == instance.trigger_depth
    end

    test "nothing about how far the old run had got" do
      # The successor starts at the start node with exactly one live token. A marking with a
      # carried token *and* a start token is one the target definition can never reach by
      # running, and in a sequential process it is the process running twice.
      {instance, _subject} = parked_on_payment!()
      republish_same!(instance)

      {:ok, %{successor: successor}} = AshBpmn.restart_instance(instance)

      live = successor |> tokens() |> Enum.reject(&(&1.status in [:consumed, :dead]))
      assert length(live) == 1
      assert hd(live).node_id == "AwaitPayment"
    end
  end

  describe "a tenant-scoped install" do
    test "the successor is stamped with the instance's own tenant" do
      # The tenant is not passed in; it is read off the instance. That is the point of
      # attribute multitenancy and it is also the thing that used to go missing -- an
      # `AshBpmn.start_instance/2` that dropped the option created an instance's tokens and
      # events outside any tenant at all, and a restart that rebuilt the option by hand would
      # be a second place for that to happen.
      tenant = Ecto.UUID.generate()
      instance = tenanted_timer_instance!(tenant)

      assert instance.organization_id == tenant

      {:ok, %{successor: successor, superseded: superseded}} =
        AshBpmn.restart_instance(instance)

      assert successor.organization_id == tenant
      assert superseded.status == :superseded

      for token <- tenanted(TenantToken, tenant, successor.id) do
        assert token.organization_id == tenant
      end

      assert :instance_restarted in Enum.map(
               tenanted(TenantProcessEvent, tenant, successor.id),
               & &1.kind
             )
    end
  end

  describe "refusing" do
    test "a superseded instance cannot be restarted again" do
      # Not idempotent, and it must not pretend to be: a second run would start a second
      # successor, both doing the same case's work with neither aware of the other.
      {instance, subject} = parked_on_payment!()
      republish!(instance, ~s(resource="payment"), ~s(resource="settlement"))

      {:ok, %{successor: successor}} = AshBpmn.restart_instance(instance)

      assert {:error, message} = AshBpmn.restart_instance(reload(instance))
      assert message =~ "already superseded"
      assert message =~ successor.id

      # The link still points where it did, and no second successor was started.
      assert instance |> reload() |> Map.fetch!(:superseded_by_instance_id) == successor.id
      assert length(instances_for(subject)) == 2
    end

    test "the resource refuses it too, not only the facade" do
      # The facade's check is for the ordinary case, where a sentence beats a status
      # validation. The action's own `:running` guard is what arbitrates two operators
      # clicking at once, so it has to hold on its own.
      {instance, _subject} = parked_on_payment!()
      republish_same!(instance)

      {:ok, %{successor: successor}} = AshBpmn.restart_instance(instance)

      assert {:error, error} = Instance.supersede(reload(instance), successor.id)
      assert Exception.message(error) =~ "running instance"
    end

    test "an instance cannot supersede itself" do
      {instance, _subject} = parked_on_payment!()

      assert {:error, error} = Instance.supersede(instance, instance.id)
      assert Exception.message(error) =~ "cannot supersede itself"
    end

    test "a completed instance is not restarted, it is started again" do
      instance = completed!()

      assert {:error, message} = AshBpmn.restart_instance(instance)
      assert message =~ "Start a new instance instead"
    end

    test "a target that did not compile is refused before anything is wound down" do
      {instance, _subject} = parked_on_payment!()

      broken =
        Definition.create!(%{
          key: unique_key(),
          name: "broken",
          xml: "<not-bpmn/>"
        })

      refute broken.graph

      assert {:error, message} = AshBpmn.restart_instance(instance, definition: broken)
      assert message =~ "no compiled graph"

      # Nothing moved.
      assert reload(instance).status == :running
      assert token_at(instance, "AwaitPayment").status == :waiting
    end

    test "a process key with nothing published has nothing to restart onto" do
      {instance, _subject} = parked_on_payment!()

      assert {:error, message} = AshBpmn.restart_instance(instance, to_version: 99)
      assert message =~ "version 99"
    end
  end

  describe "choosing the target" do
    test "the latest published definition, without being asked" do
      {instance, _subject} = parked_on_payment!()
      v2 = republish!(instance, ~s(resource="payment"), ~s(resource="settlement"))

      {:ok, %{successor: successor}} = AshBpmn.restart_instance(instance)
      assert successor.definition_id == v2.id
    end

    test "to_version pins the one that was actually classified" do
      # The option pairs with `AshBpmn.Migration.Classifier.classify/3`'s `:to_versions`, so
      # the version an operator classified is the version they restart onto -- rather than
      # whatever happened to be published by the time they clicked.
      {instance, _subject} = parked_on_payment!()
      v2 = republish!(instance, ~s(resource="payment"), ~s(resource="settlement"))
      _v3 = republish!(instance, ~s(resource="payment"), ~s(resource="refund"))

      {:ok, %{successor: successor}} = AshBpmn.restart_instance(instance, to_version: v2.version)

      assert successor.definition_id == v2.id

      assert token_at(successor, "AwaitPayment").subscription_signature ==
               "message:settlement:create"
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp unique_key, do: "restart_#{System.unique_integer([:positive])}"

  defp parked_on_payment! do
    key = unique_key()
    definition = publish!(key, File.read!("test/fixtures/message_catch.bpmn"))

    {:ok, subject} =
      AshBpmn.Test.Subject.create!(%{name: "restart", amount: 0, is_privileged: false})

    {:ok, instance} =
      AshBpmn.start_instance(AshBpmn.Test.Domain,
        definition: definition,
        subject: subject,
        correlation_id: "corr-#{System.unique_integer([:positive])}"
      )

    {instance, subject}
  end

  defp awaiting_approval! do
    key = unique_key()
    definition = publish!(key, File.read!("test/fixtures/access_request.bpmn"))

    {:ok, subject} =
      AshBpmn.Test.Subject.create!(%{name: "restart", amount: 0, is_privileged: true})

    {:ok, instance} =
      AshBpmn.start_instance(AshBpmn.Test.Domain, definition: definition, subject: subject)

    instance
  end

  defp completed! do
    key = unique_key()
    definition = publish!(key, File.read!("test/fixtures/linear.bpmn"))

    {:ok, subject} =
      AshBpmn.Test.Subject.create!(%{name: "restart", amount: 0, is_privileged: false})

    {:ok, instance} =
      AshBpmn.start_instance(AshBpmn.Test.Domain, definition: definition, subject: subject)

    reload(instance)
  end

  # A parent parked on a call activity, with its child still running. The child parks on an
  # approval so that it stays running while the parent is restarted, which is the state the
  # orphan record exists to describe.
  defp parent_awaiting_child! do
    child_key = unique_key()
    publish!(child_key, File.read!("test/fixtures/access_request.bpmn"))

    parent_xml =
      "test/fixtures/call_parent.bpmn"
      |> File.read!()
      |> String.replace("CHILD_KEY", child_key)

    parent_definition = publish!(unique_key(), parent_xml)

    {:ok, subject} =
      AshBpmn.Test.Subject.create!(%{name: "restart", amount: 0, is_privileged: true})

    {:ok, parent} =
      AshBpmn.start_instance(AshBpmn.Test.Domain,
        definition: parent_definition,
        subject: subject
      )

    parent
  end

  # A parked instance in the tenant-scoped instantiation of the same six resources. A timer
  # catch rather than a message one: it parks with no correlator and no event source, so the
  # test asserts about the tenant rather than about the delivery machinery.
  defp tenanted_timer_instance!(tenant) do
    key = unique_key()
    scope = Scope.engine(%Scope{tenant: tenant})

    definition =
      TenantDefinition.create!(
        %{key: key, name: key, xml: File.read!("test/fixtures/timer_catch.bpmn")},
        scope
      )

    if is_nil(definition.graph), do: raise("compile failed: #{inspect(definition.errors)}")

    {:ok, subject} =
      AshBpmn.Test.Subject.create!(%{name: "restart", amount: 0, is_privileged: false})

    {:ok, instance} =
      AshBpmn.start_instance(AshBpmn.TenantTest.Domain,
        definition: TenantDefinition.publish!(definition, scope),
        subject: subject,
        tenant: tenant
      )

    instance
  end

  defp tenanted(resource, tenant, instance_id) do
    resource
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(instance_id == ^instance_id)
    |> Ash.read!(Scope.engine(%Scope{tenant: tenant}))
  end

  defp publish!(key, xml) do
    definition = Definition.create!(%{key: key, name: key, xml: xml})
    if is_nil(definition.graph), do: raise("compile failed: #{inspect(definition.errors)}")

    Definition.publish!(definition)
  end

  # A new version of the instance's own process key, published. `Definition.create!` assigns
  # the next version for the key itself, so this is exactly what an operator does: edit the
  # diagram, publish, and then decide what to do about what is already running.
  defp republish!(instance, from, to) do
    key = definition_of(instance).key
    xml = String.replace(File.read!("test/fixtures/message_catch.bpmn"), from, to)

    publish!(key, xml)
  end

  defp republish_same!(instance) do
    definition = definition_of(instance)
    publish!(definition.key, definition.xml)
  end

  defp definition_of(instance) do
    Definition
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^instance.definition_id)
    |> Ash.read_one!(authorize?: false)
  end

  defp reload(instance) do
    Instance
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^instance.id)
    |> Ash.read_one!(authorize?: false)
  end

  defp instances_for(subject) do
    Instance
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(subject_id == ^subject.id)
    |> Ash.read!(authorize?: false)
  end

  defp tokens(instance) do
    Token
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(instance_id == ^instance.id)
    |> Ash.read!(authorize?: false)
  end

  defp token_at(instance, node_id) do
    Token
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(instance_id == ^instance.id and node_id == ^node_id)
    |> Ash.read!(authorize?: false)
    |> List.first()
  end

  defp open_tasks(instance) do
    HumanTask
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(instance_id == ^instance.id and status in [:open, :claimed])
    |> Ash.read!(authorize?: false)
  end

  defp events(instance) do
    ProcessEvent
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(instance_id == ^instance.id)
    |> Ash.read!(authorize?: false)
  end

  defp events_of_kind(instance, kind), do: instance |> events() |> Enum.filter(&(&1.kind == kind))

  defp event_kinds(instance), do: instance |> events() |> Enum.map(& &1.kind)
end
