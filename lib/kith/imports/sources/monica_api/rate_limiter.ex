defmodule Kith.Imports.Sources.MonicaApi.RateLimiter do
  @moduledoc """
  Per-host token bucket for outbound Monica API calls.

  Configured at one token below Monica's documented default of 60 requests
  per minute, leaving a one-call safety margin so a small clock-skew or
  burst on Monica's side does not push us into the 429 window.

  Configurable via:

      config :kith, :monica_rate_limit, <integer>

  per-test overrides via `Application.put_env/3`.

  Hammer (already a dep) supplies the underlying token bucket; we use a
  bucket key per Monica host so independent Monica instances do not share
  a quota. Calls block the caller process via `Process.sleep/1` until a
  token is available, then return `:ok`.
  """

  @default_scale_ms 60_000
  @default_limit 55
  @default_retry_sleep_ms 1_100

  @spec wait!(String.t()) :: :ok
  def wait!(url_or_host) when is_binary(url_or_host) do
    bucket = bucket_key(url_or_host)
    limit = Application.get_env(:kith, :monica_rate_limit) || @default_limit
    scale_ms = Application.get_env(:kith, :monica_rate_limit_scale_ms) || @default_scale_ms

    retry_sleep_ms =
      Application.get_env(:kith, :monica_rate_limit_retry_sleep_ms) || @default_retry_sleep_ms

    case Hammer.check_rate(bucket, scale_ms, limit) do
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
