# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.BaseResourceTest do
  @moduledoc """
  `:base` — a work item sitting on a host application's base resource.

  Until this option existed the resource macros emitted `use Ash.Resource`
  themselves, so a human task could not inherit anything an application had
  arranged for every other resource it owns: ownership, provenance, soft delete,
  the audit hook, the policy set. "An approval is an ordinary owned, audited,
  tenant-scoped record" was a design intention rather than something the code
  permitted.
  """

  use AshBpmn.DataCase, async: false

  require Ash.Query

  alias AshBpmn.BaseTest.{HumanTask, TaskCandidate}
  alias AshBpmn.Scope

  describe "a resource built on a base" do
    test "goes through the base module rather than Ash.Resource" do
      assert HumanTask.base_resource?()
      assert HumanTask.ash_bpmn_kind() == :human_task
    end

    test "still has the data layer, table and actions the macro provides" do
      assert Ash.Resource.Info.data_layer(HumanTask) == AshPostgres.DataLayer
      assert AshPostgres.DataLayer.Info.table(HumanTask) == "bpmn_human_tasks"

      action_names = Enum.map(Ash.Resource.Info.actions(HumanTask), & &1.name)
      assert :claim in action_names
      assert :complete in action_names
      assert :delegate in action_names
    end

    test "carries both policy sets: the base's, and the engine's bypass" do
      policies = Ash.Policy.Info.policies(HumanTask)

      assert Enum.any?(policies, & &1.bypass?),
             "the engine bypass should survive being emitted after the base's policies"

      refute Enum.all?(policies, & &1.bypass?),
             "the base's own policy should still be there"
    end
  end

  describe "authorization when the bypass comes first" do
    # `AshBpmn.BaseTest.PolicylessBase` leaves authorization to the resource, so
    # the macro's bypass is the first policy and the host's rule follows it.

    test "the engine writes without an actor" do
      candidate =
        TaskCandidate.create!(
          %{
            task_id: Ecto.UUID.generate(),
            principal_type: :user,
            principal_id: Ecto.UUID.generate()
          },
          Scope.engine(%Scope{})
        )

      assert candidate.principal_type == :user
    end

    test "the host's own rule still holds everyone else out" do
      attrs = %{
        task_id: Ecto.UUID.generate(),
        principal_type: :user,
        principal_id: Ecto.UUID.generate()
      }

      assert_raise Ash.Error.Forbidden, fn -> TaskCandidate.create!(attrs) end

      assert %{} = TaskCandidate.create!(attrs, actor: %{id: Ecto.UUID.generate()})
    end
  end

  describe "authorization when the base's policies come first" do
    # `AshBpmn.BaseTest.Resource` ships its own policy set, and `use` expands it
    # before anything the ash_bpmn macro emits. A bypass only short-circuits the
    # policies declared after it, so the engine does *not* get through here.
    #
    # This is pinned rather than fixed on purpose: it is Ash's semantics, not
    # ash_bpmn's, and a host needs to know which arrangement it has. The two ways
    # out are in `AshBpmn.Config.engine_actor/0`.

    test "the engine is forbidden, because the base's policy is ahead of the bypass" do
      assert_raise Ash.Error.Forbidden, fn ->
        HumanTask.create!(
          %{node_id: "approve", name: "Approve it", status: :open},
          Scope.engine(%Scope{})
        )
      end
    end

    test "engine_actor: configuring an actor the base admits is the way out" do
      Application.put_env(:ash_bpmn, :engine_actor, %{id: Ecto.UUID.generate()})
      on_exit(fn -> Application.delete_env(:ash_bpmn, :engine_actor) end)

      task =
        HumanTask.create!(
          %{node_id: "approve_via_engine_actor", name: "Approve it", status: :open},
          Scope.engine(%Scope{})
        )

      assert task.node_id == "approve_via_engine_actor"
    end

    test "a caller the base's own policy admits gets through without the engine" do
      task =
        HumanTask.create!(
          %{node_id: "approve_actor", name: "Approve it", status: :open},
          actor: %{id: Ecto.UUID.generate()}
        )

      assert task.node_id == "approve_actor"
    end
  end

  describe "conflicting options" do
    test ":base with tenant?: true refuses to compile" do
      # Two multitenancy strategies on one resource is not a thing a host wants
      # to discover at runtime, and a base worth inheriting already owns tenancy.
      assert_raise ArgumentError, ~r/`:base` and `tenant\?: true` cannot be combined/, fn ->
        Code.compile_string("""
        defmodule AshBpmn.BaseResourceTest.Conflicting do
          use AshBpmn.Resources.Definition,
            domain: AshBpmn.BaseTest.Domain,
            repo: AshBpmn.TestRepo,
            base: AshBpmn.BaseTest.Resource,
            tenant?: true
        end
        """)
      end
    end
  end

  describe "policies?: false" do
    test "removes the engine bypass, leaving the host to grant it" do
      assert Ash.Policy.Info.policies(AshBpmn.BaseTest.NoPolicies) == []
    end

    test "an authorizer with nothing to satisfy refuses even the engine" do
      assert_raise Ash.Error.Forbidden, fn ->
        AshBpmn.BaseTest.NoPolicies
        |> Ash.Query.for_read(:read)
        |> Ash.read!(Scope.engine(%Scope{}))
      end
    end
  end
end
