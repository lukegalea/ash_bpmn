# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.DesignerCatalogueTest do
  @moduledoc """
  The designer's typed-node panels: the business rule task panel (decision
  catalogue, status badge, drift note, deep link, inputs, promotions), the
  service/send panels fed by the action catalogue — and their `ash:call`
  binding, fed by the callables the configured domains expose — plus the
  free-text fallback when no catalogue is configured or its source is down.

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

    test "invalid FEEL input rows are flagged inline on change" do
      {:ok, view, _html} = live_catalogue_designer()

      render_hook(view, "selection_changed", %{
        "id" => "AssessRisk",
        "type" => "bpmn:BusinessRuleTask",
        "name" => "Assess risk",
        "config" => %{"decision" => %{"ref" => "access_request.risk", "binding" => "latest"}}
      })

      html =
        view
        |> element("#ash-bpmn-panel form")
        |> render_change(%{
          "element_id" => "AssessRisk",
          "type" => "bpmn:BusinessRuleTask",
          "name" => "Assess risk",
          "decision_ref" => "access_request.risk",
          "binding" => "latest",
          "inputs_name" => ["amount", ""],
          "inputs_from" => ["subject.amount ==", ""],
          "promote_name" => [""],
          "promote_from" => [""],
          "promote_required" => ["false"]
        })

      assert has_element?(view, "#feel-feedback-inputs-0")
      assert html =~ "expected expression"
      assert html =~ "FEEL equality is =, not =="

      # The half-typed row survives the validation re-render
      assert html =~ ~s(value="amount")
      assert html =~ "subject.amount =="
    end

    test "a parseable input row confirms itself quietly" do
      {:ok, view, _html} = live_catalogue_designer()

      render_hook(view, "selection_changed", %{
        "id" => "AssessRisk",
        "type" => "bpmn:BusinessRuleTask",
        "name" => "Assess risk",
        "config" => %{"decision" => %{"ref" => "access_request.risk", "binding" => "latest"}}
      })

      html =
        view
        |> element("#ash-bpmn-panel form")
        |> render_change(%{
          "element_id" => "AssessRisk",
          "type" => "bpmn:BusinessRuleTask",
          "name" => "Assess risk",
          "decision_ref" => "access_request.risk",
          "binding" => "latest",
          "inputs_name" => ["amount"],
          "inputs_from" => ["subject.amount > 100"],
          "promote_name" => [""],
          "promote_from" => [""],
          "promote_required" => ["false"]
        })

      assert has_element?(view, "#feel-feedback-inputs-0")
      assert html =~ "Valid FEEL"
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

    test "argument rows validate their FEEL on change" do
      {:ok, view, _html} = live_catalogue_designer()

      render_hook(view, "selection_changed", %{
        "id" => "Record",
        "type" => "bpmn:ServiceTask",
        "name" => "Record",
        "config" => %{"action" => "record_risk"}
      })

      html =
        view
        |> element("#ash-bpmn-panel form")
        |> render_change(%{
          "element_id" => "Record",
          "type" => "bpmn:ServiceTask",
          "name" => "Record",
          "action" => "record_risk",
          "inputs_from" => ["routing.tier ==", ""],
          "promote_name" => ["", ""],
          "promote_from" => ["", ""],
          "promote_required" => ["false", "false"]
        })

      assert has_element?(view, "#feel-feedback-inputs-0")
      assert html =~ "FEEL equality is =, not =="

      html =
        view
        |> element("#ash-bpmn-panel form")
        |> render_change(%{
          "element_id" => "Record",
          "type" => "bpmn:ServiceTask",
          "name" => "Record",
          "action" => "record_risk",
          "inputs_from" => ["routing.tier", ""],
          "promote_name" => ["", ""],
          "promote_from" => ["", ""],
          "promote_required" => ["false", "false"]
        })

      assert html =~ "Valid FEEL"
    end
  end

  # ── ServiceTask / SendTask panel: the ash:call binding ────────────────

  # The diagram spelling of the callables the test config's domains expose.
  @record_inputs_ref "AshBpmn.Test.RuntimeCallablesDomain.record_inputs"
  @assess_tier_ref "AshBpmn.Test.RuntimeCallablesDomain.assess_tier"

  describe "service task panel: ash:call binding" do
    test "renders the picker and the callable dropdown from the configured domains" do
      {:ok, view, _html} = live_catalogue_designer()

      html =
        render_hook(view, "selection_changed", %{
          "id" => "Record",
          "type" => "bpmn:ServiceTask",
          "name" => "Record",
          "config" => %{
            "call" => %{"ref" => @record_inputs_ref},
            "inputs" => [
              %{"name" => "amount", "from" => "subject.amount"},
              %{"name" => "tier", "from" => "routing.tier"}
            ]
          }
        })

      # The binding picker, with the call mode derived from the live config
      assert has_element?(view, "#config-binding-mode")
      assert html =~ ~s(<option value="call" selected)

      # The dropdown: the diagram spelling as the value, name and description
      # as the label — a select, not a guess
      assert html =~ ~s(<select id="config-call-ref" name="call_ref")
      assert html =~ ~s(value="#{@record_inputs_ref}" selected)
      assert html =~ "assess_tier — Assesses the risk tier from the amount"

      # The input palette is the callable's action arguments, prefilled from
      # the live binding — blank rows here would mean Apply erases them
      assert html =~ "amount"
      assert html =~ "tier"
      assert html =~ "decimal"
      assert length(Regex.scan(~r/name="inputs_from\[\]"/, html)) == 2
      assert html =~ ~s(value="subject.amount")
      assert html =~ ~s(value="routing.tier")

      # Promote rows ride along exactly as on every other binding
      assert has_element?(view, "input[name='promote_name[]']")
    end

    test "arg rows follow the callable select and validate their FEEL on change" do
      {:ok, view, _html} = live_catalogue_designer()

      render_hook(view, "selection_changed", %{
        "id" => "Record",
        "type" => "bpmn:ServiceTask",
        "name" => "Record",
        "config" => %{"call" => %{"ref" => @record_inputs_ref}}
      })

      # record_inputs declares two arguments
      assert length(Regex.scan(~r/name="inputs_from\[\]"/, render(view))) == 2

      # assess_tier declares one — the palette refreshes before Apply
      html =
        view
        |> element("#config-call-ref")
        |> render_change(%{"call_ref" => @assess_tier_ref})

      assert length(Regex.scan(~r/name="inputs_from\[\]"/, html)) == 1

      # The Phase 1 row validation, unchanged: bad FEEL flags the row inline
      # with the =-not-== hint, and the half-typed row survives the re-render
      html =
        view
        |> element("#ash-bpmn-panel form")
        |> render_change(%{
          "element_id" => "Record",
          "type" => "bpmn:ServiceTask",
          "name" => "Record",
          "binding_mode" => "call",
          "call_ref" => @assess_tier_ref,
          "inputs_from" => ["subject.amount =="],
          "promote_name" => [""],
          "promote_from" => [""],
          "promote_required" => ["false"]
        })

      assert has_element?(view, "#feel-feedback-inputs-0")
      assert html =~ "expected expression"
      assert html =~ "FEEL equality is =, not =="
      assert html =~ "subject.amount =="

      html =
        view
        |> element("#ash-bpmn-panel form")
        |> render_change(%{
          "element_id" => "Record",
          "type" => "bpmn:ServiceTask",
          "name" => "Record",
          "binding_mode" => "call",
          "call_ref" => @assess_tier_ref,
          "inputs_from" => ["subject.amount"],
          "promote_name" => [""],
          "promote_from" => [""],
          "promote_required" => ["false"]
        })

      assert html =~ "Valid FEEL"
    end

    test "picking a mode clears the other binding, in the panel and in the payload" do
      {:ok, view, _html} = live_catalogue_designer()

      render_hook(view, "selection_changed", %{
        "id" => "Record",
        "type" => "bpmn:ServiceTask",
        "name" => "Record",
        "config" => %{"action" => "record_risk"}
      })

      # The legacy-bound task opens in action mode
      html = render(view)
      assert html =~ ~s(<option value="action" selected)
      assert has_element?(view, "#config-action")

      # Flipping to the call binding swaps the field set before Apply
      view
      |> element("#config-binding-mode")
      |> render_change(%{"binding_mode" => "call"})

      refute has_element?(view, "#config-action")
      assert has_element?(view, "#config-call-ref")

      view
      |> element("#ash-bpmn-panel form")
      |> render_submit(%{
        "element_id" => "Record",
        "type" => "bpmn:ServiceTask",
        "name" => "Record",
        "binding_mode" => "call",
        "call_ref" => @record_inputs_ref,
        "inputs_from" => ["subject.amount", "routing.tier"],
        "promote_name" => [""],
        "promote_from" => [""],
        "promote_required" => ["false"]
      })

      assert_push_event(view, "apply_config", %{config: config})

      # The payload carries the call, and the action is cleared: the hook can
      # only ever write one binding element
      assert config["call"] == %{"ref" => @record_inputs_ref}
      assert config["action"] == ""

      assert config["inputs"] == [
               %{"name" => "amount", "from" => "subject.amount"},
               %{"name" => "tier", "from" => "routing.tier"}
             ]

      assert config["promote"] == []

      # And back: an action-mode Apply carries the action and an empty call
      view
      |> element("#config-binding-mode")
      |> render_change(%{"binding_mode" => "action"})

      view
      |> element("#ash-bpmn-panel form")
      |> render_submit(%{
        "element_id" => "Record",
        "type" => "bpmn:ServiceTask",
        "name" => "Record",
        "binding_mode" => "action",
        "action" => "send_notice",
        "inputs_from" => ["routing.tier"],
        "promote_name" => [""],
        "promote_from" => [""],
        "promote_required" => ["false"]
      })

      assert_push_event(view, "apply_config", %{config: config})

      assert config["action"] == "send_notice"
      assert config["call"] == %{"ref" => ""}
      assert config["inputs"] == [%{"name" => "note", "from" => "routing.tier"}]
    end

    test "the applied call binding is XML the compiler accepts" do
      {:ok, view, _html} = live_catalogue_designer()

      render_hook(view, "selection_changed", %{
        "id" => "Record",
        "type" => "bpmn:ServiceTask",
        "name" => "Record",
        "config" => %{"call" => %{"ref" => @assess_tier_ref}}
      })

      view
      |> element("#ash-bpmn-panel form")
      |> render_submit(%{
        "element_id" => "Record",
        "type" => "bpmn:ServiceTask",
        "name" => "Record",
        "binding_mode" => "call",
        "call_ref" => @assess_tier_ref,
        "inputs_from" => ["subject.amount"],
        "promote_name" => ["tier"],
        "promote_from" => [""],
        "promote_required" => ["true"]
      })

      assert_push_event(view, "apply_config", %{config: config})

      assert config["call"] == %{"ref" => @assess_tier_ref}
      assert config["inputs"] == [%{"name" => "amount", "from" => "subject.amount"}]

      # The XML the hook writes from this payload — the ash:call binding plus
      # the shared inputs/promote vocabulary — must compile and verify: the
      # ref resolves against the configured domains and every declared input
      # names a real argument of the callable's action.
      inputs =
        Enum.map_join(config["inputs"], fn input ->
          ~s|<ash:input name="#{input["name"]}" from="#{input["from"]}"/>|
        end)

      xml =
        service_task_xml("""
        <ash:call ref="#{config["call"]["ref"]}"/>
        <ash:inputs>#{inputs}</ash:inputs>
        <ash:promote>
          <ash:signal name="tier" required="true"/>
        </ash:promote>
        """)

      assert {:ok, graph} = AshBpmn.Compiler.compile(xml)

      node = graph["nodes"]["T"]

      assert node["call"] == %{"ref" => @assess_tier_ref}
      assert [%{"name" => "amount", "from" => %{"text" => "subject.amount"}}] = node["inputs"]
      assert [%{"name" => "tier", "from" => "tier", "required" => true}] = node["promote"]
    end

    test "sendTask gets the same picker and call payload" do
      {:ok, view, _html} = live_catalogue_designer()

      html =
        render_hook(view, "selection_changed", %{
          "id" => "Notify",
          "type" => "bpmn:SendTask",
          "name" => "Notify",
          "config" => %{
            "call" => %{"ref" => @assess_tier_ref},
            "inputs" => [%{"name" => "amount", "from" => "subject.amount"}]
          }
        })

      assert has_element?(view, "#config-binding-mode")
      assert html =~ ~s(<option value="call" selected)
      assert html =~ ~s(value="#{@assess_tier_ref}" selected)
      assert html =~ ~s(value="subject.amount")

      view
      |> element("#ash-bpmn-panel form")
      |> render_submit(%{
        "element_id" => "Notify",
        "type" => "bpmn:SendTask",
        "name" => "Notify",
        "binding_mode" => "call",
        "call_ref" => @assess_tier_ref,
        "inputs_from" => ["subject.amount"],
        "promote_name" => [""],
        "promote_from" => [""],
        "promote_required" => ["false"]
      })

      assert_push_event(view, "apply_config", %{config: config})

      assert config["call"] == %{"ref" => @assess_tier_ref}
      assert config["action"] == ""
      assert config["inputs"] == [%{"name" => "amount", "from" => "subject.amount"}]
    end

    test "warns when the call ref is not declared by any configured domain" do
      {:ok, view, _html} = live_catalogue_designer()

      html =
        render_hook(view, "selection_changed", %{
          "id" => "Record",
          "type" => "bpmn:ServiceTask",
          "name" => "Record",
          "config" => %{"call" => %{"ref" => "AshBpmn.Test.RuntimeCallablesDomain.nope"}}
        })

      assert has_element?(view, "#config-call-ref")
      assert html =~ "AshBpmn.Test.RuntimeCallablesDomain.nope"
      assert html =~ "is not declared by any configured domain"
    end

    test "no callables anywhere: the quiet note, never a broken control" do
      # The callable dropdown's source is the configured domains; emptying
      # them empties the dropdown. These tests are async: false, so the app env
      # mutation is exclusive to this test and restored before the next.
      original_bpmn = Application.get_env(:ash_bpmn, :ash_domains)
      original_ash = Application.get_env(:ash, :ash_domains)

      Application.put_env(:ash_bpmn, :ash_domains, [])
      Application.put_env(:ash, :ash_domains, [])

      on_exit(fn ->
        Application.put_env(:ash_bpmn, :ash_domains, original_bpmn)

        if original_ash == nil,
          do: Application.delete_env(:ash, :ash_domains),
          else: Application.put_env(:ash, :ash_domains, original_ash)
      end)

      {:ok, view, _html} = live_catalogue_designer()

      render_hook(view, "selection_changed", %{
        "id" => "Record",
        "type" => "bpmn:ServiceTask",
        "name" => "Record",
        "config" => %{}
      })

      html =
        view
        |> element("#config-binding-mode")
        |> render_change(%{"binding_mode" => "call"})

      assert has_element?(view, "#config-call-empty")
      assert html =~ "No actions are exposed to diagrams"
      assert html =~ "callables"
      refute has_element?(view, "#config-call-ref")

      # A stray ref from the XML stays visible and submittable: Apply must not
      # silently erase a binding the panel was shown.
      html =
        render_hook(view, "selection_changed", %{
          "id" => "Record",
          "type" => "bpmn:ServiceTask",
          "name" => "Record",
          "config" => %{"call" => %{"ref" => @record_inputs_ref}}
        })

      assert html =~ "is not declared by any configured domain"
      assert html =~ ~s(name="call_ref")

      view
      |> element("#ash-bpmn-panel form")
      |> render_submit(%{
        "element_id" => "Record",
        "type" => "bpmn:ServiceTask",
        "name" => "Record",
        "binding_mode" => "call",
        "call_ref" => @record_inputs_ref,
        "promote_name" => [""],
        "promote_from" => [""],
        "promote_required" => ["false"]
      })

      assert_push_event(view, "apply_config", %{config: config})
      assert config["call"] == %{"ref" => @record_inputs_ref}
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

  # An otherwise-valid process whose serviceTask carries the given extension
  # elements — the same corpus shape compiler_test.exs uses, so the panel's
  # apply payload can be compiled exactly as the hook would write it.
  defp service_task_xml(ext_content) do
    """
    <bpmn2:definitions xmlns:bpmn2="http://www.omg.org/spec/BPMN/20100524/MODEL"
                       xmlns:ash="https://github.com/lukegalea/ash_bpmn/ns">
      <bpmn2:process id="P" isExecutable="true">
        <bpmn2:startEvent id="S"><bpmn2:outgoing>F</bpmn2:outgoing></bpmn2:startEvent>
        <bpmn2:serviceTask id="T" name="Task">
          <bpmn2:extensionElements>#{ext_content}</bpmn2:extensionElements>
          <bpmn2:incoming>F</bpmn2:incoming>
          <bpmn2:outgoing>F2</bpmn2:outgoing>
        </bpmn2:serviceTask>
        <bpmn2:endEvent id="E"><bpmn2:incoming>F2</bpmn2:incoming></bpmn2:endEvent>
        <bpmn2:sequenceFlow id="F" sourceRef="S" targetRef="T"/>
        <bpmn2:sequenceFlow id="F2" sourceRef="T" targetRef="E"/>
      </bpmn2:process>
    </bpmn2:definitions>
    """
  end

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
