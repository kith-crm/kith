import Config

# Only in tests, remove the complexity from the password hashing algorithm
config :pbkdf2_elixir, :rounds, 1

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :kith, Kith.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  port: String.to_integer(System.get_env("DB_PORT", "5434")),
  database: "kith_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# Start the server when running Wallaby tests (WALLABY=1 mix test --only wallaby)
config :kith, KithWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "9QVosGIymc5flycbrRXuumAnww6vPwtL7Xf4iOAPW05MoPggLbe8eOQeVT0f8y9R",
  server: !!System.get_env("WALLABY")

# Disable Oban in tests (use Oban.Testing)
config :kith, Oban, testing: :manual

# Use the production libphonenumber metadata in tests so test-only validation
# rules (NANP "555" prefixes, etc.) don't diverge from real behavior.
config :ex_phone_number, metadata_file: Path.join("resources", "PhoneNumberMetadata.xml")

# Effectively unthrottled in tests — throttle logic is exercised in
# isolation in rate_limiter_test.exs, not via the full crawl integration.
config :kith, :monica_rate_limit, 1_000_000

# Disable PromEx in tests (its Ecto poller conflicts with sandbox ownership)
config :kith, Kith.PromEx, disabled: true

# Email — test adapter
config :kith, Kith.Mailer, adapter: Swoosh.Adapters.Test

# Disable Swoosh API client in tests
config :swoosh, :api_client, false

# Disable Sentry in tests
config :sentry, client: Sentry.NoopClient, dsn: nil

# Test metrics token
config :kith, metrics_token: "test-metrics-token"

# Disable email verification by default in tests (override per-test as needed)
config :kith, signup_double_optin: false

# Storage — local backend for tests
config :kith, Kith.Storage, backend: :local, path: "priv/uploads/test"

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

# Wallaby — headless Chrome for browser E2E tests
# Run with: WALLABY=1 mix test --only wallaby
# Use headed Chrome for debugging: WALLABY_HEADLESS=false WALLABY=1 mix test --only wallaby
config :wallaby,
  driver: Wallaby.Chrome,
  otp_app: :kith,
  screenshot_on_failure: true,
  screenshot_dir: "tmp/wallaby_screenshots",
  chromedriver: [headless: System.get_env("WALLABY_HEADLESS", "true") != "false"]
