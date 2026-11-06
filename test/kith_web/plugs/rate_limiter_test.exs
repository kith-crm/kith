defmodule KithWeb.Plugs.RateLimiterTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  alias KithWeb.Plugs.RateLimiter

  test "denials use fixed MIME and bodies even with hostile URL and accept text" do
    key = "rate-limit-security-#{System.unique_integer([:positive])}"
    opts = RateLimiter.init(limit: 1, period: 60_000, key_fun: fn _ -> key end)
    request = Plug.Test.conn(:get, "/api/%3Cscript%3E")
    refute RateLimiter.call(request, opts).halted
    json = RateLimiter.call(request, opts)
    assert json.status == 429
    assert json.halted
    assert get_resp_header(json, "content-type") == ["application/problem+json; charset=utf-8"]
    [retry_header] = get_resp_header(json, "retry-after")
    retry_seconds = String.to_integer(retry_header)
    assert retry_seconds in 1..60

    assert Jason.decode!(json.resp_body) == %{
             "type" => "about:blank",
             "title" => "Too Many Requests",
             "status" => 429,
             "detail" => "Rate limit exceeded. Try again in #{retry_seconds} seconds."
           }

    html = request |> put_req_header("accept", "text/html;<script>") |> RateLimiter.call(opts)
    assert html.status == 429
    assert get_resp_header(html, "content-type") == ["text/html; charset=utf-8"]
    assert html.resp_body == "Too many requests. Please try again later."
    assert [html_retry] = get_resp_header(html, "retry-after")
    assert String.to_integer(html_retry) in 1..60
  end

  test "a sub-second window has a nonzero rounded-up retry header" do
    key = "rate-limit-rounding-#{System.unique_integer([:positive])}"
    opts = RateLimiter.init(limit: 1, period: 900, key_fun: fn _ -> key end)
    remaining = 900 - rem(System.system_time(:millisecond), 900)
    if remaining < 200, do: Process.sleep(remaining + 1)
    request = Plug.Test.conn(:get, "/api/rate-test")
    refute RateLimiter.call(request, opts).halted
    denied = RateLimiter.call(request, opts)
    assert denied.status == 429
    assert get_resp_header(denied, "retry-after") == ["1"]
  end
end
