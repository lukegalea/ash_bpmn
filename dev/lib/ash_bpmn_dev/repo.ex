# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmnDev.Repo do
  @moduledoc """
  The demo app's repo. Dev-env only; it is what a host application's repo would
  be, and the BPMN resources are instantiated against it exactly as a host's
  would be.
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
