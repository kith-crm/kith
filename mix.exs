defmodule Kith.MixProject do
  use Mix.Project

  def project do
    [
      app: :kith,
      version: "0.1.0",
      elixir: ">= 1.15.1 and < 2.0.0",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      dialyzer: dialyzer(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      test_ignore_filters: [
        ~r"^test/fixtures/tls/transport_probe\.ex$",
        ~r"^test/fixtures/rate_limiter_redis/probe\.ex$",
        ~r"^test/playwright/seed\.exs$",
        ~r"^test/playwright/fixtures/regressions/(?:boot|control|server)\.exs$",
        ~r"^test/playwright/fixtures/s3/seed\.exs$"
      ],
      listeners: [Phoenix.CodeReloader]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Kith.Application, []},
      extra_applications: [:logger, :xmerl, :runtime_tools, :crypto]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # `:no_opaque` is project-wide on purpose. Every `Ecto.Multi` pipeline we
  # build trips `call_without_opaque`, and the cause is entirely upstream:
  # `Ecto.Multi`'s `names` field is typed `MapSet.t()`
  # (deps/ecto/lib/ecto/multi.ex:150), `MapSet.t/0` is opaque, and Dialyzer
  # constant-folds `Multi.new/0` to the literal `%Ecto.Multi{names: %MapSet{map:
  # %{}}}` — a structurally built MapSet where an opaque one is expected. Note
  # `Ecto.Multi`'s own `t/0` is NOT opaque, so this is not the "don't reach into
  # Multi's internals" case; we only ever go through `Multi.new/0` and
  # `Multi.run/3`.
  #
  # No code shape fixes it. Routing `Multi.new/0` through a `@spec _ ::
  # Multi.t()` boundary only relocates the warning to `contract_with_opaque`,
  # because `Multi.new/0`'s success typing cannot itself satisfy `Multi.t()`.
  # Ecto is already current (3.13.5), so a version bump is not the remedy
  # either.
  #
  # The cost of the project-wide flag over per-function escapes: a genuine
  # opaque-type misuse anywhere in the project goes unreported.
  defp dialyzer do
    [
      plt_file: {:no_warn, "priv/plts/dialyzer.plt"},
      plt_add_apps: [:mix, :ex_unit],
      flags: [:error_handling, :underspecs, :unknown, :no_opaque],
      ignore_warnings: ".dialyzer_ignore.exs"
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      # Core Phoenix
      {:phoenix, "~> 1.8.5"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.14"},
      {:postgrex, ">= 0.0.0"},
      {:phoenix_html, "~> 4.4"},
      {:plug, "~> 1.20.3"},
      {:phoenix_live_view, "~> 1.2.13"},
      {:phoenix_live_dashboard, "~> 0.9.1"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:libcluster, "~> 3.4"},
      {:bandit, "~> 1.5"},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},

      # Background Jobs
      {:oban, "~> 2.18"},
      {:oban_web, "~> 2.11"},

      # Email
      {:swoosh, "~> 1.17"},
      {:gen_smtp, "~> 1.2"},

      # Storage
      {:image, "~> 0.72"},
      {:ex_aws, "~> 2.7"},
      {:ex_aws_s3, "~> 2.5"},
      {:sweet_xml, "~> 0.7"},

      # HTTP Client
      {:req, "~> 0.7.5"},
      {:finch, "~> 0.21"},

      # Auth
      {:pot, "~> 1.0"},
      {:eqrcode, "~> 0.1"},
      {:wax_, "~> 0.6"},
      {:assent, "~> 0.3.2"},
      {:pbkdf2_elixir, "~> 2.2"},

      # Rate Limiting
      {:hammer, "~> 7.5"},
      {:hammer_backend_redis, "~> 7.2", optional: true},
      {:redix, "~> 1.10", optional: true},

      # Cache
      {:nebulex, "~> 3.1"},
      {:nebulex_local, "~> 3.1"},

      # i18n / CLDR / Timezone
      {:tz, "~> 0.28.4"},
      {:ex_cldr, "~> 2.47.5"},
      {:ex_cldr_dates_times, "~> 2.20"},
      # Keep the latest Calendars parent; its 2.4.x manifest currently requires
      # DigitalToken 1.x. Do not let resolution downgrade it to select token 2.x.
      {:ex_cldr_calendars, "~> 2.4.4"},
      {:ex_cldr_numbers, "~> 2.38.3"},
      {:ex_cldr_territories, "~> 2.9"},

      # Logging & Observability
      {:logger_json, "~> 7.0"},
      {:sentry, "~> 14.0"},
      {:prom_ex, "~> 1.12"},

      # Circuit Breaker
      {:fuse, "~> 2.5"},

      # IP Geolocation
      {:geolix, "~> 2.1"},
      {:geolix_adapter_mmdb2, "~> 0.7"},

      # HTML Sanitization (rich text from Trix editor)
      {:html_sanitize_ex, "~> 1.4"},

      # Phone number parsing & E.164 normalization (libphonenumber port)
      {:ex_phone_number, "~> 0.4"},

      # Server-side sorting, filtering, and pagination
      {:flop, "~> 0.29.1"},
      {:flop_phoenix, "~> 0.27.0"},

      # Dev/Test
      {:phoenix_live_reload, "~> 1.7", only: :dev},
      {:esbuild, "~> 0.10.1", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.5.2", runtime: Mix.env() == :dev},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:credo, "~> 1.7.19", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4.8", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.18.1", only: [:dev, :test], runtime: false},
      {:ex_machina, "~> 2.8.2", only: :test},
      {:mox, "~> 1.2", only: :test}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: [
        "deps.get",
        "ecto.setup",
        "assets.setup",
        "assets.vendor",
        "assets.build",
        "cmd npm install"
      ],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "assets.setup": [
        "cmd npm install --prefix assets",
        "tailwind.install --if-missing",
        "esbuild.install --if-missing"
      ],
      "assets.build": ["compile", "tailwind kith", "esbuild kith"],
      "assets.deploy": [
        "tailwind kith --minify",
        "esbuild kith --minify",
        "phx.digest"
      ],
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "format",
        "credo --strict",
        "test"
      ],
      quality: [
        "compile --warnings-as-errors",
        "format --check-formatted",
        "credo --strict",
        "run --no-start scripts/security/sobelow_check.exs",
        "dialyzer"
      ]
    ]
  end
end
