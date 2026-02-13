import Config

# Only in tests, remove the complexity from the password hashing algorithm
config :bcrypt_elixir, :log_rounds, 1

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :swarmshield, Swarmshield.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "swarmshield_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: max(System.schedulers_online() * 4, 64),
  queue_target: 5000,
  queue_interval: 10_000

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :swarmshield, SwarmshieldWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "VH8Sv+XdvYbPNygn9elxXi2yc1JkwcjNeKRVfQfcMF9CLFNWycggO/Zb3d+WrNwE",
  server: false

# In test we don't send emails
config :swarmshield, Swarmshield.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# Simulator uses Req.Test stub in test environment
config :swarmshield, Swarmshield.Simulator, req_options: [plug: {Req.Test, Swarmshield.Simulator}]
