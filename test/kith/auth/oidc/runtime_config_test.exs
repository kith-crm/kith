defmodule Kith.Auth.OIDC.RuntimeConfigTest do
  use ExUnit.Case, async: false

  test "production workers schedule auth-flow cleanup while web nodes do not run plugins" do
    script = """
    Mix.start()
    Code.require_file("mix.exs")
    base = Config.Reader.read!("config/config.exs", env: :prod, target: :host)
    System.put_env("KITH_MODE", "worker")
    worker = Config.Reader.merge(base, Config.Reader.read!("config/runtime.exs", env: :prod, target: :host))
    cron = worker[:kith][Oban][:plugins][Oban.Plugins.Cron][:crontab]
    System.put_env("KITH_MODE", "web")
    web = Config.Reader.merge(base, Config.Reader.read!("config/runtime.exs", env: :prod, target: :host))
    IO.inspect({{"*/5 * * * *", Kith.Workers.PurgeAuthFlowsWorker} in cron, web[:kith][Oban][:plugins] == false})
    """

    paths = Enum.flat_map(Path.wildcard("_build/test/lib/*/ebin"), &["-pa", &1])

    env = [
      {"DATABASE_URL", "ecto://test:test@localhost/unused_config_probe"},
      {"DATABASE_URL_FILE", nil},
      {"SECRET_KEY_BASE", String.duplicate("test-only", 8)},
      {"SECRET_KEY_BASE_FILE", nil},
      {"CLOAK_KEY", Base.encode64(String.duplicate("x", 32))},
      {"CLOAK_KEY_FILE", nil},
      {"METRICS_TOKEN", "test-only"},
      {"MAILER_ADAPTER", "smtp"},
      {"SMTP_HOST", "localhost"},
      {"OIDC_ENABLED", "false"},
      {"PASSWORD_LOGIN_ENABLED", "true"},
      {"REGISTRATION_ENABLED", "true"},
      {"DISABLE_SIGNUP", "false"},
      {"SENTRY_DSN", nil},
      {"SENTRY_DSN_FILE", nil}
    ]

    assert {"{true, true}\n", 0} = System.cmd("elixir", paths ++ ["-e", script], env: env)
  end
end
