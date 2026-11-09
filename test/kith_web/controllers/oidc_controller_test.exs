defmodule KithWeb.OIDCControllerTest do
  use KithWeb.ConnCase, async: false

  setup do
    old = Application.fetch_env!(:kith, :auth)
    Application.put_env(:kith, :auth, %{old | oidc_enabled: false})
    on_exit(fn -> Application.put_env(:kith, :auth, old) end)
    :ok
  end

  test "disabled OIDC rejects direct starts and callbacks", %{conn: conn} do
    conn = get(conn, "/auth/oidc")
    refute redirected_to(conn) =~ "issuer.test"

    refute get_resp_header(conn, "set-cookie")
           |> Enum.any?(&String.contains?(&1, "__Host-kith_oidc="))

    callback =
      get(build_conn(), "/auth/oidc/callback", %{"code" => "untrusted", "state" => "unknown"})

    refute get_session(callback, :user_token)

    assert Phoenix.Flash.get(callback.assigns.flash, :error) ==
             "OpenID Connect is unavailable. Please try again."
  end

  describe "enabled provider" do
    setup do
      fixture = Kith.OIDCFixture.start()
      old_endpoint = Application.fetch_env!(:kith, KithWeb.Endpoint)

      Application.put_env(
        :kith,
        KithWeb.Endpoint,
        Keyword.put(old_endpoint, :url, scheme: "https", host: "kith.test", port: 443)
      )

      KithWeb.Endpoint.config_change(
        [{KithWeb.Endpoint, Application.fetch_env!(:kith, KithWeb.Endpoint)}],
        []
      )

      old = Application.fetch_env!(:kith, :auth)

      Application.put_env(:kith, :auth, %{
        old
        | oidc_enabled: true,
          oidc: fixture.config ++ [display_name: "Example identity"]
      })

      on_exit(fn ->
        Kith.OIDCFixture.stop(fixture)
        Application.put_env(:kith, KithWeb.Endpoint, old_endpoint)
        KithWeb.Endpoint.config_change([{KithWeb.Endpoint, old_endpoint}], [])
      end)

      %{fixture: fixture}
    end

    test "signed Lax binding completes known identity without Strict session and rejects replay",
         %{conn: conn, fixture: fixture} do
      user = known_user(fixture)
      start = get(conn, "/auth/oidc")
      cookie = start.resp_cookies["__Host-kith_oidc"]

      assert cookie.secure and cookie.http_only and cookie.same_site == "Lax" and
               cookie.path == "/"

      params = authorize(start, fixture)
      callback = callback_conn(start) |> get("/auth/oidc/callback", params)

      assert {resolved, _} =
               Kith.Accounts.get_user_by_session_token(get_session(callback, :user_token))

      assert resolved.id == user.id
      assert redirected_to(callback) == "/dashboard"
      assert get_resp_header(callback, "cache-control") == ["no-store"]
      assert get_resp_header(callback, "referrer-policy") == ["no-referrer"]
      replay = callback_conn(start) |> get("/auth/oidc/callback", params)
      refute get_session(replay, :user_token)
    end

    test "unknown identity requires terms completion and ignores injected identity", %{
      conn: conn,
      fixture: fixture
    } do
      start = get(conn, "/auth/oidc")
      callback = callback_conn(start) |> get("/auth/oidc/callback", authorize(start, fixture))
      assert redirected_to(callback) == "/users/oidc/register"
      refute get_session(callback, :user_token)
      refute Kith.Accounts.get_user_by_email("person@example.test")

      complete =
        recycle(callback)
        |> post("/users/oidc/register", %{
          "user" => %{"tos_accepted" => "true", "email" => "attacker@example.test"}
        })

      assert get_session(complete, :user_token)
      assert Kith.Accounts.get_user_by_email("person@example.test")
      refute Kith.Accounts.get_user_by_email("attacker@example.test")

      refute recycle(callback)
             |> post("/users/oidc/register", %{"user" => %{"tos_accepted" => "true"}})
             |> get_session(:user_token)
    end

    test "denial consumes state without redeeming a code and missing or tampered cookies fail", %{
      conn: conn,
      fixture: fixture
    } do
      start = get(conn, "/auth/oidc")
      params = authorize(start, fixture)

      deny =
        callback_conn(start)
        |> get("/auth/oidc/callback", Map.put(params, "error", "access_denied"))

      refute get_session(deny, :user_token)

      refute Enum.any?(Kith.OIDCFixture.requests(fixture), fn {path, _, _} -> path == "/token" end)

      refute callback_conn(start)
             |> get("/auth/oidc/callback", params)
             |> get_session(:user_token)

      refute build_conn() |> get("/auth/oidc/callback", params) |> get_session(:user_token)
    end

    test "link restores the initiating user without Strict cookie and requests fresh authentication",
         %{conn: conn, fixture: fixture} do
      user = Kith.AccountsFixtures.user_fixture()
      Kith.OIDCFixture.update(fixture, %{claims: %{"auth_time" => System.os_time(:second)}})
      start = conn |> log_in_user(user) |> post("/users/oidc/link", %{"user_id" => "999"})
      assert URI.decode_query(URI.parse(redirected_to(start)).query)["max_age"] == "0"
      result = callback_conn(start) |> get("/auth/oidc/callback", authorize(start, fixture))

      assert {resolved, _} =
               Kith.Accounts.get_user_by_session_token(get_session(result, :user_token))

      assert resolved.id == user.id
      assert [%{subject: "subject"}] = Kith.Accounts.OIDC.list(user)
      assert redirected_to(result) == "/settings/security"
    end

    test "logged out originating link cannot complete", %{conn: conn, fixture: fixture} do
      user = Kith.AccountsFixtures.user_fixture()
      Kith.OIDCFixture.update(fixture, %{claims: %{"auth_time" => System.os_time(:second)}})
      start = conn |> log_in_user(user) |> post("/users/oidc/link")
      params = authorize(start, fixture)
      recycle(start) |> delete("/users/log-out")
      result = callback_conn(start) |> get("/auth/oidc/callback", params)
      refute get_session(result, :user_token)
      assert Kith.Accounts.OIDC.list(user) == []
    end

    test "parallel starts share cancellation identity and logout revokes a saved callback", %{
      conn: conn,
      fixture: fixture
    } do
      known_user(fixture)
      first = get(conn, "/auth/oidc")
      second = recycle(first) |> get("/auth/oidc")
      params = authorize(second, fixture)
      done = callback_conn(first) |> get("/auth/oidc/callback", authorize(first, fixture))

      assert get_session(done, :auth_challenge_binding) ==
               get_session(second, :auth_challenge_binding)

      recycle(done) |> delete("/users/log-out")

      refute callback_conn(second)
             |> get("/auth/oidc/callback", params)
             |> get_session(:user_token)
    end

    test "MFA grants no session until local verification and preserves cancellation identity", %{
      conn: conn,
      fixture: fixture
    } do
      user = known_user(fixture)
      secret = Kith.Accounts.generate_totp_secret()

      {:ok, _} =
        Kith.Accounts.enable_totp(
          %{user | authenticated_at: DateTime.utc_now(:second)},
          secret,
          :pot.totp(secret)
        )

      start = get(conn, "/auth/oidc")
      pending = callback_conn(start) |> get("/auth/oidc/callback", authorize(start, fixture))
      assert redirected_to(pending) == "/users/two-factor"
      refute get_session(pending, :user_token)

      assert get_session(pending, :auth_challenge_binding) ==
               get_session(start, :auth_challenge_binding)

      done =
        recycle(pending)
        |> post("/users/totp-verify", %{
          "totp_token" => get_session(pending, :totp_token),
          "totp" => %{"code" => :pot.totp(secret)}
        })

      assert get_session(done, :user_token)

      assert get_session(done, :auth_challenge_binding) ==
               get_session(start, :auth_challenge_binding)
    end

    test "reauthentication cannot switch user and fresh same-user flow succeeds", %{
      conn: conn,
      fixture: fixture
    } do
      user = known_user(fixture)
      Kith.OIDCFixture.update(fixture, %{claims: %{"auth_time" => System.os_time(:second)}})
      start = conn |> log_in_user(user) |> post("/users/oidc/reauth")
      done = callback_conn(start) |> get("/auth/oidc/callback", authorize(start, fixture))
      assert {same, _} = Kith.Accounts.get_user_by_session_token(get_session(done, :user_token))
      assert same.id == user.id
      other = Kith.AccountsFixtures.user_fixture()
      mismatch = build_conn() |> log_in_user(other) |> post("/users/oidc/reauth")
      denied = callback_conn(mismatch) |> get("/auth/oidc/callback", authorize(mismatch, fixture))
      refute get_session(denied, :user_token)
    end

    test "stale linking and missing fresh provider auth_time fail", %{
      conn: conn,
      fixture: fixture
    } do
      user = Kith.AccountsFixtures.user_fixture()

      stale =
        conn
        |> log_in_user(user,
          token_authenticated_at: DateTime.add(DateTime.utc_now(:second), -601)
        )
        |> post("/users/oidc/link")

      assert redirected_to(stale) == "/users/log-in"
      start = build_conn() |> log_in_user(user) |> post("/users/oidc/link")
      denied = callback_conn(start) |> get("/auth/oidc/callback", authorize(start, fixture))
      refute get_session(denied, :user_token)
      assert Kith.Accounts.OIDC.list(user) == []
    end

    test "GET login cannot turn into linking and email collisions never take over", %{
      conn: conn,
      fixture: fixture
    } do
      user = Kith.AccountsFixtures.user_fixture(%{email: "person@example.test"})

      start =
        conn
        |> log_in_user(user)
        |> get("/auth/oidc", %{"intent" => "link", "user_id" => user.id})

      denied = callback_conn(start) |> get("/auth/oidc/callback", authorize(start, fixture))
      assert Phoenix.Flash.get(denied.assigns.flash, :error) =~ "existing account"
      assert Kith.Accounts.OIDC.list(user) == []
      refute get_session(denied, :user_token)
    end

    test "signup policy is rechecked before completion and saved terms cookies die at logout", %{
      conn: conn,
      fixture: fixture
    } do
      start = get(conn, "/auth/oidc")
      pending = callback_conn(start) |> get("/auth/oidc/callback", authorize(start, fixture))
      config = Application.fetch_env!(:kith, :auth)
      Application.put_env(:kith, :auth, %{config | registration_enabled: false})

      denied =
        recycle(pending) |> post("/users/oidc/register", %{"user" => %{"tos_accepted" => "true"}})

      refute get_session(denied, :user_token)
      refute Kith.Accounts.get_user_by_email("person@example.test")
      Application.put_env(:kith, :auth, config)
      recycle(pending) |> delete("/users/log-out")

      denied =
        recycle(pending) |> post("/users/oidc/register", %{"user" => %{"tos_accepted" => "true"}})

      refute get_session(denied, :user_token)
      refute Kith.Accounts.get_user_by_email("person@example.test")
    end

    test "required terms cannot be skipped but can be corrected", %{conn: conn, fixture: fixture} do
      old = Application.get_env(:kith, :require_tos_acceptance)
      Application.put_env(:kith, :require_tos_acceptance, true)
      on_exit(fn -> Application.put_env(:kith, :require_tos_acceptance, old) end)
      start = get(conn, "/auth/oidc")
      pending = callback_conn(start) |> get("/auth/oidc/callback", authorize(start, fixture))
      missing = recycle(pending) |> post("/users/oidc/register", %{"user" => %{}})
      assert redirected_to(missing) == "/users/oidc/register"
      refute Kith.Accounts.get_user_by_email("person@example.test")

      done =
        recycle(missing) |> post("/users/oidc/register", %{"user" => %{"tos_accepted" => "true"}})

      assert get_session(done, :user_token)
    end

    test "expired terms cannot provision and encrypted pending payload stores no plaintext claims",
         %{conn: conn, fixture: fixture} do
      import Ecto.Query
      start = get(conn, "/auth/oidc")
      pending = callback_conn(start) |> get("/auth/oidc/callback", authorize(start, fixture))

      %{rows: [[payload]]} =
        Kith.Repo.query!("SELECT payload FROM oidc_transactions WHERE intent = 'registration'")

      refute :binary.match(payload, "person@example.test") != :nomatch

      Kith.Repo.update_all(
        from(t in Kith.Auth.OIDC.Transaction, where: t.intent == :registration),
        set: [expires_at: DateTime.add(DateTime.utc_now(), -1)]
      )

      denied =
        recycle(pending) |> post("/users/oidc/register", %{"user" => %{"tos_accepted" => "true"}})

      refute get_session(denied, :user_token)
      refute Kith.Accounts.get_user_by_email("person@example.test")
    end

    test "broken issuer and missing state fail without leaking query credentials", %{
      conn: conn,
      fixture: fixture
    } do
      start = get(conn, "/auth/oidc")
      params = authorize(start, fixture)
      config = Application.fetch_env!(:kith, :auth)

      Application.put_env(:kith, :auth, %{
        config
        | oidc: Keyword.put(config.oidc, :issuer, "https://other.test")
      })

      denied = callback_conn(start) |> get("/auth/oidc/callback", params)
      assert redirected_to(denied) == "/users/log-in"
      refute denied.resp_body =~ params["code"]
      missing = callback_conn(start) |> get("/auth/oidc/callback", %{"code" => "secret-marker"})
      refute get_session(missing, :user_token)
      assert redirected_to(missing) == "/users/log-in"
    end

    test "link, reauth and registration posts require CSRF", %{conn: conn} do
      user = Kith.AccountsFixtures.user_fixture()

      for path <- ["/users/oidc/link", "/users/oidc/reauth", "/users/oidc/register"] do
        protected = conn |> log_in_user(user) |> put_private(:plug_skip_csrf_protection, false)
        assert_error_sent 403, fn -> post(protected, path, %{}) end
      end
    end

    test "cancelled terms handle cannot be submitted with an old cookie", %{
      conn: conn,
      fixture: fixture
    } do
      start = get(conn, "/auth/oidc")
      pending = callback_conn(start) |> get("/auth/oidc/callback", authorize(start, fixture))
      cancelled = recycle(pending) |> post("/users/oidc/register", %{"cancel" => "true"})
      assert redirected_to(cancelled) == "/users/log-in"

      refute recycle(pending)
             |> post("/users/oidc/register", %{"user" => %{"tos_accepted" => "true"}})
             |> get_session(:user_token)
    end

    test "unusable provider email gives an actionable error before terms", %{
      conn: conn,
      fixture: fixture
    } do
      Kith.OIDCFixture.update(fixture, %{claims: %{"email" => "invalid-email"}})
      start = get(conn, "/auth/oidc")
      denied = callback_conn(start) |> get("/auth/oidc/callback", authorize(start, fixture))
      assert redirected_to(denied) == "/users/log-in"
      assert Phoenix.Flash.get(denied.assigns.flash, :error) =~ "verified email"
    end

    test "parallel terms forms retain their own identity when another tab changes the session", %{
      conn: conn,
      fixture: fixture
    } do
      first = get(conn, "/auth/oidc")
      pending_a = callback_conn(first) |> get("/auth/oidc/callback", authorize(first, fixture))
      handle_a = get_session(pending_a, :oidc_registration)

      Kith.OIDCFixture.update(fixture, %{
        claims: %{"sub" => "second", "email" => "second@example.test"}
      })

      second = recycle(pending_a) |> get("/auth/oidc")
      pending_b = callback_conn(second) |> get("/auth/oidc/callback", authorize(second, fixture))

      done_a =
        recycle(pending_b)
        |> post("/users/oidc/register", %{
          "registration_token" => handle_a,
          "user" => %{"tos_accepted" => "true"}
        })

      assert {user, _} = Kith.Accounts.get_user_by_session_token(get_session(done_a, :user_token))
      assert user.email == "person@example.test"
      refute Kith.Accounts.get_user_by_email("second@example.test")
    end

    test "email collision during pending terms is actionable and never links", %{
      conn: conn,
      fixture: fixture
    } do
      start = get(conn, "/auth/oidc")
      pending = callback_conn(start) |> get("/auth/oidc/callback", authorize(start, fixture))
      user = Kith.AccountsFixtures.user_fixture(%{email: "person@example.test"})

      denied =
        recycle(pending) |> post("/users/oidc/register", %{"user" => %{"tos_accepted" => "true"}})

      assert Phoenix.Flash.get(denied.assigns.flash, :error) =~ "existing account"
      assert Kith.Accounts.OIDC.list(user) == []
      refute get_session(denied, :user_token)
    end

    test "callback with a different active local user does not restore link ownership", %{
      conn: conn,
      fixture: fixture
    } do
      user = Kith.AccountsFixtures.user_fixture()
      other = Kith.AccountsFixtures.user_fixture()
      Kith.OIDCFixture.update(fixture, %{claims: %{"auth_time" => System.os_time(:second)}})
      start = conn |> log_in_user(user) |> post("/users/oidc/link")

      callback =
        callback_conn(start)
        |> log_in_user(other)
        |> get("/auth/oidc/callback", authorize(start, fixture))

      assert Kith.Accounts.OIDC.list(user) == []
      assert redirected_to(callback) == "/users/log-in"
    end

    test "tampered binding cannot redeem and valid original binding still completes", %{
      conn: conn,
      fixture: fixture
    } do
      known_user(fixture)
      start = get(conn, "/auth/oidc")
      params = authorize(start, fixture)

      bad =
        build_conn()
        |> put_req_cookie(
          "__Host-kith_oidc",
          "tampered" <> start.resp_cookies["__Host-kith_oidc"].value
        )
        |> get("/auth/oidc/callback", params)

      refute get_session(bad, :user_token)

      refute Enum.any?(Kith.OIDCFixture.requests(fixture), fn {path, _, _} -> path == "/token" end)

      assert callback_conn(start)
             |> get("/auth/oidc/callback", params)
             |> get_session(:user_token)
    end

    test "unavailable discovery fails closed without a binding cookie", %{
      conn: conn,
      fixture: fixture
    } do
      Kith.OIDCFixture.update(fixture, %{
        behavior: %{"/.well-known/openid-configuration" => {:status, 500}}
      })

      failed = get(conn, "/auth/oidc")
      assert redirected_to(failed) == "/users/log-in"
      refute failed.resp_cookies["__Host-kith_oidc"]
    end

    test "application callback logs omit query credentials and errors redirect locally", %{
      conn: conn,
      fixture: fixture
    } do
      known_user(fixture)
      start = get(conn, "/auth/oidc", %{"return_to" => "https://attacker.test"})
      params = authorize(start, fixture)

      previous_level = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: previous_level) end)

      output =
        ExUnit.CaptureLog.capture_log([level: :debug], fn ->
          done = callback_conn(start) |> get("/auth/oidc/callback", params)
          assert redirected_to(done) == "/dashboard"
        end)

      assert output =~ "Processing with KithWeb.OIDCController.callback/2"
      refute output =~ params["code"]
      refute output =~ params["state"]
      refute output =~ get_session(start, :auth_challenge_binding)
    end

    test "provider denial logs filter complete opaque diagnostics", %{
      conn: conn,
      fixture: fixture
    } do
      start = get(conn, "/auth/oidc")

      params =
        authorize(start, fixture)
        |> Map.merge(%{
          "error" => "access_denied",
          "error_description" => "Rejected credential CREDENTIALMARK",
          "error_uri" => "https://issuer.test/diagnostics/URICREDENTIALMARK"
        })

      previous_level = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: previous_level) end)

      output =
        ExUnit.CaptureLog.capture_log([level: :debug], fn ->
          denied = callback_conn(start) |> get("/auth/oidc/callback", params)
          assert redirected_to(denied) == "/users/log-in"
          refute get_session(denied, :user_token)
        end)

      assert output =~ "Processing with KithWeb.OIDCController.callback/2"
      refute output =~ "CREDENTIALMARK"
      refute output =~ "URICREDENTIALMARK"

      refute Enum.any?(Kith.OIDCFixture.requests(fixture), fn {path, _, _} -> path == "/token" end)
    end
  end

  defp known_user(fixture) do
    {:ok, user} =
      Kith.Accounts.OIDC.register(
        %Kith.Auth.Principal{
          issuer: fixture.config[:issuer],
          subject: "subject",
          email: "person@example.test",
          email_verified: true
        },
        %{tos_accepted: true}
      )

    user
  end

  defp authorize(start, fixture) do
    {:ok, %{status: 302, headers: headers}} =
      Kith.Auth.OIDC.Metadata.HTTPAdapter.request(
        :get,
        redirected_to(start),
        nil,
        [],
        fixture.config
      )

    {"location", location} = List.keyfind(headers, "location", 0)
    location |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
  end

  defp callback_conn(start) do
    build_conn()
    |> put_req_cookie("__Host-kith_oidc", start.resp_cookies["__Host-kith_oidc"].value)
  end
end
