defmodule KithWeb.Plugs.CSPTest do
  use KithWeb.ConnCase, async: false

  setup do
    Kith.TestEnv.configure_s3()
  end

  test "img-src includes the S3 origin", %{conn: conn} do
    conn = KithWeb.Plugs.CSP.call(conn, KithWeb.Plugs.CSP.init([]))
    [csp] = Plug.Conn.get_resp_header(conn, "content-security-policy")
    assert csp =~ ~r/img-src [^;]*https:\/\/s3\.example\.com/
  end

  test "browser responses carry the nonce policy emitted by the custom plug", %{conn: conn} do
    conn = get(conn, "/users/log-in")
    assert conn.status == 200
    [csp] = Plug.Conn.get_resp_header(conn, "content-security-policy")
    assert csp =~ "default-src 'self'"
    assert csp =~ "script-src 'self' 'nonce-"
    assert csp =~ "frame-ancestors 'self'"
  end
end
