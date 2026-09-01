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
  #{@default_oban_pruner_max_age_days} days when unset, empty, or unparseable.
  Values below one day are clamped up to one day (with a warning) so a stray
  `0`/empty override cannot make the pruner delete `oban_jobs` rows almost
  immediately.

  Read at call time, so `config/runtime.exs` picks up the container's env at
  boot rather than the value baked in at release-build time.
  """
  def oban_pruner_max_age_seconds do
    "OBAN_PRUNER_MAX_AGE_DAYS"
    |> System.get_env()
    |> parse_pruner_max_age_days()
    |> Kernel.*(@seconds_per_day)
  end

  defp parse_pruner_max_age_days(nil), do: @default_oban_pruner_max_age_days

  defp parse_pruner_max_age_days(raw) do
    case raw |> String.trim() |> Integer.parse() do
      {days, ""} when days >= 1 ->
        days

      {days, ""} ->
        Logger.warning(
          "OBAN_PRUNER_MAX_AGE_DAYS=#{days} is below the 1-day minimum; clamping to 1 day"
        )

        1

      _ ->
        Logger.warning(
          "OBAN_PRUNER_MAX_AGE_DAYS=#{inspect(raw)} is not a whole number of days; " <>
            "using the #{@default_oban_pruner_max_age_days}-day default"
        )

        @default_oban_pruner_max_age_days
    end
  end
end
