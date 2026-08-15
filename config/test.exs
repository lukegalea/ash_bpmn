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

config :ash_bpmn, ash_domains: [AshBpmn.Test.Domain]

config :ash, :validate_domain_resource_inclusion?, false
config :ash, :validate_domain_config_inclusion?, false
config :ash, disable_async?: true

# Deterministic engine tests: the runtime's Oban shim executes workers inline
# instead of enqueueing. See AshBpmn.Runtime.Oban.
config :ash_bpmn, oban_testing: :inline

config :logger, level: :warning
