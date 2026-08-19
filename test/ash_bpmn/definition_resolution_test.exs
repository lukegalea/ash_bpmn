# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.DefinitionResolutionTest do
  @moduledoc """
  Which definition an instance runs, and where that definition is read from.

  Both are host policy rather than engine policy, and both had been engine policy by accident:
  `start_instance/2` could only ever mean "the latest published definition for this key, in
  this tenant", and every advance re-read it in the instance's own tenant. That is correct for
  a single-tenant install and for any install where each tenant authors its own processes, and
  it is wrong the moment a host ships baseline processes centrally — the instance is the
  tenant's and the definition is not.

  These tests pin the seams that make the second case expressible, and pin that the default
  behaviour is unchanged for everyone who does not need them.
  """

  use AshBpmn.DataCase, async: false

  alias AshBpmn.Test.{Definition, Instance}

  @xml File.read!("test/fixtures/linear.bpmn")

  setup do
    AshBpmn.Test.Invoker.clear_calls()
    :ok
  end

  describe "which definition to run" do
    test "by process key, which is what every existing caller does" do
      defn = create_published_definition!("res_by_key", @xml)
      subject = create_test_subject!("res_by_key_subject")

      {:ok, instance} =
        AshBpmn.start_instance(AshBpmn.Test.Domain, process: "res_by_key", subject: subject)

      assert instance.definition_id == defn.id
    end

    # The option that makes a platform baseline reachable: the host has already decided which
    # definition this tenant should run, and hands it over rather than being asked to store it
    # somewhere the engine can find.
    test "by definition, handed over directly" do
      defn = create_published_definition!("res_by_defn", @xml)
      subject = create_test_subject!("res_by_defn_subject")

      {:ok, instance} =
        AshBpmn.start_instance(AshBpmn.Test.Domain, definition: defn, subject: subject)

      assert instance.definition_id == defn.id
    end

    test "by definition id" do
      defn = create_published_definition!("res_by_id", @xml)
      subject = create_test_subject!("res_by_id_subject")

      {:ok, instance} =
        AshBpmn.start_instance(AshBpmn.Test.Domain, definition_id: defn.id, subject: subject)

      assert instance.definition_id == defn.id
    end

    test "with none of the three, the error says so rather than raising somewhere downstream" do
      subject = create_test_subject!("res_none_subject")

      assert {:error, message} =
               AshBpmn.start_instance(AshBpmn.Test.Domain, subject: subject)

      assert message =~ ":process"
      assert message =~ ":definition"
    end

    test "an unknown definition id is an error, not a crash" do
      subject = create_test_subject!("res_bad_id_subject")

      assert {:error, message} =
               AshBpmn.start_instance(AshBpmn.Test.Domain,
                 definition_id: Ash.UUID.generate(),
                 subject: subject
               )

      assert message =~ "no definition with id"
    end

    # The instance pins whatever it was given. This is the property the whole versioning design
    # rests on, and it must not depend on *how* the definition was chosen.
    test "the instance records the key of the definition it was given, not the caller's argument" do
      defn = create_published_definition!("res_key_recorded", @xml)
      subject = create_test_subject!("res_key_recorded_subject")

      {:ok, instance} =
        AshBpmn.start_instance(AshBpmn.Test.Domain, definition: defn, subject: subject)

      [event] = process_events(instance.id, :instance_started)
      assert event.data["process_key"] == "res_key_recorded"
    end
  end

  describe "correlation" do
    # The attribute and the accept list had both existed since the resource was written; only
    # the plumbing was missing, so every process was an orphan in the host's trace.
    test "a correlation id supplied at start lands on the instance" do
      _defn = create_published_definition!("res_correlation", @xml)
      subject = create_test_subject!("res_correlation_subject")

      {:ok, instance} =
        AshBpmn.start_instance(AshBpmn.Test.Domain,
          process: "res_correlation",
          subject: subject,
          correlation_id: "corr-abc-123"
        )

      {:ok, reloaded} = fetch_instance(instance.id)
      assert reloaded.correlation_id == "corr-abc-123"
    end

    test "no correlation id is a normal state, not an error" do
      _defn = create_published_definition!("res_no_correlation", @xml)
      subject = create_test_subject!("res_no_correlation_subject")

      {:ok, instance} =
        AshBpmn.start_instance(AshBpmn.Test.Domain,
          process: "res_no_correlation",
          subject: subject
        )

      {:ok, reloaded} = fetch_instance(instance.id)
      assert is_nil(reloaded.correlation_id)
    end
  end

  describe "where the definition is read from" do
    test "the default loader reads it in the instance's own scope" do
      defn = create_published_definition!("res_loader_default", @xml)
      subject = create_test_subject!("res_loader_default_subject")

      {:ok, instance} =
        AshBpmn.start_instance(AshBpmn.Test.Domain,
          process: "res_loader_default",
          subject: subject
        )

      scope = AshBpmn.Scope.from_record(instance, [])

      assert {:ok, loaded} =
               AshBpmn.DefinitionLoader.Default.load(Definition, defn.id, instance, scope)

      assert loaded.id == defn.id
    end

    # A loader must return the definition the instance *pinned*. Returning the latest version
    # of that key instead would silently migrate a running instance onto a definition it was
    # never verified against, which is the one thing the versioning design exists to prevent.
    test "a failing loader raises with an explanation rather than a nil graph downstream" do
      defmodule RefusingLoader do
        @behaviour AshBpmn.DefinitionLoader
        @impl true
        def load(_resource, _id, _instance, _scope), do: {:error, :nope}
      end

      previous = Application.get_env(:ash_bpmn, :definition_loader)
      Application.put_env(:ash_bpmn, :definition_loader, RefusingLoader)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:ash_bpmn, :definition_loader, previous),
          else: Application.delete_env(:ash_bpmn, :definition_loader)
      end)

      assert_raise RuntimeError, ~r/could not load definition/, fn ->
        AshBpmn.DefinitionLoader.load!(
          Definition,
          Ash.UUID.generate(),
          %{id: "i"},
          %AshBpmn.Scope{}
        )
      end
    end

    test "the configured loader is used, so a host can reach outside the instance's tenant" do
      defmodule CountingLoader do
        @behaviour AshBpmn.DefinitionLoader
        @impl true
        def load(resource, id, instance, scope) do
          send(self(), {:loader_called, id})
          AshBpmn.DefinitionLoader.Default.load(resource, id, instance, scope)
        end
      end

      previous = Application.get_env(:ash_bpmn, :definition_loader)
      Application.put_env(:ash_bpmn, :definition_loader, CountingLoader)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:ash_bpmn, :definition_loader, previous),
          else: Application.delete_env(:ash_bpmn, :definition_loader)
      end)

      defn = create_published_definition!("res_loader_custom", @xml)
      subject = create_test_subject!("res_loader_custom_subject")

      {:ok, _instance} =
        AshBpmn.start_instance(AshBpmn.Test.Domain,
          process: "res_loader_custom",
          subject: subject
        )

      assert_received {:loader_called, id}
      assert id == defn.id
    end
  end

  defp create_published_definition!(key, xml) do
    defn = Definition.create!(%{key: key, name: "Test #{key}", xml: xml})

    if defn.graph do
      AshBpmn.TestRepo.query!(
        "UPDATE bpmn_definitions SET status = 'published' WHERE id = '#{defn.id}'"
      )

      Definition.by_key_version!(defn.key, defn.version)
    else
      raise "Definition #{key} failed to compile: #{inspect(defn.errors)}"
    end
  end

  defp create_test_subject!(name) do
    case AshBpmn.Test.Subject.create!(%{name: name, amount: 0, is_privileged: false}) do
      {:ok, subject} -> subject
      subject when is_map(subject) -> subject
    end
  end

  defp fetch_instance(id) do
    require Ash.Query

    instance =
      Instance
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(id == ^id)
      |> Ash.read_one!(authorize?: false)

    {:ok, instance}
  end

  defp process_events(instance_id, kind) do
    require Ash.Query

    AshBpmn.Test.ProcessEvent
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(instance_id == ^instance_id)
    |> Ash.Query.filter(kind == ^kind)
    |> Ash.read!(authorize?: false)
  end
end
