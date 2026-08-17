# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

import Config

# Configuration for the demo host app in dev/ — the runnable Phoenix server
# that mounts the designer, viewer and task list. Never shipped: `files:` in
# mix.exs excludes config/, and a consuming application writes its own.

config :ash_bpmn, ecto_repos: [AshBpmnDev.Repo]

config :ash_bpmn, AshBpmnDev.Repo,
  hostname: System.get_env("DB_HOST", "localhost"),
  port: String.to_integer(System.get_env("PGPORT", "5432")),
  username: System.get_env("DB_USER", "postgres"),
  password: System.get_env("DB_PASSWORD", "postgres"),
  database: "ash_bpmn_dev",
  pool_size: 10,
  # The demo's migrations live with the demo, not in the library's priv/.
  priv: "dev/priv/repo"

config :ash_bpmn,
  assignment_resolver: AshBpmnDev.Resolver,
  action_invoker: AshBpmnDev.Invoker,
  ash_domains: [AshBpmnDev.Bpmn],
  queue: :bpmn,
  max_attempts: 5

# The demo has no Oban instance, so the runtime shim runs advance jobs inline
# and parks timers in ETS. Real hosts run real Oban; this keeps `mix
# dev.server` a single process with no queue to babysit.
config :ash_bpmn, oban_testing: :inline

config :ash_bpmn, AshBpmnDevWeb.Endpoint,
  url: [host: "localhost"],
  http: [ip: {127, 0, 0, 1}, port: String.to_integer(System.get_env("PORT", "4008"))],
  server: true,
  adapter: Bandit.PhoenixAdapter,
  secret_key_base: String.duplicate("devsecret", 8),
  pubsub_server: AshBpmnDev.PubSub,
  live_view: [signing_salt: "devsigningsalt00"],
  render_errors: [formats: [html: {AshBpmnDevWeb.ErrorView, :render, []}], layout: false],
  debug_errors: true,
  code_reloader: false,
  check_origin: false

config :ash, :validate_domain_resource_inclusion?, false
config :ash, :validate_domain_config_inclusion?, false

config :logger, level: :info
