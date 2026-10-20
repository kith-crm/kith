defmodule KithWeb.DAV.AuthTest do
  @moduledoc "RFC 7617 — HTTP Basic Authentication for CardDAV."
  use KithWeb.ConnCase, async: true

  import KithWeb.DAV.TestHelpers

  setup :setup_dav_user

  describe "RFC 7617 §2 — Basic authentication scheme" do
    test "MUST return 401 when no Authorization header is present", %{conn: conn} do
      conn = dav_request(conn, "PROPFIND", "/dav/")
      assert conn.status == 401
    end

    test "401 response MUST include WWW-Authenticate header with Basic scheme and realm",
         %{conn: conn} do
      conn = dav_request(conn, "PROPFIND", "/dav/")
      [www_auth] = get_resp_header(conn, "www-authenticate")
      assert www_auth =~ ~r/Basic\s+realm=/i
    end

    test "MUST reject invalid credentials (wrong password)", %{conn: conn, user: user} do
      conn =
        conn
        |> basic_auth(user.email, "wrong-password")
        |> dav_request("PROPFIND", "/dav/")

      assert conn.status == 401
    end

    test "MUST reject malformed base64 in Authorization header", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Basic !!!invalid-base64!!!")
        |> dav_request("PROPFIND", "/dav/")

      assert conn.status == 401
    end

    test "MUST reject non-Basic authentication scheme", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer some-token")
        |> dav_request("PROPFIND", "/dav/")

      assert conn.status == 401
    end

    test "MUST accept valid base64(userid:password) credentials", context do
      conn = authed_dav(context, "PROPFIND", "/dav/")
      refute conn.status == 401
    end

    test "MUST reject unconfirmed user credentials", %{conn: conn, user: user} do
      import Ecto.Query

      Kith.Repo.update_all(from(u in Kith.Accounts.User, where: u.id == ^user.id),
        set: [confirmed_at: nil]
      )

      conn =
        conn
        |> basic_auth(user.email, dav_password())
        |> dav_request("PROPFIND", "/dav/")

      assert conn.status == 401
    end
  end

  describe "R7 — brute-force protection" do
    defp propfind_as(email, password) do
      build_conn()
      |> basic_auth(email, password)
      |> dav_request("PROPFIND", "/dav/")
    end

    defp fail_times(email, n) do
      for i <- 1..n do
        assert propfind_as(email, "wrong-#{i}").status == 401
      end
    end

    test "CDV-10: the 11th failed attempt for one IP+email is 429 with Retry-After" do
      email = "cdv10-#{System.unique_integer([:positive])}@example.com"
      fail_times(email, 10)

      conn = propfind_as(email, "wrong-11")
      assert conn.status == 429
      [retry_after] = get_resp_header(conn, "retry-after")
      assert String.to_integer(retry_after) in 1..300
    end

    test "CDV-10: a locked IP+email stays locked even with the right password", %{user: user} do
      fail_times(user.email, 10)
      assert propfind_as(user.email, dav_password()).status == 429
      assert propfind_as(String.upcase(user.email), dav_password()).status == 429
    end

    test "CDV-10: another email from the same IP is unaffected" do
      locked = "cdv10-#{System.unique_integer([:positive])}@example.com"
      fail_times(locked, 10)
      assert propfind_as(locked, "wrong-11").status == 429
      other = Kith.AccountsFixtures.user_fixture()
      assert propfind_as(other.email, dav_password()).status == 207
    end

    test "CDV-10: requests without parseable credentials are never throttled" do
      for header <- [nil, "Bearer x", "Basic !!!", "Basic " <> Base.encode64("no-colon")],
          _ <- 1..11 do
        conn =
          if header, do: put_req_header(build_conn(), "authorization", header), else: build_conn()

        assert dav_request(conn, "PROPFIND", "/dav/").status == 401
      end
    end

    test "CDV-10: successes are never throttled and reset the failure count", %{user: user} do
      for _ <- 1..15, do: assert(propfind_as(user.email, dav_password()).status == 207)

      fail_times(user.email, 9)
      assert propfind_as(user.email, dav_password()).status == 207
      fail_times(user.email, 10)
      assert propfind_as(user.email, "wrong").status == 429
    end
  end
end
