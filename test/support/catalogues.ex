# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

# A small Ash resource with declared action arguments, so the catalogue helper
# has something real to read. Generic actions: no data layer, no tables.

defmodule AshBpmn.Test.CatalogueResource do
  @moduledoc false

  use Ash.Resource, domain: AshBpmn.Test.Domain

  actions do
    action :record_risk, :string do
      description "Records the assessed risk on the subject"

      argument :risk_tier, :string do
        allow_nil? false
        description "The assessed tier"
      end

      argument :reviewer_notes, :string do
        allow_nil? true
      end

      run fn _input, _context -> {:ok, "recorded"} end
    end

    action :send_notice, :string do
      description "Sends the risk notice"

      argument :note, :string do
        allow_nil? false
      end

      run fn _input, _context -> {:ok, "sent"} end
    end
  end
end

defmodule AshBpmn.Test.UndocumentedActionResource do
  @moduledoc false

  use Ash.Resource, domain: AshBpmn.Test.Domain

  actions do
    action :undocumented, :string do
      argument :count, :integer do
        allow_nil? false
      end

      run fn _input, _context -> {:ok, "x"} end
    end
  end
end

defmodule AshBpmn.Test.TaggedActionResource do
  @moduledoc false

  use Ash.Resource, domain: AshBpmn.Test.Domain

  actions do
    action :tag, :string do
      argument :tags, {:array, :string} do
        allow_nil? false
      end

      run fn _input, _context -> {:ok, "x"} end
    end
  end
end

defmodule AshBpmn.Test.Catalogues do
  @moduledoc """
  Static catalogue doubles for the designer tests: one decision entry (with a
  two-decision key, so the panel's decision-name select has something to show),
  and the action catalogue built through the real `AshBpmn.Catalogue.AshActions`
  helper against `AshBpmn.Test.CatalogueResource`.
  """

  def decisions(_socket) do
    [
      %{
        key: "access_request.risk",
        name: "Access request risk",
        status: :published,
        latest_published_version: 3,
        has_draft: false,
        decisions: [
          %{
            name: "RiskTier",
            inputs: [%{name: "amount", type_ref: :integer}],
            outputs: [%{name: "tier", type_ref: :string}]
          },
          %{
            name: "RiskScore",
            inputs: [],
            outputs: []
          }
        ]
      }
    ]
  end

  def actions(_socket) do
    AshBpmn.Catalogue.AshActions.entries([
      {"record_risk", AshBpmn.Test.CatalogueResource, :record_risk},
      {"send_notice", AshBpmn.Test.CatalogueResource, :send_notice}
    ])
  end

  def decision_editor(key, _socket), do: "https://decisions.test/#{key}/edit"
end

defmodule AshBpmn.Test.FailingCatalogues do
  @moduledoc "A catalogue that is down — the designer must degrade to free text."

  def decisions(_socket), do: raise("catalogue down")
  def actions(_socket), do: raise("catalogue down")
  def decision_editor(_key, _socket), do: raise("editor down")
end
