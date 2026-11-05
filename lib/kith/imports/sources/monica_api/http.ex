defmodule Kith.Imports.Sources.MonicaApi.HTTP do
  @moduledoc "Bounded Monica HTTP requests sharing the per-host attempt budget."

  alias Kith.Imports.Sources.MonicaApi.RateLimiter

  @doc """
  Performs a bounded GET with ordinary Req options and transport injection.

  The optional `:on_rate_limit` callback runs synchronously in the caller for
  every attempt, receiving `(:before_wait, 0)` and `(:after_wait, elapsed_ms)`.
  It can check cancellation or account for limiter wait time. Its return value
  is ignored; raising or throwing aborts the request. Elapsed time covers only
  acquisition, excluding the callback and Req's retry backoff.
  """
  def get(url, options) do
    {on_rate_limit, options} = Keyword.pop(options, :on_rate_limit)

    url
    |> Kith.BoundedHTTP.new(options)
    # Req 0.7.5 retry and redirect steps call Request.run_request/1 again with
    # the request steps intact. Appending here runs after URL preparation and
    # immediately before every adapter dispatch, including injected Plug or
    # custom adapters. An outer wait would miss retries and redirect hosts.
    |> Req.Request.append_request_steps(monica_rate_limit: &wait(&1, on_rate_limit))
    |> Req.get()
  end

  defp wait(request, callback) do
    notify(callback, :before_wait, 0)
    started_at = System.monotonic_time()
    RateLimiter.wait!(URI.to_string(request.url))
    elapsed = System.monotonic_time() - started_at
    notify(callback, :after_wait, System.convert_time_unit(elapsed, :native, :millisecond))
    request
  end

  defp notify(nil, _phase, _elapsed), do: :ok
  defp notify(callback, phase, elapsed), do: callback.(phase, elapsed)
end
