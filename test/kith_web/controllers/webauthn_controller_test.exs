defmodule KithWeb.WebauthnControllerTest do
  use KithWeb.ConnCase

  alias Kith.Accounts.WebauthnCredential
  import Kith.AccountsFixtures

  @fake_cose_key %{
    1 => 2,
    3 => -7,
    -1 => 1,
    -2 => :crypto.strong_rand_bytes(32),
    -3 => :crypto.strong_rand_bytes(32)
  }

  setup %{conn: conn} do
    # Phoenix.ConnTest normally bypasses CSRF. Exercise the actual browser policy.
    Plug.CSRFProtection.delete_csrf_token()
    token = Plug.CSRFProtection.get_csrf_token()
    state = Plug.CSRFProtection.dump_state()

    conn =
      conn
      |> init_test_session(%{"_csrf_token" => state})
      |> put_private(:plug_skip_csrf_protection, false)
      |> put_req_header("x-csrf-token", token)

    %{conn: conn, csrf_state: state}
  end

  defp csrf_login(conn, user) do
    state = get_session(conn, "_csrf_token")
    conn |> log_in_user(user) |> put_session("_csrf_token", state)
  end

  defp create_credential(user, opts \\ []) do
    %WebauthnCredential{}
    |> WebauthnCredential.changeset(%{
      user_id: user.id,
      credential_id: Keyword.get(opts, :credential_id, :crypto.strong_rand_bytes(32)),
      public_key: :erlang.term_to_binary(@fake_cose_key),
      sign_count: 0,
      name: Keyword.get(opts, :name, "Test Key")
    })
    |> Kith.Repo.insert!()
  end

  describe "browser JSON request protection" do
    test "rejects missing and invalid CSRF tokens", %{conn: conn} do
      for token <- [nil, "invalid"] do
        request = delete_req_header(conn, "x-csrf-token")
        request = if token, do: put_req_header(request, "x-csrf-token", token), else: request

        assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
          post(request, ~p"/auth/webauthn/authenticate/challenge")
        end
      end
    end

    test "authenticated registration and deletion require CSRF", %{conn: conn} do
      conn = csrf_login(conn, user_fixture()) |> delete_req_header("x-csrf-token")

      assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
        post(conn, ~p"/auth/webauthn/register/challenge")
      end

      assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
        delete(conn, ~p"/auth/webauthn/credentials/1")
      end
    end

    test "returns the custom CSP on JSON responses", %{conn: conn} do
      conn = post(conn, ~p"/auth/webauthn/authenticate/challenge")
      assert json_response(conn, 200)["publicKey"]["challenge"]
      assert [policy] = get_resp_header(conn, "content-security-policy")
      assert policy =~ "default-src 'self'"
      assert policy =~ "script-src"
    end

    test "a real signed assertion authenticates with a stored key and valid CSRF token", %{
      conn: conn
    } do
      user = user_fixture()
      credential = create_credential(user)

      {<<4, x::binary-size(32), y::binary-size(32)>>, private_key} =
        :crypto.generate_key(:ecdh, :secp256r1)

      key = %{1 => 2, 3 => -7, -1 => 1, -2 => x, -3 => y}

      credential
      |> Ecto.Changeset.change(public_key: :erlang.term_to_binary(key))
      |> Kith.Repo.update!()

      challenge_conn =
        post(conn, ~p"/auth/webauthn/authenticate/challenge", %{"email" => user.email})

      %{"publicKey" => %{"challenge" => challenge_bytes}} = json_response(challenge_conn, 200)
      challenge = get_session(challenge_conn, :webauthn_auth_challenge)

      client_data =
        Jason.encode!(%{
          type: "webauthn.get",
          challenge: challenge_bytes,
          origin: challenge.origin
        })

      auth_data = :crypto.hash(:sha256, challenge.rp_id) <> <<1, 1::32>>

      signature =
        :crypto.sign(:ecdsa, :sha256, auth_data <> :crypto.hash(:sha256, client_data), [
          private_key,
          :secp256r1
        ])

      conn =
        challenge_conn
        |> recycle()
        |> put_private(:plug_skip_csrf_protection, false)
        |> put_req_header("x-csrf-token", hd(get_req_header(conn, "x-csrf-token")))
        |> post(~p"/auth/webauthn/authenticate/complete", %{
          "credentialId" => Base.url_encode64(credential.credential_id, padding: false),
          "authenticatorData" => Base.url_encode64(auth_data, padding: false),
          "signature" => Base.url_encode64(signature, padding: false),
          "clientDataJSON" => Base.url_encode64(client_data, padding: false)
        })

      assert redirected_to(conn) == "/dashboard"
      assert get_session(conn, :user_token)
      assert Kith.Repo.reload!(credential).sign_count == 1
      refute get_session(conn, :webauthn_auth_challenge)
    end

    test "invalid curve point stored in a credential returns a controlled error", %{conn: conn} do
      user = user_fixture()
      credential = create_credential(user)
      invalid_key = %{1 => 2, 3 => -7, -1 => 1, -2 => <<0::256>>, -3 => <<0::256>>}

      credential
      |> Ecto.Changeset.change(public_key: :erlang.term_to_binary(invalid_key))
      |> Kith.Repo.update!()

      challenge_conn = post(conn, ~p"/auth/webauthn/authenticate/challenge")
      %{"publicKey" => %{"challenge" => challenge_bytes}} = json_response(challenge_conn, 200)
      challenge = get_session(challenge_conn, :webauthn_auth_challenge)

      client_data =
        Jason.encode!(%{
          type: "webauthn.get",
          challenge: challenge_bytes,
          origin: challenge.origin
        })

      auth_data = :crypto.hash(:sha256, challenge.rp_id) <> <<1, 1::32>>

      conn =
        challenge_conn
        |> recycle()
        |> put_private(:plug_skip_csrf_protection, false)
        |> put_req_header("x-csrf-token", hd(get_req_header(conn, "x-csrf-token")))
        |> post(~p"/auth/webauthn/authenticate/complete", %{
          "credentialId" => Base.url_encode64(credential.credential_id, padding: false),
          "authenticatorData" => Base.url_encode64(auth_data, padding: false),
          "signature" => Base.url_encode64("invalid", padding: false),
          "clientDataJSON" => Base.url_encode64(client_data, padding: false)
        })

      assert json_response(conn, 401) == %{"error" => "Invalid stored credential"}
      refute get_session(conn, :user_token)
      assert Kith.Repo.reload!(credential).sign_count == 0
    end

    test "malformed stored credential fails authentication without decoding arbitrary terms", %{
      conn: conn
    } do
      user = user_fixture()
      credential = create_credential(user)
      credential |> Ecto.Changeset.change(public_key: <<131, 255>>) |> Kith.Repo.update!()
      challenge_conn = post(conn, ~p"/auth/webauthn/authenticate/challenge")
      assert json_response(challenge_conn, 200)["publicKey"]["challenge"]

      conn =
        challenge_conn
        |> recycle()
        |> put_private(:plug_skip_csrf_protection, false)
        |> put_req_header("x-csrf-token", get_req_header(conn, "x-csrf-token") |> hd())
        |> post(~p"/auth/webauthn/authenticate/complete", %{
          "credentialId" => Base.url_encode64(credential.credential_id, padding: false),
          "authenticatorData" => Base.url_encode64("fake", padding: false),
          "signature" => Base.url_encode64("fake", padding: false),
          "clientDataJSON" => Base.url_encode64("fake", padding: false)
        })

      assert json_response(conn, 401) == %{"error" => "Invalid stored credential"}
      refute get_session(conn, :webauthn_auth_challenge)
    end
  end

  describe "register_challenge (POST /auth/webauthn/register/challenge)" do
    setup %{conn: conn} do
      user = user_fixture()
      conn = csrf_login(conn, user)
      %{conn: conn, user: user}
    end

    test "returns publicKey options with challenge", %{conn: conn, user: user} do
      conn = post(conn, ~p"/auth/webauthn/register/challenge")
      assert %{"publicKey" => public_key} = json_response(conn, 200)

      assert public_key["challenge"]
      assert public_key["rp"]["name"] == "Kith"
      assert public_key["user"]["name"] == user.email
      assert is_list(public_key["pubKeyCredParams"])
      assert is_list(public_key["excludeCredentials"])
    end

    test "excludes existing credentials", %{conn: conn, user: user} do
      cred = create_credential(user)

      conn = post(conn, ~p"/auth/webauthn/register/challenge")
      %{"publicKey" => public_key} = json_response(conn, 200)

      excluded_ids = Enum.map(public_key["excludeCredentials"], & &1["id"])
      expected_id = Base.url_encode64(cred.credential_id, padding: false)
      assert expected_id in excluded_ids
    end
  end

  describe "register_complete (POST /auth/webauthn/register/complete)" do
    setup %{conn: conn} do
      user = user_fixture()
      conn = csrf_login(conn, user)
      %{conn: conn, user: user}
    end

    test "returns 400 without pending challenge", %{conn: conn} do
      conn =
        post(conn, ~p"/auth/webauthn/register/complete", %{
          "attestationObject" => Base.url_encode64("fake", padding: false),
          "clientDataJSON" => Base.url_encode64("fake", padding: false),
          "name" => "My Key"
        })

      assert json_response(conn, 400)["error"] =~ "No pending challenge"
    end
  end

  describe "authenticate_challenge (POST /auth/webauthn/authenticate/challenge)" do
    test "returns challenge without email", %{conn: conn} do
      conn = post(conn, ~p"/auth/webauthn/authenticate/challenge")
      assert %{"publicKey" => public_key} = json_response(conn, 200)
      assert public_key["challenge"]
      assert public_key["allowCredentials"] == []
    end

    test "returns challenge with allow_credentials when email has WebAuthn", %{conn: conn} do
      user = user_fixture()
      cred = create_credential(user)

      conn = post(conn, ~p"/auth/webauthn/authenticate/challenge", %{"email" => user.email})
      assert %{"publicKey" => public_key} = json_response(conn, 200)
      assert public_key["challenge"]

      allowed_ids = Enum.map(public_key["allowCredentials"], & &1["id"])
      expected_id = Base.url_encode64(cred.credential_id, padding: false)
      assert expected_id in allowed_ids
    end

    test "returns empty allow_credentials for unknown email", %{conn: conn} do
      conn =
        post(conn, ~p"/auth/webauthn/authenticate/challenge", %{
          "email" => "nobody@example.com"
        })

      assert %{"publicKey" => public_key} = json_response(conn, 200)
      assert public_key["allowCredentials"] == []
    end
  end

  describe "authenticate_complete (POST /auth/webauthn/authenticate/complete)" do
    test "returns 400 without pending challenge", %{conn: conn} do
      conn =
        post(conn, ~p"/auth/webauthn/authenticate/complete", %{
          "credentialId" => Base.url_encode64("fake", padding: false),
          "authenticatorData" => Base.url_encode64("fake", padding: false),
          "signature" => Base.url_encode64("fake", padding: false),
          "clientDataJSON" => Base.url_encode64("fake", padding: false)
        })

      assert json_response(conn, 400)["error"] =~ "No pending challenge"
    end
  end

  describe "list_credentials (GET /auth/webauthn/credentials)" do
    setup %{conn: conn} do
      user = user_fixture()
      conn = csrf_login(conn, user)
      %{conn: conn, user: user}
    end

    test "returns user's credentials", %{conn: conn, user: user} do
      create_credential(user, name: "My Yubikey")
      create_credential(user, name: "Touch ID")

      conn = get(conn, ~p"/auth/webauthn/credentials")
      assert %{"credentials" => creds} = json_response(conn, 200)
      assert length(creds) == 2
      names = Enum.map(creds, & &1["name"])
      assert "My Yubikey" in names
      assert "Touch ID" in names
    end

    test "returns empty list when no credentials", %{conn: conn} do
      conn = get(conn, ~p"/auth/webauthn/credentials")
      assert %{"credentials" => []} = json_response(conn, 200)
    end
  end

  describe "delete_credential (DELETE /auth/webauthn/credentials/:id)" do
    setup %{conn: conn} do
      user = user_fixture()
      conn = csrf_login(conn, user)
      %{conn: conn, user: user}
    end

    test "deletes a credential", %{conn: conn, user: user} do
      cred = create_credential(user)
      conn = delete(conn, ~p"/auth/webauthn/credentials/#{cred.id}")
      assert json_response(conn, 200)["status"] == "ok"
    end

    test "returns 404 for non-existent credential", %{conn: conn} do
      conn = delete(conn, ~p"/auth/webauthn/credentials/999999")
      assert json_response(conn, 404)["error"] =~ "not found"
    end
  end
end
