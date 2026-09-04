# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.Catalogue.AshActionsTest do
  use ExUnit.Case, async: true

  alias AshBpmn.Catalogue.AshActions

  describe "entries/1" do
    test "builds one entry per allowlist triple, arguments in declaration order" do
      [record_risk, send_notice] =
        AshActions.entries([
          {"record_risk", AshBpmn.Test.CatalogueResource, :record_risk},
          {"send_notice", AshBpmn.Test.CatalogueResource, :send_notice}
        ])

      assert record_risk.ref == "record_risk"
      assert record_risk.label == "Records the assessed risk on the subject"
      assert record_risk.description == "Records the assessed risk on the subject"

      assert Enum.map(record_risk.args, & &1.name) == ["risk_tier", "reviewer_notes"]

      [risk_tier, notes] = record_risk.args
      assert risk_tier.type == "string"
      assert risk_tier.allow_nil? == false
      assert risk_tier.description == "The assessed tier"

      assert notes.type == "string"
      assert notes.allow_nil? == true
      assert notes.description == nil

      assert send_notice.ref == "send_notice"
      assert send_notice.label == "Sends the risk notice"
    end

    test "an action without a description falls back to Resource.action" do
      [entry] =
        AshActions.entries([
          {"do_it", AshBpmn.Test.UndocumentedActionResource, :undocumented}
        ])

      assert entry.label == "AshBpmn.Test.UndocumentedActionResource.undocumented"
      assert entry.description == nil
      assert hd(entry.args).type == "integer"
    end

    test "array types render readably" do
      [entry] = AshActions.entries([{"tag_it", AshBpmn.Test.TaggedActionResource, :tag}])
      assert hd(entry.args).type == "string[]"
    end

    test "an unknown action raises — the allowlist is code" do
      assert_raise ArgumentError, ~r/does not declare an action named/, fn ->
        AshActions.entries([{"nope", AshBpmn.Test.CatalogueResource, :not_an_action}])
      end
    end
  end
end
