defmodule KithWeb.Plugs.MetricsAuthTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias KithWeb.Plugs.MetricsAuth

  test "rejects a missing bearer token before reaching the exporter" do
    conn = conn(:get, "/metrics") |> MetricsAuth.call([])
    assert conn.status == 401
    assert conn.halted
    assert Jason.decode!(conn.resp_body) == %{"error" => "Invalid or missing metrics token"}
  end

  test "rejects an incorrect bearer token before reaching the exporter" do
    conn =
      conn(:get, "/metrics")
      |> put_req_header("authorization", "Bearer wrong-token")
      |> MetricsAuth.call([])

    assert conn.status == 401
    assert conn.halted
  end

  test "allows the configured bearer token to continue to the exporter" do
    conn =
      conn(:get, "/metrics")
      |> put_req_header("authorization", "Bearer test-metrics-token")
      |> MetricsAuth.call([])

    assert conn.status == nil
    refute conn.halted
  end
end

defmodule KithWeb.MetricsEndpointTest do
  use KithWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  test "disabled exporter returns exactly 503 after successful authentication", %{conn: conn} do
    log =
      capture_log(fn ->
        conn =
          conn |> put_req_header("authorization", "Bearer test-metrics-token") |> get("/metrics")

        assert response(conn, 503) == "Service Unavailable"
      end)

    assert log =~ "Kith.PromEx"
    assert log =~ "has not been initialized"
  end

  test "initialized exporter serves Prometheus metrics through the authenticated route", %{
    conn: conn
  } do
    # The Oban poller queries outside the sandbox. Its database integration is
    # separate from HTTP export; retain all other production metric collectors.
    Kith.TestEnv.put_env_restoring(:kith, Kith.PromEx,
      disabled: false,
      drop_metrics_groups: [:oban_queue_poll_metrics]
    )

    start_supervised!(Kith.PromEx)

    conn = conn |> put_req_header("authorization", "Bearer test-metrics-token") |> get("/metrics")
    body = response(conn, 200)
    assert get_resp_header(conn, "content-type") == ["text/plain; charset=utf-8"]
    assert body =~ "# HELP kith_prom_ex_"
    assert body =~ "# TYPE kith_prom_ex_"
    stop_supervised!(Kith.PromEx)
  end
end
