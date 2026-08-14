import Config

# Helper: read from env var or Docker secret file (VAR_FILE takes precedence)
defmodule Kith.ConfigHelpers do
  def read_secret(env_var) do
    case System.get_env("#{env_var}_FILE") do
      nil -> System.get_env(env_var)
      file_path -> file_path |> String.trim() |> File.read!() |> String.trim()
    end
  end
end

# ## Shared (all environments)

if System.get_env("PHX_SERVER") do
  config :kith, KithWeb.Endpoint, server: true
end

config :kith, KithWeb.Endpoint, http: [port: String.to_integer(System.get_env("PORT", "4000"))]

# Feature flags
config :kith,
  disable_signup: System.get_env("DISABLE_SIGNUP") == "true",
  require_tos_acceptance: System.get_env("REQUIRE_TOS_ACCEPTANCE") == "true",
  max_upload_size_kb: String.to_integer(System.get_env("MAX_UPLOAD_SIZE_KB", "5120")),
  max_storage_size_mb: String.to_integer(System.get_env("MAX_STORAGE_SIZE_MB", "1024"))

# Only override signup_double_optin if the env var is explicitly set,
# so that test.exs / config.exs defaults are preserved.
if signup_optin = System.get_env("SIGNUP_DOUBLE_OPTIN") do
  config :kith, signup_double_optin: signup_optin == "true"
end

# ## Production-only configuration

# Weather (OpenWeatherMap) — optional
if weather_key = System.get_env("WEATHER_API_KEY") do
  config :kith, :weather_api_key, weather_key
end

if config_env() == :prod do
  database_url =
    Kith.ConfigHelpers.read_secret("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :kith, Kith.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE", "10")),
    ssl: System.get_env("DATABASE_SSL") == "true",
    socket_options: maybe_ipv6

  secret_key_base =
    Kith.ConfigHelpers.read_secret("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("KITH_HOSTNAME") || System.get_env("PHX_HOST") || "localhost"

  config :kith, KithWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [ip: {0, 0, 0, 0, 0, 0, 0, 0}],
    secret_key_base: secret_key_base

  # Cloak encryption vault — production key from env
  cloak_key =
    Kith.ConfigHelpers.read_secret("CLOAK_KEY") ||
      raise "CLOAK_KEY is required in production (base64-encoded 32-byte key)"

  config :kith, Kith.Vault,
    ciphers: [
      default: {Cloak.Ciphers.AES.GCM, tag: "AES.GCM.V1", key: Base.decode64!(cloak_key)}
    ]

  # WebAuthn — rp_id must match KITH_HOSTNAME exactly
  config :wax_,
    origin: "https://#{host}",
    rp_id: host

  # OAuth providers (optional — only enabled when env vars are set)
  oauth_providers = %{}

  oauth_providers =
    case {System.get_env("GITHUB_CLIENT_ID"), System.get_env("GITHUB_CLIENT_SECRET")} do
      {id, secret} when is_binary(id) and is_binary(secret) ->
        Map.put(oauth_providers, "github",
          client_id: id,
          client_secret: secret,
          strategy: Assent.Strategy.Github
        )

      _ ->
        oauth_providers
    end

  oauth_providers =
    case {System.get_env("GOOGLE_CLIENT_ID"), System.get_env("GOOGLE_CLIENT_SECRET")} do
      {id, secret} when is_binary(id) and is_binary(secret) ->
        Map.put(oauth_providers, "google",
          client_id: id,
          client_secret: secret,
          strategy: Assent.Strategy.Google
        )

      _ ->
        oauth_providers
    end

  if oauth_providers != %{} do
    config :kith, :oauth_providers, oauth_providers
  end

  config :kith, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  # Force SSL behind reverse proxy
  config :kith, KithWeb.Endpoint,
    force_ssl: [
      rewrite_on: [:x_forwarded_proto],
      exclude: [hosts: ["localhost", "127.0.0.1"]]
    ]

  # Email (production) — adapter selected via MAILER_ADAPTER env var
  mail_from = System.get_env("MAIL_FROM", "noreply@#{host}")
  config :kith, Kith.Mailer, from: mail_from
  config :swoosh, :api_client, Swoosh.ApiClient.Finch

  case System.get_env("MAILER_ADAPTER", "smtp") do
    "smtp" ->
      config :kith, Kith.Mailer,
        adapter: Swoosh.Adapters.SMTP,
        relay:
          System.get_env("SMTP_HOST") || raise("SMTP_HOST is required when MAILER_ADAPTER=smtp"),
        port: String.to_integer(System.get_env("SMTP_PORT", "587")),
        username: System.get_env("SMTP_USERNAME", ""),
        password: Kith.ConfigHelpers.read_secret("SMTP_PASSWORD") || "",
        ssl: System.get_env("SMTP_SSL") == "true",
        tls: :always,
        auth: :always,
        tls_options: [
          verify: :verify_peer,
          cacerts: :public_key.cacerts_get(),
          depth: 3,
          server_name_indication: String.to_charlist(System.get_env("SMTP_HOST") || ""),
          customize_hostname_check: [
            match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
          ]
        ]

    "mailgun" ->
      config :kith, Kith.Mailer,
        adapter: Swoosh.Adapters.Mailgun,
        api_key: System.get_env("MAILGUN_API_KEY") || raise("MAILGUN_API_KEY required"),
        domain: System.get_env("MAILGUN_DOMAIN") || raise("MAILGUN_DOMAIN required")

    "ses" ->
      config :kith, Kith.Mailer,
        adapter: Swoosh.Adapters.AmazonSES,
        region: System.get_env("AWS_REGION", "us-east-1"),
        access_key:
          Kith.ConfigHelpers.read_secret("AWS_ACCESS_KEY_ID") ||
            raise("AWS_ACCESS_KEY_ID required for SES"),
        secret:
          Kith.ConfigHelpers.read_secret("AWS_SECRET_ACCESS_KEY") ||
            raise("AWS_SECRET_ACCESS_KEY required for SES")

    "postmark" ->
      config :kith, Kith.Mailer,
        adapter: Swoosh.Adapters.Postmark,
        api_key: System.get_env("POSTMARK_API_KEY") || raise("POSTMARK_API_KEY required")

    invalid ->
      raise "Invalid MAILER_ADAPTER: #{inspect(invalid)}. Must be smtp, mailgun, ses, or postmark."
  end

  # Storage backend — set STORAGE_BACKEND=s3 to use S3/S3-compatible storage,
  # defaults to local disk.
  case System.get_env("STORAGE_BACKEND", "local") do
    "s3" ->
      config :ex_aws,
        http_client: ExAws.Request.Req,
        access_key_id: Kith.ConfigHelpers.read_secret("AWS_ACCESS_KEY_ID"),
        secret_access_key: Kith.ConfigHelpers.read_secret("AWS_SECRET_ACCESS_KEY"),
        region: System.get_env("AWS_REGION", "us-east-1")

      if endpoint = System.get_env("AWS_S3_ENDPOINT") do
        config :ex_aws, :s3,
          scheme: "http://",
          host: URI.parse(endpoint).host,
          port: URI.parse(endpoint).port
      end

      config :kith, Kith.Storage,
        backend: :s3,
        bucket: System.fetch_env!("AWS_S3_BUCKET")

    _ ->
      config :kith, Kith.Storage,
        backend: :local,
        path: System.get_env("STORAGE_PATH", "/app/uploads")
  end

  # Rate limiting — optional Redis backend
  if System.get_env("RATE_LIMIT_BACKEND") == "redis" do
    redis_url =
      System.get_env("REDIS_URL") ||
        raise "REDIS_URL is required when RATE_LIMIT_BACKEND=redis"

    config :hammer,
      backend: {Hammer.Backend.Redis, [expiry_ms: 60_000 * 60, redis_url: redis_url]}
  end

  # Oban — only the worker container processes jobs in production.
  # The web container can call `Oban.insert/1` to enqueue jobs, but
  # runs no queues or plugins (no cron, no pruner) — so it never claims
  # rows from `oban_jobs`. The worker container keeps the full config
  # from `config.exs`.
  #
  # Dev (`config_env() == :dev`) is unaffected: this block only runs in
  # `:prod`. Test env is pinned to `testing: :manual` in `config/test.exs`.
  case System.get_env("KITH_MODE", "web") do
    "worker" ->
      :ok

    _web ->
      config :kith, Oban, queues: false, plugins: false
  end

  # libcluster — connect this BEAM node to its peer(s) so Phoenix.PubSub
  # broadcasts span containers (web ↔ worker). Configure via
  # `KITH_CLUSTER_HOSTS` env var: comma-separated long node names, e.g.
  # `kith@app,kith@worker`. Leave unset to disable clustering (single-node).
  #
  # Each container must also set `RELEASE_DISTRIBUTION=name` and
  # `RELEASE_NODE=kith@<hostname>` so its actual node name matches the
  # name listed in `KITH_CLUSTER_HOSTS`. `RELEASE_COOKIE` must be shared.
  cluster_hosts =
    case System.get_env("KITH_CLUSTER_HOSTS") do
      nil ->
        []

      "" ->
        []

      str ->
        str
        |> String.split(",", trim: true)
        |> Enum.map(&(&1 |> String.trim() |> String.to_atom()))
    end

  if cluster_hosts != [] do
    config :libcluster,
      topologies: [
        kith: [
          strategy: Cluster.Strategy.Epmd,
          config: [hosts: cluster_hosts]
        ]
      ]
  end

  # Sentry error tracking (optional — only when SENTRY_DSN is set)
  if sentry_dsn = System.get_env("SENTRY_DSN") do
    config :sentry,
      dsn: sentry_dsn,
      environment_name: System.get_env("SENTRY_ENVIRONMENT", "production"),
      tags: %{
        app_version: to_string(Application.spec(:kith, :vsn) || "dev"),
        kith_mode: System.get_env("KITH_MODE", "web")
      },
      client: Kith.SentryReqClient,
      filter: Kith.SentryFilter,
      before_send: {Kith.SentryEventHandler, :before_send},
      enable_source_code_context: true
  end

  # Geolix — local MaxMind GeoLite2 database (optional)
  if geoip_path = System.get_env("GEOIP_DB_PATH") do
    config :geolix,
      databases: [
        %{id: :city, adapter: Geolix.Adapter.MMDB2, source: geoip_path}
      ]
  end

  # Trusted proxies for real IP extraction
  trusted_proxies =
    System.get_env("TRUSTED_PROXIES", "127.0.0.1/8")
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)

  config :remote_ip, headers: ~w[x-forwarded-for], proxies: trusted_proxies

  # Metrics endpoint authentication
  metrics_token =
    System.get_env("METRICS_TOKEN") ||
      raise "METRICS_TOKEN is required in production for /metrics endpoint"

  config :kith, metrics_token: metrics_token

  # Structured JSON logging in production
  config :logger, :default_handler,
    formatter:
      {LoggerJSON.Formatters.Basic, metadata: [:request_id, :user_id, :account_id, :reason]}
end
