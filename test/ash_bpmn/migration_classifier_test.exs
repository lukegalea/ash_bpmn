# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.MigrationClassifierTest do
  @moduledoc """
  Deciding what an upgrade does to the instances already running.

  These tests are built from real compiled graphs — two variants of a shipped fixture, put
  through `AshBpmn.Compiler` — rather than from handwritten digests, because the property
  being asserted is that *the compiler's own notion of a changed element* and *the
  classifier's* agree. A test that asserted against transcribed digests would keep passing
  after the graph shape changed underneath it, which is the one thing it exists to catch.

  The instance and token rows are constructed in memory. They are exported documents, not
  database rows, and the classifier's contract is with the document; requiring Postgres for
  every case would make the interesting ones — a node deleted, an engine swapped — awkward to
  set up and slow to run, which is how they end up not being written.
  """

  use ExUnit.Case, async: true

  alias AshBpmn.Migration.Classifier
  alias AshBpmn.StateExport

  @exclusive "test/fixtures/exclusive.bpmn"
  @message_catch "test/fixtures/message_catch.bpmn"
  @call_parent "test/fixtures/call_parent.bpmn"

  describe "an unchanged definition" do
    test "is safe to continue, and says why in one reason rather than none" do
      source = entry!(@exclusive, 1)
      target = %{entry!(@exclusive, 2) | "graph_digest" => source["graph_digest"]}

      report = classify(source, target, [token("Gateway_1")])

      assert verdict(report) == "safe_to_continue"
      assert codes(report) == ["definition_unchanged"]
      assert report["summary"]["safe_to_continue"] == 1
    end

    test "a rename is an unchanged definition as far as any token is concerned" do
      source = entry!(@exclusive, 1)
      target = variant!(@exclusive, 2, ~s(name="Task A"), ~s(name="Task Alpha"))

      report = classify(source, target, [token("Gateway_1"), token("Task_A")])

      assert verdict(report) == "safe_to_continue"
    end

    test "a change somewhere no token is standing does not disturb the ones that are" do
      # The point of scoping to occupancy. Editing what happens after Task_B is usually the
      # reason for the migration; a token parked before it has not reached that yet.
      source = entry!(@exclusive, 1)
      target = variant!(@exclusive, 2, ~s(action="task_b"), ~s(action="task_b_v2"))

      assert verdict(classify(source, target, [token("Task_A")])) == "safe_to_continue"
      assert verdict(classify(source, target, [token("Task_B")])) == "needs_restart"
    end
  end

  describe "needs_restart" do
    test "a rewritten gateway condition under the token standing on the gateway" do
      source = entry!(@exclusive, 1)
      target = variant!(@exclusive, 2, "subject.amount > 100", "subject.amount > 500")

      report = classify(source, target, [token("Gateway_1")])

      assert verdict(report) == "needs_restart"
      assert "outgoing_flows_changed" in codes(report)
    end

    test "a service task whose action changed under the token executing it" do
      source = entry!(@exclusive, 1)
      target = variant!(@exclusive, 2, ~s(action="task_a"), ~s(action="task_a_v2"))

      report = classify(source, target, [token("Task_A", status: "executing")])

      assert verdict(report) == "needs_restart"
      assert "node_config_changed" in codes(report)
    end

    test "a moved start event, which no token owns" do
      source = entry!(@exclusive, 1)
      target = altered(entry!(@exclusive, 2), &Map.put(&1, "start", "Start_2"))

      report = classify(source, target, [token("Task_A")])

      assert verdict(report) == "needs_restart"
      assert "start_node_changed" in codes(report)
    end
  end

  describe "needs_manual_attention" do
    test "the node a token is standing on is gone" do
      source = entry!(@exclusive, 1)

      target =
        altered(
          entry!(@exclusive, 2),
          &update_in(&1["elements"], fn e -> Map.delete(e, "Task_A") end)
        )

      report = classify(source, target, [token("Task_A")])

      assert verdict(report) == "needs_manual_attention"
      assert "node_missing_in_target" in codes(report)
    end

    test "a parked wait that the target would never produce the signature for" do
      # The failure this module exists to catch. The signature was frozen onto the token at
      # park; the correlator matches on exactly that string; a target that parks on a
      # different one leaves the token unwakeable for the life of the instance, silently.
      source = entry!(@message_catch, 1)
      target = variant!(@message_catch, 2, ~s(resource="payment"), ~s(resource="settlement"))

      report =
        classify(source, target, [
          token("AwaitPayment",
            status: "waiting",
            waiting: %{
              "subscription_signature" => "message:payment:create",
              "correlation_key_digest" => "sha256:deadbeefdeadbeefdeadbeefdeadbeef",
              "children" => []
            }
          )
        ])

      assert verdict(report) == "needs_manual_attention"
      assert "wait_signature_changed" in codes(report)
    end

    test "a rewritten correlate expression, which invalidates every key already frozen" do
      # The signature is unchanged here — same resource, same action — so a signature check
      # alone would call this safe. What moved is the expression the frozen key was computed
      # from, which lives on the node while the key lives on the row.
      source = entry!(@message_catch, 1)

      target =
        variant!(@message_catch, 2, ~s(correlate="subject.id"), ~s(correlate="subject.name"))

      report =
        classify(source, target, [
          token("AwaitPayment",
            status: "waiting",
            waiting: %{
              "subscription_signature" => "message:payment:create",
              "correlation_key_digest" => "sha256:deadbeefdeadbeefdeadbeefdeadbeef",
              "children" => []
            }
          )
        ])

      assert verdict(report) == "needs_manual_attention"
      assert "correlation_basis_changed" in codes(report)
    end

    test "a node that stops parking at all while a token is parked on it" do
      source = entry!(@message_catch, 1)

      target =
        altered(
          entry!(@message_catch, 2),
          &put_in(&1["elements"]["AwaitPayment"]["wait"], nil)
        )

      report =
        classify(source, target, [
          token("AwaitPayment", status: "waiting", waiting: %{"children" => []})
        ])

      assert verdict(report) == "needs_manual_attention"
      assert "wait_removed" in codes(report)
    end

    test "a call activity pointed at a different process than the child already running" do
      source = entry!(@call_parent, 1)
      target = variant!(@call_parent, 2, ~s(key="CHILD_KEY"), ~s(key="OTHER_KEY"))

      report =
        classify(source, target, [
          token("Onboard", status: "waiting", waiting: %{"children" => []})
        ])

      assert verdict(report) == "needs_manual_attention"
      assert "call_process_key_changed" in codes(report)
    end
  end

  describe "unknown, with the reason attached" do
    test "no target definition was supplied for the key" do
      report =
        Classifier.classify(export(entry!(@exclusive, 1), [token("Task_A")]), [])

      assert verdict(report) == "unknown"
      assert codes(report) == ["target_definition_missing"]
      assert hd(report["instances"])["reasons"] |> hd() |> Map.get("detail") =~ "no target"
    end

    test "the export carries no definition for the instance" do
      base = export(entry!(@exclusive, 1), [token("Task_A")])
      orphaned = %{base | "definitions" => []}

      report = Classifier.classify(orphaned, [entry!(@exclusive, 2)])

      assert verdict(report) == "unknown"
      assert codes(report) == ["source_definition_missing"]
    end

    test "the token stands on a node the pinned graph does not have" do
      source = entry!(@exclusive, 1)
      target = variant!(@exclusive, 2, ~s(action="task_a"), ~s(action="task_a_v2"))
      report = classify(source, target, [token("Task_Nonexistent")])

      assert verdict(report) == "unknown"
      assert "node_missing_in_source" in codes(report)
    end

    test "a running instance with no live tokens" do
      source = entry!(@exclusive, 1)
      target = variant!(@exclusive, 2, ~s(action="task_a"), ~s(action="task_a_v2"))

      report = classify(source, target, [])

      assert verdict(report) == "unknown"
      assert "no_live_tokens" in codes(report)
    end

    test "the FEEL engine changed under a node that routes on a condition" do
      # Conditions are stored as source text and re-evaluated by whatever engine is
      # installed, which is what lets an in-flight instance survive an engine upgrade — and
      # also means the engine can change how a gateway routes without changing the graph.
      source = entry!(@exclusive, 1)

      target =
        altered(
          entry!(@exclusive, 2),
          &Map.put(&1, "feel_engine", %{"name" => "boxic_feel", "version" => "9.9.9"})
        )

      assert verdict(classify(source, target, [token("Gateway_1")])) == "unknown"
      assert "feel_engine_changed" in codes(classify(source, target, [token("Gateway_1")]))

      # And not for a token standing somewhere with no condition to re-evaluate.
      assert verdict(classify(source, target, [token("Task_A")])) == "safe_to_continue"
    end

    test "an export from a future format version is not guessed at" do
      base = export(entry!(@exclusive, 1), [token("Task_A")])
      future = %{base | "format_version" => 99}

      report = Classifier.classify(future, [entry!(@exclusive, 2)])

      assert verdict(report) == "unknown"
      assert codes(report) == ["export_format_unsupported"]
      assert report["source_format_version"] == 99
    end
  end

  describe "severity and ordering" do
    test "a definite restart outranks an undecidable token in the same instance" do
      # Restarting the instance disposes of both, so the actionable answer wins. The
      # undecidable one is still reported.
      source = entry!(@exclusive, 1)
      target = variant!(@exclusive, 2, ~s(action="task_a"), ~s(action="task_a_v2"))

      report = classify(source, target, [token("Task_A"), token("Task_Nonexistent")])

      assert verdict(report) == "needs_restart"
      assert "node_missing_in_source" in codes(report)
    end

    test "manual attention outranks everything else" do
      source = entry!(@exclusive, 1)

      target =
        @exclusive
        |> variant!(2, ~s(action="task_a"), ~s(action="task_a_v2"))
        |> altered(&update_in(&1["elements"], fn e -> Map.delete(e, "Task_B") end))

      report = classify(source, target, [token("Task_A"), token("Task_B")])

      assert verdict(report) == "needs_manual_attention"
      assert "node_config_changed" in codes(report)
      assert "node_missing_in_target" in codes(report)
    end

    test "the summary counts every verdict, including the ones at zero" do
      source = entry!(@exclusive, 1)
      report = classify(source, entry!(@exclusive, 2), [token("Task_A")])

      assert Map.keys(report["summary"]) |> Enum.sort() ==
               Enum.sort(Classifier.verdicts())

      assert report["summary"]["needs_restart"] == 0
    end
  end

  describe "children" do
    test "a parent cannot be moved past a child that cannot" do
      parent_def = entry!(@call_parent, 1)
      child_def = entry!(@exclusive, 1)
      child_id = Ash.UUID.generate()

      parent_token =
        token("Onboard",
          status: "waiting",
          waiting: %{
            "children" => [
              %{"instance_id" => child_id, "definition_key" => "exclusive", "status" => "running"}
            ]
          }
        )

      export = %{
        base_export()
        | "definitions" => [parent_def, child_def],
          "instances" => [
            instance(parent_def, [parent_token]),
            %{instance(child_def, [token("Task_A")]) | "id" => child_id}
          ]
      }

      # The child's Task_A is deleted in the target, so the child needs manual attention; the
      # parent's own call activity is untouched.
      targets = [
        entry!(@call_parent, 2),
        altered(
          entry!(@exclusive, 2),
          &update_in(&1["elements"], fn e -> Map.delete(e, "Task_A") end)
        )
      ]

      report = Classifier.classify(export, targets)

      parent_verdict =
        Enum.find(report["instances"], &(&1["definition_key"] == parent_def["key"]))

      assert parent_verdict["classification"] == "needs_manual_attention"
      assert "child_needs_attention" in Enum.map(parent_verdict["reasons"], & &1["code"])
    end

    test "a child outside the export is named rather than assumed fine" do
      parent_def = entry!(@call_parent, 1)

      parent_token =
        token("Onboard",
          status: "waiting",
          waiting: %{
            "children" => [
              %{
                "instance_id" => Ash.UUID.generate(),
                "definition_key" => "x",
                "status" => "running"
              }
            ]
          }
        )

      export = %{
        base_export()
        | "definitions" => [parent_def],
          "instances" => [instance(parent_def, [parent_token])]
      }

      report = Classifier.classify(export, [entry!(@call_parent, 2)])

      assert verdict(report) == "unknown"
      assert "child_not_classified" in codes(report)
    end

    test "a child that is safe leaves the parent alone" do
      parent_def = entry!(@call_parent, 1)
      child_def = entry!(@exclusive, 1)
      child_id = Ash.UUID.generate()

      parent_token =
        token("Onboard",
          status: "waiting",
          waiting: %{
            "children" => [
              %{"instance_id" => child_id, "definition_key" => "exclusive", "status" => "running"}
            ]
          }
        )

      export = %{
        base_export()
        | "definitions" => [parent_def, child_def],
          "instances" => [
            instance(parent_def, [parent_token]),
            %{instance(child_def, [token("Task_A")]) | "id" => child_id}
          ]
      }

      report = Classifier.classify(export, [entry!(@call_parent, 2), entry!(@exclusive, 2)])

      assert Enum.all?(report["instances"], &(&1["classification"] == "safe_to_continue"))
    end
  end

  describe "picking a target version" do
    test "the highest version wins when nothing is pinned" do
      source = entry!(@exclusive, 1)
      v2 = variant!(@exclusive, 2, ~s(action="task_a"), ~s(action="v2"))
      v3 = entry!(@exclusive, 3)

      report =
        Classifier.classify(export(source, [token("Task_A")]), [v2, v3])

      assert hd(report["instances"])["to_version"] == 3
      assert verdict(report) == "safe_to_continue"
    end

    test "to_versions pins the one that is actually being moved to" do
      source = entry!(@exclusive, 1)
      v2 = variant!(@exclusive, 2, ~s(action="task_a"), ~s(action="v2"))
      v3 = entry!(@exclusive, 3)

      report =
        Classifier.classify(export(source, [token("Task_A")]), [v2, v3],
          to_versions: %{source["key"] => 2}
        )

      assert hd(report["instances"])["to_version"] == 2
      assert verdict(report) == "needs_restart"
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp entry!(path, version), do: variant!(path, version, nil, nil)

  # A definition entry for `path` at `version`, optionally with one substitution applied to
  # the XML first. The process key comes from the fixture name and the id from the key and
  # version together: a parent and its child are two different processes, and giving them one
  # key would make the export's definition index collapse them into whichever the map
  # happened to hold -- a failure that shows up only on some seeds.
  defp variant!(path, version, from, to) do
    xml = File.read!(path)
    xml = if from, do: String.replace(xml, from, to), else: xml

    entry_from_xml!(xml, version, Path.basename(path, ".bpmn"))
  end

  # Applies an edit that no fixture expresses -- a deleted node, a swapped FEEL engine -- and
  # restamps the graph digest to match. Without the restamp the entry would claim to be the
  # same graph it was before, and the classifier's "the target is byte-identical to the pinned
  # graph" shortcut would (correctly) fire over a document that had in fact been edited. The
  # helper exists so a test cannot accidentally assert against an entry that contradicts itself.
  defp altered(entry, fun) do
    edited = fun.(entry)
    %{edited | "graph_digest" => AshBpmn.Canonical.digest(Map.delete(edited, "graph_digest"))}
  end

  defp entry_from_xml!(xml, version, key) do
    {:ok, entry} = StateExport.definition_entry_from_xml(key, version, xml)
    # A stored definition has an id, and the export keys its definitions by it. Deriving one
    # from the key and version keeps two versions of one process, and two different processes,
    # all distinguishable without pretending these came from rows.
    %{entry | "id" => "def-#{key}-#{version}"}
  end

  defp token(node_id, opts \\ []) do
    %{
      "id" => Ash.UUID.generate(),
      "node_id" => node_id,
      "status" => Keyword.get(opts, :status, "active"),
      "waiting" => Keyword.get(opts, :waiting)
    }
  end

  defp instance(definition, tokens) do
    %{
      "id" => Ash.UUID.generate(),
      "definition_id" => definition["id"],
      "definition_key" => definition["key"],
      "definition_version" => definition["version"],
      "status" => "running",
      "tokens" => tokens
    }
  end

  defp base_export do
    %{
      "format" => StateExport.format(),
      "format_version" => StateExport.format_version(),
      "exported_at" => "2026-09-21T00:00:00.000000Z",
      "engine" => %{"ash_bpmn" => "0.1.0"},
      "definitions" => [],
      "instances" => []
    }
  end

  defp export(definition, tokens) do
    %{
      base_export()
      | "definitions" => [definition],
        "instances" => [instance(definition, tokens)]
    }
  end

  defp classify(source, target, tokens) do
    Classifier.classify(export(source, tokens), List.wrap(target))
  end

  defp verdict(report), do: hd(report["instances"])["classification"]

  defp codes(report) do
    report["instances"] |> Enum.flat_map(& &1["reasons"]) |> Enum.map(& &1["code"])
  end
end
