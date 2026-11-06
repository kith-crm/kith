defmodule Kith.RateLimiter.Redis do
  @moduledoc false
  use Hammer,
    backend: Hammer.Redis,
    algorithm: :fix_window,
    prefix: "kith:rate_limit",
    timeout: 5000

  def validate_version(connection) do
    case Redix.command(connection, ["INFO", "server"], timeout: 5000) do
      {:ok, information} ->
        validate_information(information)

      {:error, _reason} ->
        {:error, :redis_version_unavailable}
    end
  end

  defp validate_information(information) do
    case Regex.run(~r/^redis_version:(\d+)\./m, information) do
      [_, major] ->
        if String.to_integer(major) >= 7, do: :ok, else: {:error, :redis_7_required}

      _ ->
        {:error, :redis_version_unavailable}
    end
  end
end
