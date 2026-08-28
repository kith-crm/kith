defmodule Kith.ConfigHelpers do
  @moduledoc false

  require Logger

  def read_secret(env_var) do
    case System.get_env("#{env_var}_FILE") do
      nil -> System.get_env(env_var)
      file_path -> file_path |> String.trim() |> File.read!() |> String.trim()
    end
  end

  @default_oban_pruner_max_age_days 7
  @seconds_per_day 24 * 60 * 60

  @doc """
  Effective `Oban.Plugins.Pruner` `:max_age`, in **seconds**.

  Driven by the `OBAN_PRUNER_MAX_AGE_DAYS` env var (whole days), defaulting to
  #{@default_oban_pruner_max_age_days} days when unset. Values below one day are
  clamped up to one day (with a warning) so a stray `0`/empty override cannot
  make the pruner delete `oban_jobs` rows almost immediately.

  Read at call time, so `config/runtime.exs` picks up the container's env at
  boot rather than the value baked in at release-build time.
  """
  def oban_pruner_max_age_seconds do
    days =
      "OBAN_PRUNER_MAX_AGE_DAYS"
      |> System.get_env(Integer.to_string(@default_oban_pruner_max_age_days))
      |> String.to_integer()

    clamped =
      if days < 1 do
        Logger.warning(
          "OBAN_PRUNER_MAX_AGE_DAYS=#{days} is below the 1-day minimum; clamping to 1 day"
        )

        1
      else
        days
      end

    clamped * @seconds_per_day
  end
end
