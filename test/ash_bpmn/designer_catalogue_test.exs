# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.DesignerCatalogueTest do
  @moduledoc """
  The designer's typed-node panels: the business rule task panel (decision
  catalogue, status badge, drift note, deep link, inputs, promotions), the
  service/send panels fed by the action catalogue, and the free-text fallback
  when no catalogue is configured or its source is down.

  The round-trip contract matters more than any single field: the apply_config
  payload must carry the decision elements back out, because the hook rewrites
  extensionElements from scratch — a payload without them is the silent-erasure
  defect this panel exists to close.
  """

  use AshBpmn.WebConnCase, async: false

  # ── BusinessRuleTask panel ─────────────────────────────────────────────

  describe "business rule task panel" do
    test "renders the decision catalogue with a status badge, name select and deep link" do
      {:ok, view, _html} = live_catalogue_designer()

      html =
        render_hook(view, "selection_changed", %{
          "id" => "AssessRisk",
          "type" => "bpmn:BusinessRuleTask",
          "name" => "Assess risk",
          "config" => %{
            "decision" => %{"ref" => "access_request.risk", "binding" => "latest"},
            "inputs" => [%{"name" => "amount", "from" => "subject.amount"}],
            "promote" => [%{"name" => "tier", "from" => "", "required" => true}]
          }
        })

      # The catalogue select, not free text, with the entry selected
      assert html =~ ~s(<select id="config-decision-ref" name="decision_ref")
      assert html =~ ~s(value="access_request.risk" selected)
      assert html =~ "Access request risk"

      # Status badge for the resolved entry
      assert html =~ "published v3"

      # Two decisions in the key, so the decision-name select is present
      assert has_element?(view, "select[name='decision_name']")
      assert html =~ ~s(value="RiskTier")

      # The deep link: configured editor MFA, non-empty ref
      assert html =~ ~s(href="https://decisions.test/access_request.risk/edit")
      assert html =~ ~s(target="_blank")
      assert html =~ ~s(rel="noopener")
      assert html =~ "Edit decision"

      # Existing bindings prefill the rows
      assert html =~ ~s(value="subject.amount")
      assert html =~ ~s(value="tier")
      assert html =~ ~s(value="true" selected)
    end

    test "renders the version input and drift note when pinned" do
      {:ok, view, _html} = live_catalogue_designer()

      html =
        render_hook(view, "selection_changed", %{
          "id" => "AssessRisk",
          "type" => "bpmn:BusinessRuleTask",
          "name" => "Assess risk",
          "config" => %{
            "decision" => %{
              "ref" => "access_request.risk",
              "binding" => "pinned",
              "version" => "1"
            }
          }
        })

      assert has_element?(view, "input[name='version']")
      assert html =~ ~s(value="1")
      assert html =~ "Pinned to v1; latest published is v3."
    end

    test "warns when the ref is not in the catalogue" do
      {:ok, view, _html} = live_catalogue_designer()

      html =
        render_hook(view, "selection_changed", %{
          "id" => "AssessRisk",
          "type" => "bpmn:BusinessRuleTask",
          "name" => "Assess risk",
          "config" => %{"decision" => %{"ref" => "no.such.key", "binding" => "latest"}}
        })

      assert html =~ "no.such.key"
      assert html =~ "is not in the decision catalogue"
    end

    test "round-trips the decision through the form path without erasing it" do
      {:ok, view, _html} = live_catalogue_designer()

      render_hook(view, "selection_changed", %{
        "id" => "AssessRisk",
        "type" => "bpmn:BusinessRuleTask",
        "name" => "Assess risk",
        "config" => %{
          "decision" => %{
            "ref" => "access_request.risk",
            "binding" => "pinned",
            "version" => "2",
            "name" => "RiskTier"
          },
          "inputs" => [%{"name" => "amount", "from" => "subject.amount"}],
          "promote" => [%{"name" => "tier", "from" => "", "required" => true}]
        }
      })

      view
      |> element("#ash-bpmn-panel form")
      |> render_submit(%{
        "element_id" => "AssessRisk",
        "type" => "bpmn:BusinessRuleTask",
        "name" => "Assess risk",
        "decision_ref" => "access_request.risk",
        "binding" => "pinned",
        "version" => "2",
        "decision_name" => "RiskTier",
        "inputs_name" => ["amount", ""],
        "inputs_from" => ["subject.amount", ""],
        "promote_name" => ["tier", ""],
        "promote_from" => ["", ""],
        "promote_required" => ["true", "false"]
      })

      assert_push_event(view, "apply_config", %{config: config})

      # The whole decision comes back — ref, binding, version and name — because the
      # hook rebuilds extensionElements from this payload alone.
      assert config["decision"] == %{
               "ref" => "access_request.risk",
               "binding" => "pinned",
               "version" => "2",
               "name" => "RiskTier"
             }

      assert config["inputs"] == [%{"name" => "amount", "from" => "subject.amount"}]
      assert config["promote"] == [%{"name" => "tier", "from" => "", "required" => true}]
    end

    test "a latest binding emits no version into the payload" do
      {:ok, view, _html} = live_catalogue_designer()

      render_hook(view, "selection_changed", %{
        "id" => "AssessRisk",
        "type" => "bpmn:BusinessRuleTask",
        "name" => "Assess risk",
        "config" => %{"decision" => %{"ref" => "access_request.risk", "binding" => "latest"}}
      })

      view
      |> element("#ash-bpmn-panel form")
      |> render_submit(%{
        "element_id" => "AssessRisk",
        "type" => "bpmn:BusinessRuleTask",
        "name" => "Assess risk",
        "decision_ref" => "access_request.risk",
        "binding" => "latest",
        "decision_name" => "",
        "inputs_name" => [""],
        "inputs_from" => [""],
        "promote_name" => [""],
        "promote_from" => [""],
        "promote_required" => ["false"]
      })

      assert_push_event(view, "apply_config", %{config: config})

      assert config["decision"]["binding"] == "latest"
      assert config["decision"]["version"] == nil
      assert config["decision"]["name"] == nil
      assert config["inputs"] == []
      assert config["promote"] == []
    end

    test "falls back to free text when no catalogue option is configured" do
      {:ok, view, _html} = live_designer()

      html =
        render_hook(view, "selection_changed", %{
          "id" => "AssessRisk",
          "type" => "bpmn:BusinessRuleTask",
          "name" => "Assess risk",
          "config" => %{"decision" => %{"ref" => "my.risk", "binding" => "latest"}}
        })

      assert has_element?(view, "input[name='decision_ref']")
      assert html =~ ~s(value="my.risk")
      refute html =~ "decision_name"
    end

    test "falls back to free text when the catalogue source is down" do
      {:ok, view, _html} = live_failing_catalogue_designer()

      html =
        render_hook(view, "selection_changed", %{
          "id" => "AssessRisk",
          "type" => "bpmn:BusinessRuleTask",
          "name" => "Assess risk",
          "config" => %{"decision" => %{"ref" => "my.risk", "binding" => "latest"}}
        })

      assert has_element?(view, "input[name='decision_ref']")
      assert html =~ ~s(value="my.risk")
    end
  end

  # ── ServiceTask / SendTask panel ───────────────────────────────────────

  describe "service task panel" do
    test "renders the action catalogue with argument hints and FEEL rows" do
      {:ok, view, _html} = live_catalogue_designer()

      html =
        render_hook(view, "selection_changed", %{
          "id" => "Record",
          "type" => "bpmn:ServiceTask",
          "name" => "Record",
          "config" => %{
            "action" => "record_risk",
            "inputs" => [%{"name" => "risk_tier", "from" => "routing.tier"}],
            "promote" => []
          }
        })

      assert html =~ ~s(<select id="config-action" name="action")
      assert html =~ ~s(value="record_risk" selected)

      # One row per declared argument: read-only hints + a FEEL from input
      assert html =~ "risk_tier"
      assert html =~ "reviewer_notes"
      assert html =~ "The assessed tier"
      # allow_nil? == false renders the required badge
      assert html =~ ~r/>\s*required\s*<\/span>/
      # The existing binding prefills the row for its argument
      assert html =~ ~s(value="routing.tier")

      assert length(Regex.scan(~r/name="inputs_from\[\]"/, html)) == 2
    end

    test "arg rows refresh when the action select changes" do
      {:ok, view, _html} = live_catalogue_designer()

      render_hook(view, "selection_changed", %{
        "id" => "Record",
        "type" => "bpmn:ServiceTask",
        "name" => "Record",
        "config" => %{"action" => "record_risk"}
      })

      assert render(view) =~ "reviewer_notes"

      html =
        view
        |> element("select[name='action']")
        |> render_change(%{"action" => "send_notice"})

      assert html =~ "note"
      refute html =~ "reviewer_notes"
    end

    test "submits filled argument rows as inputs, dropping empty ones" do
      {:ok, view, _html} = live_catalogue_designer()

      render_hook(view, "selection_changed", %{
        "id" => "Record",
        "type" => "bpmn:ServiceTask",
        "name" => "Record",
        "config" => %{"action" => "record_risk"}
      })

      view
      |> element("#ash-bpmn-panel form")
      |> render_submit(%{
        "element_id" => "Record",
        "type" => "bpmn:ServiceTask",
        "name" => "Record",
        "action" => "record_risk",
        "inputs_from" => ["routing.tier", ""],
        "promote_name" => ["", ""],
        "promote_from" => ["", ""],
        "promote_required" => ["false", "false"]
      })

      assert_push_event(view, "apply_config", %{config: config})

      assert config["action"] == "record_risk"
      # The row names come from the catalogue entry, positionally aligned
      assert config["inputs"] == [%{"name" => "risk_tier", "from" => "routing.tier"}]
      assert config["promote"] == []
    end

    test "sendTask gets the same panel and payload" do
      {:ok, view, _html} = live_catalogue_designer()

      html =
        render_hook(view, "selection_changed", %{
          "id" => "Notify",
          "type" => "bpmn:SendTask",
          "name" => "Notify",
          "config" => %{
            "action" => "send_notice",
            "inputs" => [%{"name" => "note", "from" => "routing.tier"}],
            "promote" => [%{"name" => "ticket", "from" => "reference", "required" => "true"}]
          }
        })

      assert html =~ ~s(value="send_notice" selected)
      assert html =~ "note"
      assert html =~ ~s(value="routing.tier")
      assert html =~ ~s(value="reference")
      assert html =~ ~s(value="true" selected)

      view
      |> element("#ash-bpmn-panel form")
      |> render_submit(%{
        "element_id" => "Notify",
        "type" => "bpmn:SendTask",
        "name" => "Notify",
        "action" => "send_notice",
        "inputs_from" => ["routing.tier"],
        "promote_name" => ["ticket"],
        "promote_from" => ["reference"],
        "promote_required" => ["true"]
      })

      assert_push_event(view, "apply_config", %{config: config})

      assert config["action"] == "send_notice"
      assert config["inputs"] == [%{"name" => "note", "from" => "routing.tier"}]

      assert config["promote"] == [
               %{"name" => "ticket", "from" => "reference", "required" => true}
             ]
    end

    test "falls back to free text when no catalogue option is configured" do
      {:ok, view, _html} = live_designer()

      html =
        render_hook(view, "selection_changed", %{
          "id" => "Record",
          "type" => "bpmn:ServiceTask",
          "name" => "Record",
          "config" => %{"action" => "my_app.record"}
        })

      assert has_element?(view, "input[name='action']")
      assert html =~ ~s(value="my_app.record")
    end
  end

  # ── Unchanged panels ───────────────────────────────────────────────────

  test "userTask and endEvent panels still render" do
    {:ok, view, _html} = live_catalogue_designer()

    html =
      render_hook(view, "selection_changed", %{
        "id" => "Task_1",
        "type" => "bpmn:UserTask",
        "name" => "Review",
        "config" => %{"outcomes" => ["approve"]}
      })

    assert html =~ "Outcomes"
    assert html =~ ~s(value="approve")

    html =
      render_hook(view, "selection_changed", %{
        "id" => "End_1",
        "type" => "bpmn:EndEvent",
        "name" => "End",
        "config" => %{"outcome" => "approved"}
      })

    assert html =~ ~s(value="approved")
  end

  # ── Helpers ────────────────────────────────────────────────────────────

  defp live_designer do
    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Test.init_test_session(%{})

    live(conn, "/designer")
  end

  defp live_catalogue_designer do
    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Test.init_test_session(%{})

    live(conn, "/catalogue-designer")
  end

  defp live_failing_catalogue_designer do
    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Test.init_test_session(%{})

    live(conn, "/failing-catalogue-designer")
  end
end
