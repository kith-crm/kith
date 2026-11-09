defmodule KithWeb.AuthenticationCompletionTest do
  use KithWeb.ConnCase, async: false
  require Phoenix.LiveViewTest
  alias Kith.Accounts
  alias KithWeb.Authentication
  import Kith.AccountsFixtures

  setup do
    original = Application.fetch_env!(:kith, :auth)
    on_exit(fn -> Application.put_env(:kith, :auth, original) end)

    Application.put_env(:kith, :auth, %{
      original
      | oidc_enabled: true,
        oidc: [issuer: "https://issuer.example"]
    })

    :ok
  end

  for intent <- [:login, :reauth, :link], policy <- [:disabled, :switched, :unchanged] do
    @tag intent: intent, policy: policy
    test "pending OIDC #{intent} MFA honors #{policy} current policy", %{
      conn: conn,
      intent: intent,
      policy: policy
    } do
      secret = Accounts.generate_totp_secret()
      now = DateTime.utc_now(:second)

      user =
        user_fixture()
        |> Ecto.Changeset.change(totp_enabled: true, totp_secret: secret)
        |> Kith.Repo.update!()

      principal = %Kith.Auth.Principal{
        issuer: "https://issuer.example",
        subject: "pending-subject",
        auth_time: DateTime.to_unix(now)
      }

      if intent != :link do
        {:ok, _} =
          Accounts.OIDC.link(
            %{user | authenticated_at: now, mfa_authenticated_at: now},
            principal
          )
      end

      old = DateTime.add(now, -601)

      origin =
        if intent != :login,
          do:
            Accounts.generate_user_session_token(%{
              user
              | authenticated_at: old,
                mfa_authenticated_at: old
            })

      binding = "pending-policy-browser-binding"

      flow = %Kith.Auth.OIDC.Transaction{
        intent: intent,
        user_id: user.id,
        session_token: origin,
        issuer: principal.issuer,
        consumed_at: now,
        initiated_at: now,
        binding_hash: :crypto.hash(:sha256, binding),
        return_to: "/settings/security"
      }

      callback = conn |> init_test_session(%{}) |> Phoenix.Controller.fetch_flash()

      pending =
        Authentication.begin_oidc(callback, user, flow, principal, browser_binding: binding)

      assert redirected_to(pending) == "/users/two-factor"
      refute get_session(pending, :user_token)
      assert get_session(pending, :auth_challenge_binding) == binding
      handle = get_session(pending, :totp_token)
      before_tokens = Kith.Repo.aggregate(Accounts.UserToken, :count)
      before_identities = Accounts.OIDC.list(user)
      auth = Application.fetch_env!(:kith, :auth)

      changed =
        case policy do
          :disabled -> %{auth | oidc_enabled: false, oidc: nil}
          :switched -> %{auth | oidc: [issuer: "https://replacement.example"]}
          :unchanged -> auth
        end

      Application.put_env(:kith, :auth, changed)

      # Carry the actual pending session binding into the real MFA endpoint.
      finished =
        conn
        |> init_test_session(get_session(pending))
        |> post("/users/totp-verify", %{totp_token: handle, totp: %{code: :pot.totp(secret)}})

      challenge =
        Kith.Repo.get_by!(Kith.Auth.Challenge, handle_hash: :crypto.hash(:sha256, handle))

      assert challenge.consumed_at != nil

      if policy == :unchanged do
        assert redirected_to(finished) == "/settings/security"
        assert token = get_session(finished, :user_token)
        assert {loaded, _} = Accounts.get_user_by_session_token(token)
        assert :ok = Authentication.require_recent(loaded)
        assert [%{subject: "pending-subject"}] = Accounts.OIDC.list(user)
        if origin, do: refute(Accounts.get_user_by_session_token(origin))
      else
        assert redirected_to(finished) == "/users/log-in"
        assert is_nil(get_session(finished, :user_token))
        assert Kith.Repo.aggregate(Accounts.UserToken, :count) == before_tokens
        assert Accounts.OIDC.list(user) == before_identities

        if origin do
          assert {loaded, _} = Accounts.get_user_by_session_token(origin)
          assert loaded.authenticated_at == old
          assert loaded.mfa_authenticated_at == old
          assert {:error, :reauthentication_required} = Authentication.require_recent(loaded)
        end
      end
    end
  end

  test "renewing a session does not manufacture recent authentication" do
    user = Kith.AccountsFixtures.user_fixture()
    old = DateTime.add(DateTime.utc_now(:second), -601, :second)
    user = %{user | authenticated_at: old}
    token = Kith.Accounts.generate_user_session_token(user)
    assert {loaded, _} = Kith.Accounts.get_user_by_session_token(token)

    assert {:error, :reauthentication_required} =
             KithWeb.Authentication.require_recent(loaded)
  end

  test "legacy MFA sessions cannot authorize sensitive mutations" do
    user = user_fixture() |> Ecto.Changeset.change(totp_enabled: true) |> Kith.Repo.update!()
    token = Accounts.generate_user_session_token(user)
    {loaded, _} = Accounts.get_user_by_session_token(token)
    assert {:error, :reauthentication_required} = Authentication.require_recent(loaded)

    assert {:error, :reauthentication_required} =
             Accounts.DavAppPasswords.create(loaded, %{name: "phone"})
  end

  test "password MFA grants no token until browser-bound completion", %{conn: conn} do
    secret = Accounts.generate_totp_secret()

    user =
      user_fixture()
      |> Ecto.Changeset.change(totp_enabled: true, totp_secret: secret)
      |> Kith.Repo.update!()

    conn =
      post(conn, "/users/log-in", %{user: %{email: user.email, password: valid_user_password()}})

    refute get_session(conn, :user_token)
    handle = get_session(conn, :totp_token)

    stolen =
      post(build_conn(), "/users/totp-verify", %{
        totp_token: handle,
        totp: %{code: :pot.totp(secret)}
      })

    refute get_session(stolen, :user_token)

    conn =
      post(recycle(conn), "/users/totp-verify", %{
        totp_token: handle,
        totp: %{code: :pot.totp(secret)}
      })

    assert token = get_session(conn, :user_token)
    assert {loaded, _} = Accounts.get_user_by_session_token(token)
    assert :ok = Authentication.require_recent(loaded)

    replay =
      post(recycle(conn), "/users/totp-verify", %{
        totp_token: handle,
        totp: %{code: :pot.totp(secret)}
      })

    assert get_session(replay, :user_token) == token
  end

  test "nil legacy freshness remains nil when renewed" do
    user = user_fixture()
    token = Accounts.generate_user_session_token(user)
    {loaded, _} = Accounts.get_user_by_session_token(token)
    renewed = Accounts.generate_user_session_token(loaded)
    {loaded, _} = Accounts.get_user_by_session_token(renewed)
    assert loaded.authenticated_at == nil
    assert {:error, :reauthentication_required} = Authentication.require_recent(loaded)
  end

  test "TOTP setup and enabling require recent authentication", %{conn: conn} do
    user = user_fixture()
    secret = Accounts.generate_totp_secret()

    assert {:error, :reauthentication_required} =
             Accounts.enable_totp(user, secret, :pot.totp(secret))

    conn =
      log_in_user(conn, user,
        token_authenticated_at: DateTime.add(DateTime.utc_now(:second), -601)
      )

    assert {:error, {:redirect, %{to: "/users/reauth?return_to=totp"}}} =
             Phoenix.LiveViewTest.live(conn, "/users/totp-setup")
  end

  test "freshness completion rotates same-user session and returns without replaying a mutation",
       %{conn: conn} do
    user = user_fixture()

    conn =
      log_in_user(conn, user,
        token_authenticated_at: DateTime.add(DateTime.utc_now(:second), -601)
      )

    previous = get_session(conn, :user_token)
    conn = get(conn, "/users/reauth?return_to=totp")
    assert redirected_to(conn) == "/users/log-in"

    conn =
      post(recycle(conn), "/users/log-in", %{
        user: %{email: user.email, password: valid_user_password()}
      })

    assert redirected_to(conn) == "/users/totp-setup"
    assert get_session(conn, :user_token) != previous
    refute Accounts.get_user_by_session_token(previous)
  end

  test "OIDC reauthentication validates same linked identity and fresh provider evidence", %{
    conn: conn
  } do
    user = %{user_fixture() | authenticated_at: DateTime.utc_now(:second)}

    principal = %Kith.Auth.Principal{
      issuer: "https://issuer.example",
      subject: "subject",
      auth_time: System.os_time(:second)
    }

    {:ok, _} = Accounts.OIDC.link(user, principal)
    token = Accounts.generate_user_session_token(user)

    flow = %Kith.Auth.OIDC.Transaction{
      intent: :reauth,
      user_id: user.id,
      session_token: token,
      issuer: principal.issuer,
      consumed_at: DateTime.utc_now(),
      initiated_at: DateTime.utc_now(),
      return_to: "/settings/contact-sync/new"
    }

    conn = conn |> init_test_session(%{}) |> Phoenix.Controller.fetch_flash()
    wrong = %{principal | subject: "wrong"}
    rejected = Authentication.begin_oidc(conn, user, flow, wrong)
    refute get_session(rejected, :user_token)
    stale = %{principal | auth_time: System.os_time(:second) - 601}
    rejected = Authentication.begin_oidc(conn, user, flow, stale)
    refute get_session(rejected, :user_token)
    finished = Authentication.begin_oidc(conn, user, flow, principal)
    assert redirected_to(finished) == "/settings/contact-sync/new"
    assert get_session(finished, :user_token)
    refute Accounts.get_user_by_session_token(token)
  end

  test "OIDC link waits for local MFA and logout invalidates the pending link", %{conn: conn} do
    secret = Accounts.generate_totp_secret()

    user =
      user_fixture()
      |> Ecto.Changeset.change(totp_enabled: true, totp_secret: secret)
      |> Kith.Repo.update!()

    token = Accounts.generate_user_session_token(user)

    principal = %Kith.Auth.Principal{
      issuer: "https://issuer.example",
      subject: "new-subject",
      auth_time: System.os_time(:second)
    }

    flow = %Kith.Auth.OIDC.Transaction{
      intent: :link,
      user_id: user.id,
      session_token: token,
      issuer: principal.issuer,
      consumed_at: DateTime.utc_now(),
      initiated_at: DateTime.utc_now(),
      return_to: "/settings/security"
    }

    conn = conn |> init_test_session(%{}) |> Phoenix.Controller.fetch_flash()
    pending = Authentication.begin_oidc(conn, user, flow, principal)
    refute get_session(pending, :user_token)
    assert Accounts.OIDC.list(user) == []
    Accounts.delete_user_session_token(token)

    assert {:error, :invalid} =
             Kith.Auth.Challenges.complete(
               get_session(pending, :totp_token),
               get_session(pending, :auth_challenge_binding),
               :pot.totp(secret)
             )

    assert Accounts.OIDC.list(user) == []
  end

  test "fresh MFA evidence survives session reissue while both factors independently expire" do
    user = user_fixture() |> Ecto.Changeset.change(totp_enabled: true) |> Kith.Repo.update!()
    now = DateTime.utc_now(:second)
    user = %{user | authenticated_at: now, mfa_authenticated_at: now}
    token = Accounts.generate_user_session_token(user)
    {loaded, _} = Accounts.get_user_by_session_token(token)
    renewed = Accounts.generate_user_session_token(loaded)
    {loaded, _} = Accounts.get_user_by_session_token(renewed)
    assert loaded.mfa_authenticated_at == now
    assert :ok = Authentication.require_recent(loaded)
    old = DateTime.add(now, -601)

    assert {:error, :reauthentication_required} =
             Authentication.require_recent(%{loaded | mfa_authenticated_at: old})

    assert {:error, :reauthentication_required} =
             Authentication.require_recent(%{loaded | authenticated_at: old})

    assert {:error, :reauthentication_required} =
             Authentication.require_recent(%{loaded | authenticated_at: DateTime.add(now, 60)})

    assert {:ok, row, _} = Accounts.DavAppPasswords.create(loaded, %{name: "phone"})
    assert :ok = Accounts.DavAppPasswords.revoke(loaded, row.id)
  end

  test "completed link consumes MFA before linking and rotates the originating session", %{
    conn: conn
  } do
    secret = Accounts.generate_totp_secret()

    user =
      user_fixture()
      |> Ecto.Changeset.change(totp_enabled: true, totp_secret: secret)
      |> Kith.Repo.update!()

    token = Accounts.generate_user_session_token(user)
    principal = %Kith.Auth.Principal{issuer: "https://issuer.example", subject: "linked"}

    {:ok, handle} =
      Kith.Auth.Challenges.issue(user, %{
        intent: :link,
        session_token: token,
        principal: principal,
        browser_binding: "complete-browser-binding",
        authenticated_at: DateTime.utc_now(:second),
        return_to: "/settings/security"
      })

    {:ok, completion} =
      Kith.Auth.Challenges.complete(handle, "complete-browser-binding", :pot.totp(secret))

    assert Accounts.OIDC.list(user) == []

    assert {:error, :invalid} =
             Kith.Auth.Challenges.complete(handle, "complete-browser-binding", :pot.totp(secret))

    conn = conn |> init_test_session(%{}) |> Phoenix.Controller.fetch_flash()
    finished = Authentication.finish(conn, completion)
    assert get_session(finished, :user_token)
    assert [%{subject: "linked"}] = Accounts.OIDC.list(user)
    refute Accounts.get_user_by_session_token(token)
    replay = Authentication.finish(conn, completion)
    refute get_session(replay, :user_token)
  end

  test "password reauth cannot switch accounts", %{conn: conn} do
    first = user_fixture()
    other = user_fixture()
    conn = log_in_user(conn, first)
    token = get_session(conn, :user_token)

    response =
      post(conn, "/users/log-in", %{user: %{email: other.email, password: valid_user_password()}})

    assert get_session(response, :user_token) == token
    assert redirected_to(response) == "/users/log-in"
  end

  test "authentication request parameters are filtered before logging" do
    values = %{
      "password" => "private-password",
      "totp_token" => "private-handle",
      "totp" => %{"code" => "123456"},
      "state" => "private-state",
      "code" => "private-provider-code"
    }

    filtered = Phoenix.Logger.filter_values(values)
    refute inspect(filtered) =~ "private-"
    refute inspect(filtered) =~ "123456"

    for key <- ["code", "totp_code", "totp_token", "state", "auth_challenge_binding"] do
      assert {^key, "[FILTERED]"} = Kith.SentryEventHandler.scrub_params({key, "private-value"})
    end
  end

  test "logout invalidates a pending login even with the old browser cookie", %{conn: conn} do
    secret = Accounts.generate_totp_secret()

    user =
      user_fixture()
      |> Ecto.Changeset.change(totp_enabled: true, totp_secret: secret)
      |> Kith.Repo.update!()

    pending =
      post(conn, "/users/log-in", %{user: %{email: user.email, password: valid_user_password()}})

    handle = get_session(pending, :totp_token)
    logout = delete(recycle(pending), "/users/log-out")
    refute get_session(logout, :user_token)

    replay =
      post(recycle(pending), "/users/totp-verify", %{
        totp_token: handle,
        totp: %{code: :pot.totp(secret)}
      })

    refute get_session(replay, :user_token)
  end

  test "logout cancels a sibling login after completing another flow", %{conn: conn} do
    assert_sibling_logout(conn, false)
  end

  test "logout cancels a sibling login after subsequent reauthentication", %{conn: conn} do
    assert_sibling_logout(conn, true)
  end

  test "failed completion preserves the browser cancellation identity", %{conn: conn} do
    user = user_fixture()

    conn =
      conn
      |> init_test_session(%{auth_challenge_binding: "existing-browser-binding"})
      |> Phoenix.Controller.fetch_flash()

    rejected =
      Authentication.begin(conn, user, %{intent: :reauth, session_token: "revoked-origin"})

    assert redirected_to(rejected) == "/users/log-in"
    assert get_session(rejected, :auth_challenge_binding) == "existing-browser-binding"
    refute get_session(rejected, :user_token)
  end

  test "verified Lax binding preserves logout cancellation without the Strict cookie", %{
    conn: conn
  } do
    secret = Accounts.generate_totp_secret()

    user =
      user_fixture()
      |> Ecto.Changeset.change(totp_enabled: true, totp_secret: secret)
      |> Kith.Repo.update!()

    sibling =
      post(conn, "/users/log-in", %{user: %{email: user.email, password: valid_user_password()}})

    binding = get_session(sibling, :auth_challenge_binding)
    principal = %Kith.Auth.Principal{issuer: "https://issuer.example", subject: "subject"}

    flow = %Kith.Auth.OIDC.Transaction{
      intent: :login,
      issuer: principal.issuer,
      consumed_at: DateTime.utc_now(),
      binding_hash: :crypto.hash(:sha256, binding),
      return_to: "/dashboard"
    }

    callback = build_conn() |> init_test_session(%{}) |> Phoenix.Controller.fetch_flash()

    rejected =
      Authentication.begin_oidc(callback, user, flow, principal, browser_binding: "wrong-binding")

    refute get_session(rejected, :totp_token)
    refute get_session(rejected, :user_token)
    pending = Authentication.begin_oidc(callback, user, flow, principal, browser_binding: binding)
    assert get_session(pending, :auth_challenge_binding) == binding

    {:ok, completion} =
      Kith.Auth.Challenges.complete(get_session(pending, :totp_token), binding, :pot.totp(secret))

    # Exercise the trusted callback boundary without relying on a preexisting
    # Strict session; the verified completion itself retains cancellation proof.
    finished = Authentication.finish(callback, completion)
    assert get_session(finished, :user_token)
    assert get_session(finished, :auth_challenge_binding) == binding

    logout_conn =
      build_conn() |> init_test_session(get_session(finished)) |> Phoenix.Controller.fetch_flash()

    KithWeb.UserAuth.log_out_user(logout_conn)

    assert {:error, :invalid} =
             Kith.Auth.Challenges.complete(
               get_session(sibling, :totp_token),
               binding,
               :pot.totp(secret)
             )
  end

  defp assert_sibling_logout(conn, reauthenticate?) do
    secret = Accounts.generate_totp_secret()

    user =
      user_fixture()
      |> Ecto.Changeset.change(totp_enabled: true, totp_secret: secret)
      |> Kith.Repo.update!()

    params = %{user: %{email: user.email, password: valid_user_password()}}
    first = post(conn, "/users/log-in", params)
    first_handle = get_session(first, :totp_token)
    second = post(recycle(first), "/users/log-in", params)
    second_handle = get_session(second, :totp_token)
    assert second_handle != first_handle

    assert get_session(second, :auth_challenge_binding) ==
             get_session(first, :auth_challenge_binding)

    finished =
      post(recycle(first), "/users/totp-verify", %{
        totp_token: first_handle,
        totp: %{code: :pot.totp(secret)}
      })

    assert get_session(finished, :user_token)

    finished =
      if reauthenticate? do
        pending = post(recycle(finished), "/users/log-in", params)

        assert get_session(pending, :auth_challenge_binding) ==
                 get_session(second, :auth_challenge_binding)

        post(recycle(pending), "/users/totp-verify", %{
          totp_token: get_session(pending, :totp_token),
          totp: %{code: :pot.totp(secret)}
        })
      else
        finished
      end

    assert get_session(finished, :user_token)
    # A successful tab must not invalidate another tab before explicit logout.
    row =
      Kith.Repo.get_by!(Kith.Auth.Challenge, handle_hash: :crypto.hash(:sha256, second_handle))

    assert is_nil(row.consumed_at)
    logout = delete(recycle(finished), "/users/log-out")
    refute get_session(logout, :user_token)

    replay =
      post(recycle(second), "/users/totp-verify", %{
        totp_token: second_handle,
        totp: %{code: :pot.totp(secret)}
      })

    refute get_session(replay, :user_token)
  end
end
