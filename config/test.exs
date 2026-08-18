# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

import Config

# The test repo. Postgres connection details come from the environment so both
# devenv (dynamic port, read from the cluster's postgresql.conf) and CI (fixed
# port) work without editing this file. Same pattern as ash_strangler.
config :ash_bpmn, AshBpmn.TestRepo,
  hostname: System.get_env("DB_HOST", "localhost"),
  port: String.to_integer(System.get_env("PGPORT", "5432")),
  username: System.get_env("DB_USER", "postgres"),
  password: System.get_env("DB_PASSWORD", "postgres"),
  database: "ash_bpmn_test",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online()

# Test-support values for the behaviours and domain discovery. A host app sets
# its own; these live here (test-only) so nothing leaks into consuming apps.
config :ash_bpmn,
  assignment_resolver: AshBpmn.Test.Resolver,
  action_invoker: AshBpmn.Test.Invoker,
  queue: :bpmn,
  max_attempts: 5

# Order matters. `AshBpmn.Runtime.DomainResolver.resolve!/1` falls back to the
# first domain here that has all six resource kinds when a caller does not name
# one, so the tenant-scoped domain goes last: it is reached by name, from the
# `"domain"` key its jobs carry, and never by the fallback.
config :ash_bpmn,
  ash_domains: [
    AshBpmn.Test.Domain,
    AshBpmn.ApprovalTestSupport.Domain,
    AshBpmn.TenantTest.Domain
  ]

# The web test endpoint (test/support/web_endpoint.ex). Config lives here —
# not in a compile-time Application.put_env in the module body — because that
# trick only executes on fresh compilation, never from cached beams.
config :ash_bpmn, AshBpmn.Web.TestEndpoint,
  server: false,
  pubsub_server: AshBpmn.Web.TestPubSub,
  secret_key_base: String.duplicate("a", 64),
  live_view: [signing_salt: String.duplicate("b", 32)],
  render_errors: [formats: [html: {AshBpmn.ErrorView, :render, []}], layout: false]

config :ash, :validate_domain_resource_inclusion?, false
config :ash, :validate_domain_config_inclusion?, false
config :ash, disable_async?: true

# Deterministic engine tests: the runtime's Oban shim executes workers inline
# instead of enqueueing. See AshBpmn.Runtime.Oban.
config :ash_bpmn, oban_testing: :inline

config :logger, level: :warning
