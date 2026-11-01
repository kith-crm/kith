defmodule KithWeb.Plugs.ApiRateLimiterTest do
  use ExUnit.Case, async: true

  import Plug.Conn

  alias KithWeb.Plugs.ApiRateLimiter

  test "account budgets and headers use the shared backend without affecting other accounts" do
    first = System.unique_integer([:positive])
    second = System.unique_integer([:positive])
    opts = ApiRateLimiter.init(limit: 1, period: 60_000)
    request = scoped_request(first)
    remaining_ms = 60_000 - rem(System.system_time(:millisecond), 60_000)
    if remaining_ms < 100, do: Process.sleep(remaining_ms + 1)

    allowed = ApiRateLimiter.call(request, opts)
    refute allowed.halted
    assert get_resp_header(allowed, "x-ratelimit-remaining") == ["0"]
    [reset] = get_resp_header(allowed, "x-ratelimit-reset")
    assert rem(String.to_integer(reset), 60) == 0

    denied = ApiRateLimiter.call(request, opts)
    assert denied.status == 429
    assert denied.halted
    assert get_resp_header(denied, "x-ratelimit-limit") == ["1"]
    assert get_resp_header(denied, "x-ratelimit-remaining") == ["0"]
    assert [retry_header] = get_resp_header(denied, "retry-after")
    assert String.to_integer(retry_header) in 1..60
    assert get_resp_header(denied, "x-ratelimit-reset") == [reset]

    assert Jason.decode!(denied.resp_body)["detail"] ==
             "Account API rate limit exceeded. Try again in #{retry_header} seconds."

    refute ApiRateLimiter.call(scoped_request(second), opts).halted
  end

  test "requests without account scope retain the existing pass-through behavior" do
    conn = Plug.Test.conn(:get, "/api/contacts")
    assert ApiRateLimiter.call(conn, ApiRateLimiter.init([])) == conn
  end

  defp scoped_request(account_id) do
    Plug.Test.conn(:get, "/api/contacts")
    |> assign(:current_scope, %{user: %{account_id: account_id}})
  end
end
