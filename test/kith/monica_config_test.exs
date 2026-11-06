defmodule Kith.MonicaConfigTest do
  use ExUnit.Case, async: false

  setup do
    previous = System.get_env("MONICA_RATE_LIMIT_PER_MINUTE")

    on_exit(fn ->
      if previous,
        do: System.put_env("MONICA_RATE_LIMIT_PER_MINUTE", previous),
        else: System.delete_env("MONICA_RATE_LIMIT_PER_MINUTE")
    end)
  end

  test "unset runtime configuration preserves the environment default" do
    System.delete_env("MONICA_RATE_LIMIT_PER_MINUTE")
    runtime = Config.Reader.read!("config/runtime.exs", env: :dev, target: :host)
    assert get_in(runtime, [:kith, :monica_rate_limit]) == nil

    for {env, expected} <- [dev: 55, test: 1_000_000] do
      base = Config.Reader.read!("config/config.exs", env: env, target: :host)
      merged = Config.Reader.merge(base, runtime)
      assert get_in(merged, [:kith, :monica_rate_limit]) == expected
    end
  end

  test "explicit budgets above and below the fallback are loaded in dev and test" do
    for env <- [:dev, :test], limit <- [1, 25, 120] do
      System.put_env("MONICA_RATE_LIMIT_PER_MINUTE", to_string(limit))
      runtime = Config.Reader.read!("config/runtime.exs", env: env, target: :host)
      assert get_in(runtime, [:kith, :monica_rate_limit]) == limit
    end
  end

  test "invalid budgets fail startup with the option named" do
    for invalid <- ["", "0", "-1", "1.5", "55requests", " 55", "no"] do
      System.put_env("MONICA_RATE_LIMIT_PER_MINUTE", invalid)

      assert_raise RuntimeError,
                   ~r/MONICA_RATE_LIMIT_PER_MINUTE must be a positive integer/,
                   fn ->
                     Config.Reader.read!("config/runtime.exs", env: :dev, target: :host)
                   end
    end
  end

  test "supported Compose app and worker services forward the budget" do
    for {file, services} <- [
          {"docker-compose.dev.yml", ["app"]},
          {"docker-compose.prod.yml", ["app", "worker"]}
        ],
        service <- services do
      [_, config] =
        Regex.run(~r/^  #{service}:\n(.*?)(?=^  [a-z][a-z_-]*:|\z)/ms, File.read!(file))

      assert config =~ "      MONICA_RATE_LIMIT_PER_MINUTE: ${MONICA_RATE_LIMIT_PER_MINUTE:-55}"
    end
  end
end
