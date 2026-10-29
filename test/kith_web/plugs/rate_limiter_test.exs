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

    assert Jason.decode!(json.resp_body) == %{
             "type" => "about:blank",
             "title" => "Too Many Requests",
             "status" => 429,
             "detail" => "Rate limit exceeded. Try again in 60 seconds."
           }

    html = request |> put_req_header("accept", "text/html;<script>") |> RateLimiter.call(opts)
    assert html.status == 429
    assert get_resp_header(html, "content-type") == ["text/html; charset=utf-8"]
    assert html.resp_body == "Too many requests. Please try again later."
    assert get_resp_header(html, "retry-after") == ["60"]
  end
end
