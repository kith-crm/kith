defmodule Kith.MixProject do
  use Mix.Project

  def project do
    [
      app: :kith,
      version: "0.1.0",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      dialyzer: dialyzer(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Kith.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  defp dialyzer do
    [
      plt_file: {:no_warn, "priv/plts/dialyzer.plt"},
      plt_add_apps: [:mix, :ex_unit],
      flags: [:error_handling, :underspecs, :unknown],
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
      {:ecto_sql, "~> 3.13"},
      {:postgrex, ">= 0.0.0"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_view, "~> 1.1.0"},
      {:phoenix_live_dashboard, "~> 0.8.3"},
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
      {:ex_aws, "~> 2.5"},
      {:ex_aws_s3, "~> 2.5"},
      {:sweet_xml, "~> 0.7"},

      # HTTP Client
      {:req, "~> 0.5"},
      {:finch, "~> 0.18"},

      # Auth
      {:pot, "~> 1.0"},
      {:eqrcode, "~> 0.1"},
      {:wax_, "~> 0.6"},
      {:assent, "~> 0.2"},
      {:pbkdf2_elixir, "~> 2.2"},

      # Rate Limiting
      {:hammer, "~> 6.2"},
      {:redix, "~> 1.5", optional: true},

      # Cache
      {:cachex, "~> 4.0"},

      # i18n / CLDR / Timezone
      {:tz, "~> 0.28"},
      {:ex_cldr, "~> 2.40"},
      {:ex_cldr_dates_times, "~> 2.20"},
      {:ex_cldr_numbers, "~> 2.33"},
      {:ex_cldr_territories, "~> 2.9"},

      # Logging & Observability
      {:logger_json, "~> 6.0"},
      {:sentry, "~> 10.8"},
      {:prom_ex, "~> 1.9"},

      # Circuit Breaker
      {:fuse, "~> 2.5"},

      # Encryption
      {:cloak_ecto, "~> 1.3"},

      # IP Geolocation
      {:geolix, "~> 2.0"},
      {:geolix_adapter_mmdb2, "~> 0.6"},

      # Security
      {:plug_content_security_policy, "~> 0.2"},
      {:remote_ip, "~> 1.2"},

      # HTML Sanitization (rich text from Trix editor)
      {:html_sanitize_ex, "~> 1.4"},

      # Phone number parsing & E.164 normalization (libphonenumber port)
      {:ex_phone_number, "~> 0.4"},

      # Server-side sorting, filtering, and pagination
      {:flop, "~> 0.26"},
      {:flop_phoenix, "~> 0.23"},

      # Dev/Test
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.3", runtime: Mix.env() == :dev},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.13", only: [:dev, :test], runtime: false},
      {:ex_machina, "~> 2.8", only: :test},
      {:mox, "~> 1.2", only: :test},
      {:wallaby, "~> 0.30", only: :test, runtime: false}
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
        "sobelow --config",
        "dialyzer"
      ]
    ]
  end
end
