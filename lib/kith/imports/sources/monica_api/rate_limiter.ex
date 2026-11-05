defmodule Kith.Imports.Sources.MonicaApi.RateLimiter do
  @moduledoc """
  Per-host fixed-window request budget for outbound Monica API calls.

  The fallback is 55 attempts per minute, five below Monica's usual 60/min
  default. Set the budget below the server's actual configured limit, allowing
  headroom for other clients. Retries and redirect hops also consume slots.

  Configurable via:

      config :kith, :monica_rate_limit, <integer>

  which `config/runtime.exs` sets from `MONICA_RATE_LIMIT_PER_MINUTE`.
  Per-test overrides go through `Application.put_env/3`.

  The shared supervised Hammer backend supplies the fixed-window counter; we use a
  bucket key per actual request host (scheme, port, account and API key do not
  create separate quotas). ETS counters are node-local; Redis counters are
  shared by nodes using the same Redis backend. Calls block via
  `Process.sleep/1` until a token is available, then return `:ok`.
  """

  @default_scale_ms 60_000
  @default_limit 55
  @default_retry_sleep_ms 1_100

  @doc "The configured request budget per `scale_ms` window (per minute by default)."
  @spec limit() :: pos_integer()
  def limit, do: Application.get_env(:kith, :monica_rate_limit) || @default_limit

  @spec wait!(String.t()) :: :ok
  def wait!(url_or_host) when is_binary(url_or_host) do
    bucket = bucket_key(url_or_host)
    limit = limit()
    scale_ms = Application.get_env(:kith, :monica_rate_limit_scale_ms) || @default_scale_ms

    retry_sleep_ms =
      Application.get_env(:kith, :monica_rate_limit_retry_sleep_ms) || @default_retry_sleep_ms

    case Kith.RateLimiter.hit(bucket, scale_ms, limit) do
      {:allow, _count} ->
        :ok

      {:deny, _retry_after_ms} ->
        Process.sleep(retry_sleep_ms)
        wait!(url_or_host)
    end
  end

  defp bucket_key(url_or_host) do
    host = URI.parse(url_or_host).host || url_or_host
    "monica_api:#{host}"
  end
end
