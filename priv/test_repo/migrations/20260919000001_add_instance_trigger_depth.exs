# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.TestRepo.Migrations.AddInstanceTriggerDepth do
  @moduledoc """
  How many trigger hops produced an instance.

  A separate migration from the signal tables because it is a separate fact: the depth bound
  already existed on `Dispatch`, and what was missing was anywhere for it to survive the gap
  between one event and the next. A process that throws a signal starts a fresh event with
  nothing linking it back, so without this the count restarted every lap.
  """

  use Ecto.Migration

  def up do
    alter table(:bpmn_instances), do: add(:trigger_depth, :integer, null: false, default: 0)

    alter table(:tenant_bpmn_instances),
      do: add(:trigger_depth, :integer, null: false, default: 0)
  end

  def down do
    alter table(:bpmn_instances), do: remove(:trigger_depth)
    alter table(:tenant_bpmn_instances), do: remove(:trigger_depth)
  end
end
