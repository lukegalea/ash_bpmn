# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.Test.Baselines do
  @moduledoc false

  # A host's baseline seam, reduced to what the designer needs from it: a document to show
  # for a key the scope has stored nothing for, and a way to turn that into the scope's own
  # draft. Where a real host keeps its baselines (another tenant, a file, a registry) is its
  # business; here it is a fixture file, so the test can tell the baseline's XML from the
  # template's by content.

  alias AshBpmn.Test.Definition

  @xml File.read!("test/fixtures/linear.bpmn")

  def xml, do: @xml

  def baseline(_key, _socket), do: %{xml: @xml, version: 3, name: "Baseline"}

  def customize(key, socket) do
    opts = AshBpmn.Scope.engine(AshBpmn.Scope.from_assigns(socket.assigns))
    {:ok, Definition.create!(%{key: key, name: "Customized", xml: @xml}, opts)}
  end

  def refuse(_key, _socket), do: {:error, "No baseline to customize from."}
end
