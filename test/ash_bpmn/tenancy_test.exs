# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.TenancyTest do
  @moduledoc """
  `tenant?: true`, end to end.

  Every one of these assertions would have passed vacuously before: the tables
  had no `organization_id`, so nothing could be scoped by one, and
  `AshBpmn.start_instance/2` bound the `:tenant` option to `_tenant` and dropped
  it on the floor.
  """

  use AshBpmn.DataCase, async: false

  require Ash.Query

  alias AshBpmn.Runtime.Oban.TestJobs
  alias AshBpmn.Scope
  alias AshBpmn.TenantTest.{Definition, Instance, ProcessEvent, Token}

  @acme Ecto.UUID.generate()
  @globex Ecto.UUID.generate()

  setup do
    AshBpmn.Test.Invoker.clear_calls()
    TestJobs.clear()
    :ok
  end

  describe "start_instance/2 with a tenant" do
    test "stamps the tenant on the instance, its tokens and its events" do
      defn = published_definition!("tenanted_linear", @acme)
      subject = subject!("tenanted_linear")

      {:ok, instance} =
        AshBpmn.start_instance(AshBpmn.TenantTest.Domain,
          process: "tenanted_linear",
          subject: subject,
          tenant: @acme
        )

      assert instance.organization_id == @acme
      assert instance.definition_id == defn.id

      # The tokens and events are created by the engine and by the advance
      # worker respectively -- so this is also an assertion that the tenant
      # survived the trip through the Oban payload.
      for token <- read!(Token, @acme, instance.id) do
        assert token.organization_id == @acme
      end

      events = read!(ProcessEvent, @acme, instance.id)
      assert events != []

      for event <- events do
        assert event.organization_id == @acme
      end

      assert :instance_started in Enum.map(events, & &1.kind)
    end

    test "another tenant cannot see the instance" do
      published_definition!("tenant_isolation", @acme)
      subject = subject!("tenant_isolation")

      {:ok, instance} =
        AshBpmn.start_instance(AshBpmn.TenantTest.Domain,
          process: "tenant_isolation",
          subject: subject,
          tenant: @acme
        )

      assert [_] =
               Instance
               |> Ash.Query.for_read(:read)
               |> Ash.Query.filter(id == ^instance.id)
               |> Ash.read!(Scope.engine(%Scope{tenant: @acme}))

      assert [] =
               Instance
               |> Ash.Query.for_read(:read)
               |> Ash.Query.filter(id == ^instance.id)
               |> Ash.read!(Scope.engine(%Scope{tenant: @globex}))
    end

    test "two tenants run the same process independently" do
      published_definition!("shared_key", @acme)
      published_definition!("shared_key", @globex)

      {:ok, acme_instance} =
        AshBpmn.start_instance(AshBpmn.TenantTest.Domain,
          process: "shared_key",
          subject: subject!("acme"),
          tenant: @acme
        )

      {:ok, globex_instance} =
        AshBpmn.start_instance(AshBpmn.TenantTest.Domain,
          process: "shared_key",
          subject: subject!("globex"),
          tenant: @globex
        )

      refute acme_instance.id == globex_instance.id
      assert acme_instance.organization_id == @acme
      assert globex_instance.organization_id == @globex

      # Each instance's events belong to its own tenant and nobody else's. The
      # partial unique indexes carry `organization_id` for the same reason.
      assert read!(ProcessEvent, @globex, acme_instance.id) == []
      assert read!(ProcessEvent, @acme, globex_instance.id) == []
    end
  end

  describe "Scope" do
    test "from_record/2 reads the tenant and domain off the record" do
      published_definition!("scope_from_record", @acme)

      {:ok, instance} =
        AshBpmn.start_instance(AshBpmn.TenantTest.Domain,
          process: "scope_from_record",
          subject: subject!("scope_from_record"),
          tenant: @acme
        )

      scope = Scope.from_record(instance)

      assert scope.tenant == @acme
      assert scope.domain == AshBpmn.TenantTest.Domain
    end

    test "an explicit tenant beats the record's own" do
      published_definition!("scope_override", @acme)

      {:ok, instance} =
        AshBpmn.start_instance(AshBpmn.TenantTest.Domain,
          process: "scope_override",
          subject: subject!("scope_override"),
          tenant: @acme
        )

      assert Scope.from_record(instance, tenant: @globex).tenant == @globex
    end

    test "to_job_args/2 carries tenant and domain, and omits what is nil" do
      scope = %Scope{tenant: @acme, domain: AshBpmn.TenantTest.Domain}

      assert Scope.to_job_args(scope, %{"a" => 1}) == %{
               "a" => 1,
               "tenant" => @acme,
               "domain" => "Elixir.AshBpmn.TenantTest.Domain"
             }

      assert Scope.to_job_args(%Scope{}, %{"a" => 1}) == %{"a" => 1}
    end

    test "from_job/2 reads them back, with a named system actor" do
      args = Scope.to_job_args(%Scope{tenant: @acme, domain: AshBpmn.TenantTest.Domain}, %{})
      scope = Scope.from_job(args, :advance)

      assert scope.tenant == @acme
      assert scope.domain == "Elixir.AshBpmn.TenantTest.Domain"
      assert scope.actor == AshBpmn.SystemActor.advance()
    end
  end

  describe "DomainResolver" do
    test "resolves the domain a job names, not the first one configured" do
      resolved =
        AshBpmn.Runtime.DomainResolver.resolve!("Elixir.AshBpmn.TenantTest.Domain")

      assert resolved.instance == AshBpmn.TenantTest.Instance

      # Which is the point: the fallback would have answered with the *other*
      # domain, and advanced this instance against the untenanted tables.
      refute AshBpmn.Runtime.DomainResolver.resolve!().instance ==
               AshBpmn.TenantTest.Instance
    end

    test "an unknown domain is an error rather than a silent fallback" do
      assert_raise ArgumentError, ~r/no such domain/, fn ->
        AshBpmn.Runtime.DomainResolver.resolve!("Elixir.AshBpmn.NoSuchDomain")
      end
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────────

  defp published_definition!(key, tenant) do
    xml = File.read!("test/fixtures/linear.bpmn")

    defn =
      Definition.create!(
        %{key: key, name: "Test #{key}", xml: xml},
        Scope.engine(%Scope{tenant: tenant})
      )

    if defn.graph do
      AshBpmn.TestRepo.query!(
        "UPDATE tenant_bpmn_definitions SET status = 'published' WHERE id = $1",
        [Ecto.UUID.dump!(defn.id)]
      )

      Definition
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(id == ^defn.id)
      |> Ash.read_one!(Scope.engine(%Scope{tenant: tenant}))
    else
      raise "Definition #{key} failed to compile: #{inspect(defn.errors)}"
    end
  end

  # The test subject's `create!` returns an ok tuple rather than the record --
  # same shape the engine suite works around.
  defp subject!(name) do
    case AshBpmn.Test.Subject.create!(%{name: name, amount: 0, is_privileged: false}) do
      {:ok, subject} -> subject
      subject when is_map(subject) -> subject
    end
  end

  defp read!(resource, tenant, instance_id) do
    resource
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(instance_id == ^instance_id)
    |> Ash.read!(Scope.engine(%Scope{tenant: tenant}))
  end
end
