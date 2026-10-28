defmodule KithWeb.DAV.AuthTest do
  @moduledoc "RFC 7617 — HTTP Basic Authentication for CardDAV."
  use KithWeb.ConnCase, async: true

  import Ecto.Query
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

  describe "verified-password cache" do
    # Production hashes at pbkdf2's default cost (~0.3 s per check); the test
    # env uses 1 round, so give this user a slow hash to see the difference.
    defp slow_hash_user(user) do
      hash = Pbkdf2.hash_pwd_salt(dav_password(), rounds: 300_000)

      Kith.Repo.update_all(
        from(u in Kith.Accounts.User, where: u.id == ^user.id),
        set: [hashed_password: hash]
      )

      Kith.Repo.get!(Kith.Accounts.User, user.id)
    end

    defp timed_propfind(email, password) do
      {us, conn} = :timer.tc(fn -> propfind_as(email, password) end)
      {div(us, 1000), conn.status}
    end

    test "a repeated successful Basic login does not rerun the password hash",
         %{user: user} do
      user = slow_hash_user(user)

      {first_ms, 207} = timed_propfind(user.email, dav_password())
      assert first_ms >= 50, "precondition: the slow hash must be measurable (#{first_ms} ms)"

      # Best of several cached logins: one slow sample under load can't fail it.
      second_ms =
        1..5
        |> Enum.map(fn _ ->
          {ms, 207} = timed_propfind(user.email, dav_password())
          ms
        end)
        |> Enum.min()

      assert second_ms < first_ms / 3, "cached login #{second_ms} ms vs first #{first_ms} ms"
    end

    test "a wrong password is still rejected after a cached success", %{user: user} do
      user = slow_hash_user(user)
      assert {_, 207} = timed_propfind(user.email, dav_password())
      assert {_, 401} = timed_propfind(user.email, dav_password() <> "x")
      assert {_, 207} = timed_propfind(user.email, dav_password())
    end

    test "a wrong password is never cached", %{user: user} do
      wrong = "never-cache-this-password"

      key =
        {:verified_password,
         :crypto.mac(
           :hmac,
           :sha256,
           :persistent_term.get({Kith.Accounts, :verified_password_key}, <<0::256>>),
           [user.hashed_password, 0, wrong]
         )}

      assert propfind_as(user.email, wrong).status == 401
      assert propfind_as(user.email, wrong).status == 401
      assert Cachex.get(:kith_cache, key) == {:ok, nil}
    end

    test "a changed password invalidates the cached login", %{user: user} do
      user = slow_hash_user(user)
      assert {_, 207} = timed_propfind(user.email, dav_password())

      new_hash = Pbkdf2.hash_pwd_salt("AnotherP@ssw0rd-123", rounds: 1)

      Kith.Repo.update_all(
        from(u in Kith.Accounts.User, where: u.id == ^user.id),
        set: [hashed_password: new_hash]
      )

      assert {_, 401} = timed_propfind(user.email, dav_password())
      assert {_, 207} = timed_propfind(user.email, "AnotherP@ssw0rd-123")
    end

    test "the cached digest cannot be recomputed from the hash and the password",
         %{user: user} do
      user = slow_hash_user(user)
      assert {_, 207} = timed_propfind(user.email, dav_password())

      {:ok, keys} = Cachex.keys(:kith_cache)

      plain =
        {:verified_password, :crypto.hash(:sha256, [user.hashed_password, 0, dav_password()])}

      assert Enum.any?(keys, &match?({:verified_password, _}, &1)), "login was not cached"
      refute plain in keys
    end

    test "deleting the user stops a cached login", %{user: user} do
      user = slow_hash_user(user)
      assert {_, 207} = timed_propfind(user.email, dav_password())

      Kith.Repo.delete_all(from(u in Kith.Accounts.User, where: u.id == ^user.id))

      assert {_, 401} = timed_propfind(user.email, dav_password())
    end

    test "a role change takes effect on the next request despite a cached login",
         %{user: user} do
      user = slow_hash_user(user)

      current_role = fn ->
        build_conn()
        |> basic_auth(user.email, dav_password())
        |> Kith.DAV.Auth.require_auth()
        |> Map.fetch!(:assigns)
        |> Map.fetch!(:current_scope)
        |> Map.fetch!(:user)
        |> Map.fetch!(:role)
      end

      set_role = fn role ->
        Kith.Repo.update_all(from(u in Kith.Accounts.User, where: u.id == ^user.id),
          set: [role: role]
        )
      end

      set_role.("viewer")
      assert current_role.() == "viewer"
      set_role.("editor")
      assert current_role.() == "editor"
      set_role.("viewer")
      assert current_role.() == "viewer"
      set_role.("admin")
      assert current_role.() == "admin"
    end

    test "unconfirming the user stops a cached login", %{user: user} do
      user = slow_hash_user(user)
      assert {_, 207} = timed_propfind(user.email, dav_password())

      Kith.Repo.update_all(from(u in Kith.Accounts.User, where: u.id == ^user.id),
        set: [confirmed_at: nil]
      )

      assert {_, 401} = timed_propfind(user.email, dav_password())
    end
  end

  describe "brute-force protection" do
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

    test "11th failure within the window gets 429 with Retry-After" do
      email = "cdv10-#{System.unique_integer([:positive])}@example.com"
      fail_times(email, 10)

      conn = propfind_as(email, "wrong-11")
      assert conn.status == 429
      [retry_after] = get_resp_header(conn, "retry-after")
      assert String.to_integer(retry_after) in 1..300
    end

    test "a locked IP+email stays locked even with the right password", %{user: user} do
      fail_times(user.email, 10)
      assert propfind_as(user.email, dav_password()).status == 429
      assert propfind_as(String.upcase(user.email), dav_password()).status == 429
    end

    test "another email from the same IP is unaffected" do
      locked = "cdv10-#{System.unique_integer([:positive])}@example.com"
      fail_times(locked, 10)
      assert propfind_as(locked, "wrong-11").status == 429
      other = Kith.AccountsFixtures.user_fixture()
      assert propfind_as(other.email, dav_password()).status == 207
    end

    test "requests without parseable credentials are never throttled" do
      for header <- [nil, "Bearer x", "Basic !!!", "Basic " <> Base.encode64("no-colon")],
          _ <- 1..11 do
        conn =
          if header, do: put_req_header(build_conn(), "authorization", header), else: build_conn()

        assert dav_request(conn, "PROPFIND", "/dav/").status == 401
      end
    end

    test "success clears the failure count", %{user: user} do
      for _ <- 1..15, do: assert(propfind_as(user.email, dav_password()).status == 207)

      fail_times(user.email, 9)
      assert propfind_as(user.email, dav_password()).status == 207
      fail_times(user.email, 10)
      assert propfind_as(user.email, "wrong").status == 429
    end
  end
end
