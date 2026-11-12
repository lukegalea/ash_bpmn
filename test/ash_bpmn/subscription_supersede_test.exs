# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.SupersedeTest.Subscription do
  @moduledoc """
  A host's subscription with a broad update grant: any person or agent may run any update
  action. That is the shape that used to open `:supersede`, because it is an update action
  like `:publish` and `:retire`.
  """

  use AshBpmn.Resources.Subscription,
    domain: AshBpmn.SupersedeTest.Domain,
    repo: AshBpmn.TestRepo,
    table: "tenant_bpmn_subscriptions",
    tenant?: true

  policies do
    policy action_type(:update) do
      authorize_if actor_attribute_equals(:person?, true)
      authorize_if actor_attribute_equals(:agent?, true)
    end
  end
end

defmodule AshBpmn.SupersedeTest.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshBpmn.SupersedeTest.Subscription
  end
end

defmodule AshBpmn.SubscriptionSupersedeTest do
  @moduledoc """
  `:supersede` is half of a publish, and only a publish reaches it.

  It retires a published version and stamps the boundary the sweep reads. Run on its own,
  it would retire a version nothing replaces, at a boundary the caller picked. A host that
  grants updates on subscriptions grants it too, unless the action itself refuses, so it
  does: whoever the host's policies admit, the engine's mark included, only the publish of
  the same key, inside its transaction, gets through.

  The refusals come first.
  """

  use AshBpmn.DataCase, async: false

  require Ash.Query

  alias AshBpmn.Resources.Subscription.SupersedeFromPublish
  alias AshBpmn.Scope
  alias AshBpmn.SupersedeTest.Subscription

  @acme Ecto.UUID.generate()
  @globex Ecto.UUID.generate()

  setup do
    previous_source = Application.get_env(:ash_bpmn, :event_source)
    Application.put_env(:ash_bpmn, :event_source, TriggerTest.EventSource)
    TriggerTest.EventSource.reset!()

    on_exit(fn ->
      if previous_source,
        do: Application.put_env(:ash_bpmn, :event_source, previous_source),
        else: Application.delete_env(:ash_bpmn, :event_source)
    end)

    :ok
  end

  describe "calling :supersede directly" do
    test "is refused to a person the host admits to every update" do
      published = published!(@acme)

      assert {:error, %Ash.Error.Invalid{} = error} =
               supersede(published, actor: person(), tenant: @acme)

      assert Exception.message(error) =~ "supersede is run by publish"
      assert reload!(published).status == :published
    end

    test "is refused to an agent the host admits to every update" do
      published = published!(@acme)

      assert {:error, %Ash.Error.Invalid{}} =
               supersede(published, actor: agent(), tenant: @acme)

      assert reload!(published).status == :published
    end

    test "is refused to a person inside a transaction of their own" do
      published = published!(@acme)

      {:ok, result} =
        AshBpmn.TestRepo.transaction(fn ->
          supersede(published, actor: person(), tenant: @acme)
        end)

      assert {:error, %Ash.Error.Invalid{}} = result
      assert reload!(published).status == :published
    end

    test "is refused to the engine's mark alone" do
      published = published!(@acme)

      assert {:error, %Ash.Error.Invalid{}} = supersede(published, engine(@acme))
      assert reload!(published).status == :published
    end

    test "is refused to a publish mark that names another key" do
      published = published!(@acme)
      opts = SupersedeFromPublish.mark(engine(@acme), "other_key", Ecto.UUID.generate())

      {:ok, result} = AshBpmn.TestRepo.transaction(fn -> supersede(published, opts) end)

      assert {:error, %Ash.Error.Invalid{}} = result
      assert reload!(published).status == :published
    end

    test "is refused to a publish mark that names the row itself" do
      published = published!(@acme)
      opts = SupersedeFromPublish.mark(engine(@acme), published.key, published.id)

      {:ok, result} = AshBpmn.TestRepo.transaction(fn -> supersede(published, opts) end)

      assert {:error, %Ash.Error.Invalid{}} = result
      assert reload!(published).status == :published
    end

    test "is refused to the publish mark outside a transaction" do
      published = published!(@acme)
      opts = SupersedeFromPublish.mark(engine(@acme), published.key, Ecto.UUID.generate())

      assert {:error, %Ash.Error.Invalid{}} = supersede(published, opts)
      assert reload!(published).status == :published
    end

    test "cannot take its boundary as public input, even with the publish's mark" do
      published = published!(@acme)
      opts = SupersedeFromPublish.mark(engine(@acme), published.key, Ecto.UUID.generate())

      {:ok, result} =
        AshBpmn.TestRepo.transaction(fn ->
          published
          |> Ash.Changeset.for_update(:supersede, %{retired_sequence: 1}, opts)
          |> Ash.update()
        end)

      assert {:error, %Ash.Error.Invalid{errors: errors}} = result
      assert Enum.any?(errors, &match?(%Ash.Error.Invalid.NoSuchInput{}, &1))
      assert reload!(published).status == :published
    end
  end

  describe "publishing the next version" do
    test "in another tenant leaves this tenant's version published" do
      acme_v1 = published!(@acme, "shared")
      _globex_v1 = published!(@globex, "shared")
      _globex_v2 = published!(@globex, "shared")

      assert %{status: :published, retired_sequence: nil} = reload!(acme_v1)
    end

    test "as the engine still retires the previous version at the boundary" do
      v1 = published!(@acme, "engine_rule")
      event = TriggerTest.EventSource.append!(@acme)

      v2 = published!(@acme, "engine_rule")

      assert %{status: :retired, retired_sequence: sequence} = reload!(v1)
      assert sequence == event.sequence
      assert v2.effective_sequence == event.sequence
    end

    test "as a person the host admits still retires the previous version" do
      v1 = published!(@acme, "person_rule")
      event = TriggerTest.EventSource.append!(@acme)

      draft = draft!(@acme, "person_rule")

      assert {:ok, v2} =
               draft
               |> Ash.Changeset.for_update(:publish, %{}, actor: person(), tenant: @acme)
               |> Ash.update()

      assert v2.status == :published
      assert v2.effective_sequence == event.sequence
      assert %{status: :retired, retired_sequence: sequence} = reload!(v1)
      assert sequence == event.sequence
    end
  end

  defp supersede(record, opts) do
    record
    |> Ash.Changeset.for_update(
      :supersede,
      %{},
      Keyword.put(opts, :private_arguments, %{retired_sequence: 1})
    )
    |> Ash.update()
  end

  defp person, do: %{id: Ecto.UUID.generate(), person?: true}
  defp agent, do: %{id: Ecto.UUID.generate(), agent?: true}

  defp engine(tenant), do: Scope.engine(%Scope{tenant: tenant})

  defp draft!(tenant, key) do
    Subscription
    |> Ash.Changeset.for_create(:create, %{
      key: key,
      match_resource: "TriggerTest.Payout",
      process_key: "p"
    })
    |> Ash.create!(engine(tenant))
  end

  defp published!(tenant, key \\ "rule_#{System.unique_integer([:positive])}") do
    tenant
    |> draft!(key)
    |> Ash.Changeset.for_update(:publish, %{})
    |> Ash.update!(engine(tenant))
  end

  defp reload!(record) do
    Subscription
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^record.id)
    |> Ash.read_one!(engine(record.organization_id))
  end
end
