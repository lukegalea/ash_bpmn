# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

import Config

# This config exists for ash_bpmn's OWN dev and test runs. It is not shipped --
# `files:` in mix.exs excludes it -- and a consuming application configures its
# own resolver/invoker/domains. Same pattern as ash_strangler.
config :ash_bpmn, ecto_repos: [AshBpmn.TestRepo]

if config_env() == :test do
  import_config "test.exs"
end
