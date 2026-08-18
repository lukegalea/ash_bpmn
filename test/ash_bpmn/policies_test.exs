# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.PoliciesTest do
  @moduledoc """
  The engine's own authority, and the fact that it is now declared.

  Every generated resource used to name `Ash.Policy.Authorizer` as its authorizer
  and then ship no policies at all, while the engine reached past the authorizer
  with `authorize?: false` at ninety call sites. Both halves were defensible on
  their own — the host owns policy; the engine has to write rows no person may
  write — and together they meant the package shipped an unauthorized path into
  the tables it manages, with nothing in the policy set to show for it.
  """

  use AshBpmn.DataCase, async: false

  require Ash.Query

  alias AshBpmn.Scope
  alias AshBpmn.TenantTest

  @tenant Ecto.UUID.generate()

  @generated [
    TenantTest.Definition,
    TenantTest.Instance,
    TenantTest.Token,
    TenantTest.HumanTask,
    TenantTest.TaskCandidate,
    TenantTest.ProcessEvent
  ]

  describe "the generated policy set" do
    test "every resource carries exactly one policy, and it is the engine bypass" do
      for resource <- @generated do
        assert [policy] = Ash.Policy.Info.policies(resource),
               "#{inspect(resource)} should carry exactly the generated policy"

        assert policy.bypass?, "#{inspect(resource)}'s generated policy should be a bypass"

        # The check is the policy's *condition* -- `bypass Check do … end` puts it
        # there and `authorize_if always()` is the body.
        assert Enum.any?(policy.condition, fn
                 {AshBpmn.Checks.AshBpmnInteraction, _opts} -> true
                 _ -> false
               end),
               "#{inspect(resource)}'s bypass should be conditioned on AshBpmnInteraction"
      end
    end
  end

  describe "who the bypass lets through" do
    test "a read carrying the engine context is allowed" do
      for resource <- @generated do
        assert {:ok, _} =
                 resource
                 |> Ash.Query.for_read(:read)
                 |> Ash.read(Scope.engine(%Scope{tenant: @tenant}))
      end
    end

    test "a read without it is forbidden — including one with a plausible actor" do
      for resource <- @generated do
        assert {:error, %Ash.Error.Forbidden{}} =
                 resource
                 |> Ash.Query.for_read(:read)
                 |> Ash.read(tenant: @tenant)

        assert {:error, %Ash.Error.Forbidden{}} =
                 resource
                 |> Ash.Query.for_read(:read)
                 |> Ash.read(tenant: @tenant, actor: %{id: Ecto.UUID.generate()})
      end
    end

    test "the check describes itself, so a policy breakdown reads" do
      assert AshBpmn.Checks.AshBpmnInteraction.describe([]) =~ "ash_bpmn"
    end
  end

  describe "the engine end to end" do
    test "runs a process with no authorize?: false anywhere in its path" do
      xml = File.read!("test/fixtures/linear.bpmn")

      defn =
        TenantTest.Definition.create!(
          %{key: "policy_path", name: "Policy path", xml: xml},
          Scope.engine(%Scope{tenant: @tenant})
        )

      AshBpmn.TestRepo.query!(
        "UPDATE tenant_bpmn_definitions SET status = 'published' WHERE id = $1",
        [Ecto.UUID.dump!(defn.id)]
      )

      subject =
        case AshBpmn.Test.Subject.create!(%{name: "policy_path", amount: 0}) do
          {:ok, s} -> s
          s when is_map(s) -> s
        end

      assert {:ok, instance} =
               AshBpmn.start_instance(TenantTest.Domain,
                 process: "policy_path",
                 subject: subject,
                 tenant: @tenant
               )

      assert instance.status == :completed
    end
  end

  describe "the source itself" do
    test "no module under lib/ passes authorize?: false" do
      offenders =
        "lib/**/*.ex"
        |> Path.wildcard()
        |> Enum.flat_map(fn path ->
          path
          |> File.read!()
          |> String.split("\n")
          |> Enum.with_index(1)
          |> Enum.filter(fn {line, _} ->
            String.contains?(line, "authorize?: false") and not documentation?(line)
          end)
          |> Enum.map(fn {line, number} -> "#{path}:#{number}: #{String.trim(line)}" end)
        end)

      assert offenders == [],
             """
             `authorize?: false` is back in lib/.

             Engine calls go through `AshBpmn.Scope.engine/2`, which marks them for
             the bypass every generated resource declares. The one deliberate
             exception is `AshBpmn.Scope.subject/2`, which reads a *host* resource
             the engine's policies say nothing about — and it is a named function
             with its reasoning attached rather than an option at a call site.

             #{Enum.join(offenders, "\n")}
             """
    end
  end

  # A doc line or a comment mentioning the option is not a call site. `subject/2`
  # is the one real use, and it is excluded by name so that removing its comment
  # would not quietly re-open the door.
  defp documentation?(line) do
    trimmed = String.trim(line)

    String.starts_with?(trimmed, "#") or
      String.contains?(line, "`authorize?: false`") or
      String.contains?(line, "[actor: scope.actor, tenant: scope.tenant, authorize?: false]")
  end
end
