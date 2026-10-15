# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.TestRepo.Migrations.CreateObanJobs do
  @moduledoc """
  Oban's own table, in the test database only.

  The suite runs Oban inline almost everywhere, which never touches `oban_jobs`. The tests that
  need the real thing are the ones about transactions: a job inserted inside a step that rolls
  back must be gone, and only a real `Oban.insert/2` into a real table can show that. The host
  creates this table in its own migrations; the library ships none.
  """
  use Ecto.Migration

  def up, do: Oban.Migrations.up()

  def down, do: Oban.Migrations.down(version: 1)
end
