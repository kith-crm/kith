defmodule KithWeb.DAV.AuthTest do
  @moduledoc "RFC 7617 — HTTP Basic Authentication for CardDAV."
  use KithWeb.ConnCase, async: false

  import Ecto.Query
  import KithWeb.DAV.TestHelpers

  setup :setup_dav_user

  test "app passwords authorize DAV methods, isolate accounts, and revoke immediately", %{
    user: user
  } do
    user = %{user | authenticated_at: DateTime.utc_now(:second)}
    {:ok, row, credential} = Kith.Accounts.DavAppPasswords.create(user, %{name: "DAVx5"})

    request = fn method, path, body ->
      build_conn() |> basic_auth(user.email, credential) |> dav_request(method, path, body)
    end

    assert request.("PROPFIND", "/dav/", "").status == 207
    path = "/dav/addressbooks/default/app-password-test.vcf"

    assert request.(
             "PUT",
             path,
             build_vcard("App", "Password", uid: "e1f3f223-99e0-42cc-b99c-0a0102030405")
           ).status ==
             201

    assert request.("GET", path, "").status == 200
    assert request.("REPORT", "/dav/addressbooks/default/", sync_collection_body()).status == 207
    other = Kith.AccountsFixtures.user_fixture()
    contact = Kith.ContactsFixtures.contact_fixture(other.account_id, %{first_name: "SecretData"})
    foreign = contact_path(contact)

    for method <- ["GET", "DELETE", "PROPFIND"] do
      assert request.(method, foreign, "").status in [403, 404]
    end

    denied_write =
      build_conn()
      |> basic_auth(user.email, credential)
      |> put_req_header("if-match", "*")
      |> dav_request("PUT", foreign, build_vcard("Hacked", "Contact"))

    assert denied_write.status == 412
    assert Kith.Repo.get!(Kith.Contacts.Contact, contact.id).first_name == "SecretData"

    report = request.("REPORT", "/dav/addressbooks/default/", multiget_body([foreign]))
    assert report.status == 207
    assert report.resp_body =~ "404 Not Found"
    refute report.resp_body =~ "SecretData"
    assert request.("DELETE", path, "").status == 204
    assert :ok = Kith.Accounts.DavAppPasswords.revoke(user, row.id)
    assert request.("PROPFIND", "/dav/", "").status == 401
  end

  test "disabled passwords preserve app access and deny cached account passwords", %{user: user} do
    old = Application.fetch_env!(:kith, :auth)
    on_exit(fn -> Application.put_env(:kith, :auth, old) end)
    user = %{user | authenticated_at: DateTime.utc_now(:second)}
    {:ok, _, credential} = Kith.Accounts.DavAppPasswords.create(user, %{name: "DAV"})
    assert propfind_as(user.email, dav_password()).status == 207
    Application.put_env(:kith, :auth, %{old | password_login_enabled: false})
    assert propfind_as(user.email, dav_password()).status == 401
    assert propfind_as(user.email, credential).status == 207
  end

  test "app format never falls back even if it is the actual account password", %{user: user} do
    password = "kith_dav_malformed-account-password"

    Kith.Repo.update_all(from(u in Kith.Accounts.User, where: u.id == ^user.id),
      set: [hashed_password: Pbkdf2.hash_pwd_salt(password)]
    )

    assert propfind_as(user.email, password).status == 401
    for _ <- 1..9, do: assert(propfind_as(user.email, "kith_dav_bad").status == 401)
    assert propfind_as(user.email, "kith_dav_bad").status == 429
  end

  test "app passwords preserve viewer write restrictions and current roles", %{
    user: user,
    account_id: aid
  } do
    user = %{user | authenticated_at: DateTime.utc_now(:second)}
    {:ok, _, credential} = Kith.Accounts.DavAppPasswords.create(user, %{name: "Viewer"})
    contact = Kith.ContactsFixtures.contact_fixture(aid)
    path = contact_path(contact)

    request = fn method, body ->
      build_conn() |> basic_auth(user.email, credential) |> dav_request(method, path, body)
    end

    Kith.Repo.update_all(from(u in Kith.Accounts.User, where: u.id == ^user.id),
      set: [role: "viewer"]
    )

    assert request.("GET", "").status == 200
    assert request.("PUT", build_vcard("Updated", "Contact")).status == 403
    assert request.("DELETE", "").status == 403

    Kith.Repo.update_all(from(u in Kith.Accounts.User, where: u.id == ^user.id),
      set: [role: "admin"]
    )

    assert request.("DELETE", "").status == 204
  end

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
      assert Kith.Cache.get(key) == :miss
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

      key =
        {:verified_password,
         :crypto.mac(
           :hmac,
           :sha256,
           :persistent_term.get({Kith.Accounts, :verified_password_key}),
           [user.hashed_password, 0, dav_password()]
         )}

      plain =
        {:verified_password, :crypto.hash(:sha256, [user.hashed_password, 0, dav_password()])}

      assert Kith.Cache.get(key) == {:ok, true}
      assert Kith.Cache.get(plain) == :miss
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
