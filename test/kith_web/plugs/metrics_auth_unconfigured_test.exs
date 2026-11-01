defmodule KithWeb.Plugs.MetricsAuthUnconfiguredTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  test "unset and blank configuration reject with an explicit JSON response" do
    previous = Application.fetch_env!(:kith, :metrics_token)
    on_exit(fn -> Application.put_env(:kith, :metrics_token, previous) end)

    for token <- [nil, ""] do
      Application.put_env(:kith, :metrics_token, token)
      conn = conn(:get, "/metrics") |> KithWeb.Plugs.MetricsAuth.call([])

      assert conn.status == 401
      assert conn.halted
      assert get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]
      assert Jason.decode!(conn.resp_body) == %{"error" => "Metrics endpoint not configured"}
    end
  end
end
