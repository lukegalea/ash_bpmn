# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.TestRepo do
  @moduledoc """
  The repo the resource tests run against. Test-env only.
  """

  use AshPostgres.Repo,
    otp_app: :ash_bpmn,
    warn_on_missing_ash_functions?: false

  @impl true
  def min_pg_version, do: %Version{major: 14, minor: 0, patch: 0}

  @impl true
  def installed_extensions, do: ["uuid-ossp"]

  @impl true
  def prefer_transaction?, do: false
end
