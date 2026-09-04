# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.Test.Domain do
  @moduledoc false

  use Ash.Domain

  resources do
    resource AshBpmn.Test.Definition
    resource AshBpmn.Test.Instance
    resource AshBpmn.Test.Token
    resource AshBpmn.Test.HumanTask
    resource AshBpmn.Test.TaskCandidate
    resource AshBpmn.Test.ProcessEvent
    resource AshBpmn.Test.Subject
    resource AshBpmn.Test.CatalogueResource
    resource AshBpmn.Test.UndocumentedActionResource
    resource AshBpmn.Test.TaggedActionResource
  end
end
