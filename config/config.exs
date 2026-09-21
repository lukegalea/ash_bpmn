# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

import Config

# This config exists for ash_bpmn's OWN dev and test runs. It is not shipped --
# `files:` in mix.exs excludes it -- and a consuming application configures its
# own resolver/invoker/domains. Same pattern as ash_strangler.
config :ash_bpmn, ecto_repos: [AshBpmn.TestRepo]

# Required since ash 3.33: every application compiling its own resources must
# make an explicit choice about how string length constraints count. Codepoints
# is the recommendation -- it is how SQL counts length, so Elixir-side
# validation agrees with what the data layer will store and enforce.
config :ash, default_string_length_count: :codepoints

if config_env() in [:dev, :test] do
  import_config "#{config_env()}.exs"
end
