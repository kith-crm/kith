# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

# Register .vcf (vCard) MIME type for LiveView uploads
config :mime, :types, %{"text/vcard" => ["vcf"], "application/json" => ["json"]}

# Default CLDR backend — required so ex_cldr_territories can resolve
# locale-aware territory data without an explicit per-call backend argument.
config :ex_cldr, default_backend: Kith.Cldr

# Outbound rate limit for Monica API calls. One below the documented
# default of 60 req/min leaves a one-call safety margin.
config :kith, :monica_rate_limit, 55

config :kith, :scopes,
  user: [
    default: true,
    module: Kith.Accounts.Scope,
    assign_key: :current_scope,
    access_path: [:user, :id],
    schema_key: :user_id,
    schema_type: :id,
    schema_table: :users,
    test_data_fixture: Kith.AccountsFixtures,
    test_setup_helper: :register_and_log_in_user
  ]

config :kith,
  ecto_repos: [Kith.Repo],
  generators: [timestamp_type: :utc_datetime],
  disable_signup: false,
  require_tos_acceptance: false,
  signup_double_optin: true

# Oban background jobs
config :kith, Oban,
  repo: Kith.Repo,
  queues: [
    default: 10,
    mailers: 10,
    reminders: 5,
    exports: 2,
    imports: 2,
    immich: 3,
    purge: 1
  ],
  plugins: [
    Oban.Plugins.Pruner,
    {Oban.Plugins.Cron,
     crontab: [
       {"0 2 * * *", Kith.Workers.ReminderSchedulerWorker},
       {"0 3 * * *", Kith.Workers.ContactPurgeWorker},
       {"0 4 * * 0", Kith.Workers.DuplicateDetectionWorker},
       {"0 5 * * 0", Kith.Workers.ImportFileCleanupWorker}
     ]}
  ]

# Rate limiting (ETS default, Redis optional via RATE_LIMIT_BACKEND env)
config :hammer,
  backend: {Hammer.Backend.ETS, [expiry_ms: 60_000 * 60, cleanup_interval_ms: 60_000 * 10]}

# Timezone database
config :elixir, :time_zone_database, Tz.TimeZoneDatabase

# Configure the endpoint
config :kith, KithWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: KithWeb.ErrorHTML, json: KithWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Kith.PubSub,
  live_view: [signing_salt: "KsbGiNTx"]

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  kith: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  kith: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Weather (OpenWeatherMap) — API key set per-environment via env vars
config :kith, :weather_api_key, nil

# OAuth providers — configured per-environment via env vars
config :kith, :oauth_providers, %{}

# WebAuthn (wax_) — origin/rp_id set per-environment
config :wax_,
  origin: "http://localhost:4000",
  rp_id: :auto

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [
    :request_id,
    :user_id,
    :account_id,
    :reason,
    :worker,
    :queue,
    :duration_ms,
    :attempt,
    :max_attempts,
    :state,
    :source,
    :import_id
  ]

# Cloak encryption vault — key set per-environment
config :kith, Kith.Vault,
  ciphers: [
    default:
      {Cloak.Ciphers.AES.GCM,
       tag: "AES.GCM.V1", key: Base.decode64!("oQaI0liBwsBX4ClJyWexY+lHhC3R3RPn1t9N8VPFdho=")}
  ]

# Flop — server-side sorting, filtering, pagination
config :flop, repo: Kith.Repo, default_limit: 25

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
