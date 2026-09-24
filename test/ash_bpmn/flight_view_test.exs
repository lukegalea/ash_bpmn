# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.FlightViewTest do
  @moduledoc """
  The three flight-view APIs: the mermaid rendering, the token positions query,
  and the token-movement broadcast.

  The mermaid output is pinned byte for byte for one fixture — the fastest way to
  notice an accidental change to what hosts render — and structurally checked for
  the others: every edge endpoint must be a declared node id, and every element
  id of the graph must appear verbatim, because the host positions its overlays
  by those ids and a silent rename would hang avatars over the wrong boxes.

  The broadcast tests subscribe *before* the engine runs, which is only possible
  because the inline Oban shim executes advances in the test's own process: the
  broadcast is synchronous with the write, so `assert_received/1` sees every
  payload by the time `start_instance` has returned, in the order the engine
  wrote it.
  """

  use AshBpmn.DataCase, async: false

  require Ash.Query

  alias AshBpmn.FlightView
  alias AshBpmn.Runtime.Oban.TestJobs
  alias AshBpmn.Test.{Definition, Domain, HumanTask}

  @position_keys ~w(instance_id instance_status definition_id definition_key definition_version
      subject_type subject_id correlation_id started_by_id tenant_id
      token_id node_id node_type node_name status parked_at token_created_at)a

  @payload_keys ~w(event token_id instance_id definition_id node_id status
      subject_type subject_id correlation_id instance_status tenant_id moved_at)

  setup do
    AshBpmn.Test.Invoker.clear_calls()
    TestJobs.clear()
    :ok
  end

  # ── mermaid ──────────────────────────────────────────────────────────────

  describe "mermaid" do
    test "renders the linear process byte for byte" do
      graph = compile!("test/fixtures/linear.bpmn")

      assert FlightView.mermaid!(graph) == """
             flowchart TD
             End_1((("End")))
             Service_1["Do something"]
             Start_1(["Start"])
             Service_1 --> End_1
             Start_1 --> Service_1
             """
    end

    test "renders every executable element of the gateway process, and round-trips the ids" do
      graph = compile!("test/fixtures/exclusive.bpmn")
      mermaid = FlightView.mermaid!(graph)

      for id <- Map.keys(graph["nodes"]) do
        # The overlay contract: the host finds each element in the rendered
        # diagram by the element's own id.
        assert mermaid =~ id
      end

      assert mermaid =~ ~s{Gateway_1 -->|"subject.amount > 100"| Task_A}
      assert mermaid =~ ~s{Gateway_1 -->|"default"| Task_B}
      assert mermaid =~ ~s{Start_1(["Start"])}
      assert mermaid =~ ~s{End_1((("End")))}

      assert %{nodes: nodes, edges: edges} = lint!(mermaid)
      assert MapSet.subset?(MapSet.new(Map.keys(graph["nodes"])), nodes)

      for {from, to} <- edges do
        assert MapSet.member?(nodes, from) and MapSet.member?(nodes, to),
               "edge #{from} -> #{to} references an undeclared node"
      end
    end

    test "draws boundary events attached to their activity by a dotted edge" do
      graph = compile!("test/fixtures/boundary_timer.bpmn")
      mermaid = FlightView.mermaid!(graph)

      assert mermaid =~ "Approve_1 -.-> Boundary_1"
      assert mermaid =~ ~s{Boundary_1(("Too slow"))}
    end

    test "the same graph renders identically every time" do
      graph = compile!("test/fixtures/access_request.bpmn")

      assert FlightView.mermaid!(graph) == FlightView.mermaid!(graph)
    end

    test "accepts a definition record as well as a bare graph" do
      {definition, _instance, _subject} = start_unprivileged_request!("flight_record")

      assert FlightView.mermaid!(definition) == FlightView.mermaid!(definition.graph)
    end

    test "a definition that never compiled has no diagram, and says so" do
      assert FlightView.mermaid(%{graph: nil}) == {:error, :no_graph}
      assert FlightView.mermaid(%{graph: %{}}) == {:error, :no_graph}

      assert_raise ArgumentError, ~r/needs a compiled graph/, fn ->
        FlightView.mermaid!(%{graph: nil})
      end
    end

    test "ids mermaid cannot carry are sanitized deterministically" do
      graph = %{
        "nodes" => %{
          "end" => %{"type" => "endEvent", "name" => "Done"},
          "my node id!" => %{"type" => "userTask", "name" => ~s(Say "ah")},
          "Start_1" => %{"type" => "startEvent", "name" => "Start"}
        },
        "flows" => %{
          "f1" => %{"from" => "Start_1", "to" => "my node id!"},
          "f2" => %{"from" => "my node id!", "to" => "end"}
        }
      }

      mermaid = FlightView.mermaid!(graph)

      # The reserved word `end` cannot be parsed by mermaid at all, so it is
      # renamed by a documented rule; unsafe characters become underscores and
      # an `n_` prefix keeps the id from starting with a digit.
      assert mermaid =~ "node_end((("
      assert mermaid =~ ~s{n_my_node_id_["Say #quot;ah#quot;"]}

      assert %{nodes: nodes, edges: edges} = lint!(mermaid)

      for {from, to} <- edges do
        assert MapSet.member?(nodes, from) and MapSet.member?(nodes, to)
      end
    end
  end

  # ── token positions ──────────────────────────────────────────────────────

  describe "token positions" do
    test "reports the parked token of an advanced instance, with the subject passthrough" do
      {definition, instance, subject} = start_unprivileged_request!("flight_positions")

      assert [entry] = FlightView.token_positions!(Domain, definition: definition)

      # The shape is a contract with hosts; pin it so an accidental change to
      # the payload is a failing test rather than a silent breaking release.
      assert MapSet.new(Map.keys(entry)) == MapSet.new(@position_keys)

      assert entry.instance_id == instance.id
      assert entry.instance_status == "running"
      assert entry.definition_id == definition.id
      assert entry.definition_key == "flight_positions"
      assert entry.definition_version == definition.version
      assert entry.subject_type == "Elixir.AshBpmn.Test.Subject"
      assert entry.subject_id == subject.id
      assert entry.correlation_id == nil
      assert entry.tenant_id == nil
      assert entry.node_id == "ManagerApproval"
      assert entry.node_type == "userTask"
      assert entry.node_name == "Manager approval"
      assert entry.status == "waiting"
      assert entry.parked_at
      assert entry.token_created_at
    end

    test "narrowing by definition, definition_id and definition_key agree" do
      {definition, _instance, _subject} = start_unprivileged_request!("flight_narrow")

      by_record = FlightView.token_positions!(Domain, definition: definition)
      by_id = FlightView.token_positions!(Domain, definition_id: definition.id)
      by_key = FlightView.token_positions!(Domain, definition_key: "flight_narrow")

      assert by_record == by_id
      assert by_record == by_key
      assert by_record != []
    end

    test "completed instances leave the default view and can be asked for explicitly" do
      {definition, instance, _subject} = start_unprivileged_request!("flight_done")
      approve!(instance)

      assert FlightView.token_positions!(Domain, definition: definition) == []

      everything =
        FlightView.token_positions!(Domain,
          definition: definition,
          instance_statuses: [:running, :completed, :failed, :errored, :cancelled, :superseded],
          token_statuses: [:active, :executing, :waiting, :consumed, :dead]
        )

      # Every token the instance ever had is visible, each finished the way the
      # engine finishes branches — consumed at an end, or dead at a starved
      # join — and the instance itself reads as what it is now.
      assert everything != []

      assert Enum.all?(everything, fn entry ->
               entry.instance_id == instance.id and
                 entry.instance_status == "completed" and
                 entry.status in ["consumed", "dead"]
             end)

      assert Enum.any?(everything, &(&1.node_id == "End_approved"))
    end

    test "restricting by instance_ids returns only those instances' tokens" do
      {definition, instance, _subject} = start_unprivileged_request!("flight_ids")

      assert [entry] =
               FlightView.token_positions!(Domain,
                 definition: definition,
                 instance_ids: [instance.id]
               )

      assert entry.instance_id == instance.id

      assert FlightView.token_positions!(Domain,
               definition: definition,
               instance_ids: [Ash.UUID.generate()]
             ) == []
    end
  end

  # ── live updates ─────────────────────────────────────────────────────────

  describe "live updates with a PubSub" do
    setup do
      start_supervised!(
        {Phoenix.PubSub, name: AshBpmn.Web.TestPubSub, adapter: Phoenix.PubSub.PG2}
      )

      :ok
    end

    test "token movement is broadcast on advance, on the definition topic" do
      xml = File.read!("test/fixtures/access_request.bpmn")
      definition = create_published_definition!("flight_live", xml)
      subject = create_test_subject!("flight_live", is_privileged: false)

      # Subscribed before the instance exists, so the start's own movement is
      # captured — the property a real flight view depends on.
      :ok = FlightView.subscribe(FlightView.definition_topic(definition.id))

      {:ok, instance} = AshBpmn.start_instance(Domain, process: "flight_live", subject: subject)

      # The advance runs inline in this process, so every hop of the start is
      # already in the mailbox, in the order the engine wrote it. Note the
      # shape of a hop: the new token's creation is announced before the token
      # it came from is retired — the engine creates forward before it
      # consumes behind — and a park is announced as `waiting`, the state the
      # view holds until a human decides.
      sequence = drain_payloads()

      assert [
               %{"node_id" => "Start_1", "status" => "active"} = first,
               %{"node_id" => "Start_1", "status" => "executing"},
               %{"node_id" => "Validate", "status" => "active"},
               %{"node_id" => "Start_1", "status" => "consumed"},
               %{"node_id" => "Validate", "status" => "executing"},
               %{"node_id" => "PrivilegedGateway", "status" => "active"},
               %{"node_id" => "Validate", "status" => "consumed"},
               %{"node_id" => "PrivilegedGateway", "status" => "executing"},
               %{"node_id" => "ManagerApproval", "status" => "active"},
               %{"node_id" => "PrivilegedGateway", "status" => "consumed"},
               %{"node_id" => "ManagerApproval", "status" => "executing"},
               %{
                 "node_id" => "ManagerApproval",
                 "status" => "waiting",
                 "subject_type" => "Elixir.AshBpmn.Test.Subject",
                 "tenant_id" => nil
               } = waiting
             ] = sequence

      assert first["instance_id"] == instance.id
      assert first["definition_id"] == definition.id
      assert first["subject_id"] == subject.id
      assert {:ok, _, _} = waiting["moved_at"] |> DateTime.from_iso8601()

      # The payload shape is a contract; an added key is a new version of the
      # subscription, not a surprise.
      assert MapSet.new(Map.keys(waiting)) == MapSet.new(@payload_keys)

      FlightView.unsubscribe(FlightView.definition_topic(definition.id))
    end

    test "movement reaches the per-instance topic until the case clears the diagram" do
      {definition, instance, _subject} = start_unprivileged_request!("flight_instance")

      # The start's own broadcasts went to a topic nobody was subscribed to
      # yet; from here the instance topic carries the rest of the life of the
      # case, decision through completion.
      :ok = FlightView.subscribe(FlightView.instance_topic(instance.id))

      approve!(instance)

      # The claim out of the park is movement too, then the branch runs on —
      # again creation announced ahead of the retirement behind it. The
      # starved join's token dies and its continuation is minted straight
      # past it, and the case runs to its end.
      sequence =
        drain_payloads()

      assert [
               %{"node_id" => "ManagerApproval", "status" => "executing"},
               %{"node_id" => "ManagerApproval", "status" => "consumed"},
               %{"node_id" => "MgrDecision", "status" => "active"},
               %{"node_id" => "MgrDecision", "status" => "executing"},
               %{"node_id" => "Join_1", "status" => "active"},
               %{"node_id" => "MgrDecision", "status" => "consumed"},
               %{"node_id" => "Join_1", "status" => "executing"},
               %{"node_id" => "Join_1", "status" => "dead"},
               %{"node_id" => "Provision", "status" => "executing"},
               %{"node_id" => "End_approved", "status" => "active"},
               %{"node_id" => "Provision", "status" => "consumed"},
               %{"node_id" => "End_approved", "status" => "executing"},
               %{
                 "node_id" => "End_approved",
                 "status" => "consumed",
                 "instance_status" => "running"
               } = last
             ] = sequence

      # The last consumption is what tells the view to clear its markers, and
      # it still reports the instance as running: the completion is a separate
      # write, and the view re-queries for the authoritative status.
      assert last["instance_status"] == "running"

      assert FlightView.token_positions!(Domain, definition: definition) == []
    end
  end

  describe "without a running PubSub" do
    test "the engine advances, and subscribe reports the configuration" do
      {_definition, _instance, _subject} = start_unprivileged_request!("flight_quiet")

      # No PubSub process in this test, which is the state every non-web test
      # runs in: the engine must still advance.
      assert Process.whereis(AshBpmn.Web.TestPubSub) == nil

      assert {:ok, positions} =
               FlightView.token_positions(Domain, definition_key: "flight_quiet")

      assert length(positions) == 1

      assert FlightView.subscribe(FlightView.definition_topic(Ash.UUID.generate())) ==
               {:error, :pubsub_not_running}
    end

    test "subscribe without a configured PubSub is an error, not a crash" do
      Application.put_env(:ash_bpmn, :pubsub_server, nil)
      on_exit(fn -> Application.put_env(:ash_bpmn, :pubsub_server, AshBpmn.Web.TestPubSub) end)

      assert FlightView.subscribe(FlightView.definition_topic(Ash.UUID.generate())) ==
               {:error, :pubsub_not_configured}

      assert FlightView.unsubscribe("bpmn:tokens:instance:nope") ==
               {:error, :pubsub_not_configured}
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp compile!(fixture) do
    xml = File.read!(fixture)

    case AshBpmn.Compiler.compile(xml) do
      {:ok, graph} -> graph
      {:error, errors} -> raise "fixture #{fixture} does not compile: #{inspect(errors)}"
    end
  end

  defp start_unprivileged_request!(key) do
    xml = File.read!("test/fixtures/access_request.bpmn")
    definition = create_published_definition!(key, xml)
    subject = create_test_subject!(key, is_privileged: false)

    {:ok, instance} =
      AshBpmn.start_instance(Domain, process: key, subject: subject)

    {definition, instance, subject}
  end

  defp approve!(instance) do
    task = fetch_task!(instance.id, "ManagerApproval")

    {:ok, _} =
      AshBpmn.complete_task(task, outcome: :approved, actor: %{id: Ash.UUID.generate()})
  end

  defp fetch_task!(instance_id, node_id) do
    HumanTask
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(instance_id == ^instance_id and node_id == ^node_id)
    |> Ash.read_one!(authorize?: false)
    |> case do
      nil -> raise "no task at #{node_id} for instance #{instance_id}"
      task -> task
    end
  end

  defp create_published_definition!(key, xml) do
    defn =
      Definition.create!(%{
        key: key,
        name: "Test #{key}",
        xml: xml
      })

    if defn.graph do
      AshBpmn.TestRepo.query!(
        "UPDATE bpmn_definitions SET status = 'published' WHERE id = '#{defn.id}'"
      )

      Definition.by_key_version!(defn.key, defn.version)
    else
      raise "Definition #{key} failed to compile: #{inspect(defn.errors)}"
    end
  end

  defp create_test_subject!(name, overrides \\ []) do
    attrs = %{
      name: name,
      amount: Keyword.get(overrides, :amount, 0),
      is_privileged: Keyword.get(overrides, :is_privileged, false)
    }

    case AshBpmn.Test.Subject.create!(attrs) do
      {:ok, subject} -> subject
      subject when is_map(subject) -> subject
    end
  end

  # Every movement the engine has announced, oldest first.
  defp drain_payloads(acc \\ []) do
    receive do
      msg -> drain_payloads([msg | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # ── a mermaid lint small enough to trust ──────────────────────────────────
  #
  # There is no mermaid parser in this test suite, so "valid mermaid" is
  # asserted structurally: a direction header, one node declaration per line
  # with a renderable id, edges in one of the three shapes the renderer emits,
  # and — asserted by the callers — every edge endpoint declared. Drift in the
  # renderer's line shapes breaks the lint rather than shipping a diagram hosts
  # cannot parse.

  @header ~r/^flowchart \w{2}$/
  @edge_plain ~r/^(\S+) --> (\S+)$/
  @edge_label ~r/^(\S+) -->\|"[^"]*"\| (\S+)$/
  @edge_dotted ~r/^(\S+) -\.-> (\S+)$/
  @node_decl ~r/^(\w+)(\(\(\(|\(\[|\(\(|\[\[|\{|\[)"/

  defp lint!(mermaid) do
    [header | rest] =
      mermaid |> String.split("\n") |> Enum.reject(&(&1 == ""))

    unless header =~ @header, do: raise("bad mermaid header: #{inspect(header)}")

    Enum.reduce(rest, %{nodes: MapSet.new(), edges: []}, fn line, acc ->
      cond do
        edge = match_edge(line) ->
          %{acc | edges: [edge | acc.edges]}

        id = match_node(line) ->
          unless Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_]*$/, id) do
            raise("unrenderable node id in output: #{inspect(line)}")
          end

          %{acc | nodes: MapSet.put(acc.nodes, id)}

        true ->
          raise("unparseable mermaid line: #{inspect(line)}")
      end
    end)
  end

  defp match_edge(line) do
    cond do
      caps = Regex.run(@edge_plain, line) -> {Enum.at(caps, 1), Enum.at(caps, 2)}
      caps = Regex.run(@edge_label, line) -> {Enum.at(caps, 1), Enum.at(caps, 2)}
      caps = Regex.run(@edge_dotted, line) -> {Enum.at(caps, 1), Enum.at(caps, 2)}
      true -> nil
    end
  end

  defp match_node(line) do
    case Regex.run(@node_decl, line) do
      [_, id, _shape] -> id
      nil -> nil
    end
  end
end
