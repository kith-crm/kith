defmodule KithWeb.OAuthControllerTest do
  use KithWeb.ConnCase

  alias Kith.Accounts

  import Kith.AccountsFixtures

  setup do
    previous = Application.get_env(:kith, :oauth_providers)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:kith, :oauth_providers),
        else: Application.put_env(:kith, :oauth_providers, previous)
    end)

    :ok
  end

  describe "request (GET /auth/:provider)" do
    test "redirects to login with error for unconfigured provider", %{conn: conn} do
      conn = get(conn, ~p"/auth/github")
      assert redirected_to(conn) == ~p"/users/log-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "not configured"
    end

    test "returns error for unsupported provider", %{conn: conn} do
      conn = get(conn, ~p"/auth/facebook")
      assert redirected_to(conn) == ~p"/users/log-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Unsupported"
    end
  end

  describe "callback (GET /auth/:provider/callback)" do
    test "redirects to login with error for unconfigured provider", %{conn: conn} do
      conn = get(conn, ~p"/auth/github/callback", %{"code" => "test"})
      assert redirected_to(conn) == ~p"/users/log-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "not configured"
    end

    test "returns error for unsupported provider", %{conn: conn} do
      conn = get(conn, ~p"/auth/facebook/callback", %{"code" => "test"})
      assert redirected_to(conn) == ~p"/users/log-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Unsupported"
    end
  end

  describe "configured provider callbacks through Assent's Req adapter" do
    for provider <- ["github", "google"] do
      @provider provider

      test "#{provider} uses provider identity rather than browser-supplied identity", %{
        conn: conn
      } do
        provider = @provider
        user = user_fixture()
        uid = if provider == "github", do: "123456", else: "google-subject"
        assert {:ok, _} = Accounts.upsert_identity(user, provider, uid, %{})
        configure_provider(provider, user.email, uid)

        authorization = get(conn, "/auth/#{provider}")
        session = get_session(authorization, :oauth_session_params)
        assert is_binary(session.state)
        assert is_binary(session.code_verifier)

        params =
          authorization
          |> redirected_to()
          |> URI.parse()
          |> Map.fetch!(:query)
          |> URI.decode_query()

        assert params["state"] == session.state
        assert params["code_challenge_method"] == "S256"

        assert params["code_challenge"] ==
                 Base.url_encode64(:crypto.hash(:sha256, session.code_verifier), padding: false)

        callback =
          authorization
          |> recycle()
          |> get("/auth/#{provider}/callback", %{
            "code" => "fixture-code",
            "state" => session.state,
            "user" =>
              Jason.encode!(%{"sub" => "attacker-subject", "email" => "attacker@example.com"})
          })

        assert redirected_to(callback) == "/dashboard"
        assert is_binary(get_session(callback, :user_token))
        assert is_nil(get_session(callback, :oauth_session_params))
        assert is_nil(get_session(callback, :oauth_provider))
        assert Accounts.get_identity_by_provider_uid(provider, uid).user_id == user.id

        assert Accounts.get_identity_by_provider_uid(provider, uid).access_token ==
                 "fixture-access-token"

        assert is_nil(Accounts.get_identity_by_provider_uid(provider, "attacker-subject"))

        assert_received {:oauth_token_request, ^provider, token_request}
        assert token_request["code"] == "fixture-code"
        assert token_request["code_verifier"] == session.code_verifier
      end

      test "#{provider} rejects a mismatched state before exchanging credentials", %{conn: conn} do
        provider = @provider
        configure_provider(provider, "provider@example.com", "provider-subject")
        authorization = get(conn, "/auth/#{provider}")

        callback =
          authorization
          |> recycle()
          |> get("/auth/#{provider}/callback", %{
            "code" => "fixture-code",
            "state" => "forged-state"
          })

        assert redirected_to(callback) == "/users/log-in"
        assert Phoenix.Flash.get(callback.assigns.flash, :error) == "OAuth authentication failed."
        assert is_nil(get_session(callback, :user_token))
        assert is_nil(get_session(callback, :oauth_session_params))
        refute_received {:oauth_token_request, _, _}
      end
    end

    test "Google rejects a token whose signature does not match the provider key", %{conn: conn} do
      configure_provider("google", "provider@example.com", "provider-subject",
        invalid_signature: true
      )

      authorization = get(conn, "/auth/google")
      session = get_session(authorization, :oauth_session_params)

      callback =
        authorization
        |> recycle()
        |> get("/auth/google/callback", %{"code" => "fixture-code", "state" => session.state})

      assert redirected_to(callback) == "/users/log-in"
      assert Phoenix.Flash.get(callback.assigns.flash, :error) == "OAuth authentication failed."
      assert is_nil(get_session(callback, :user_token))
      assert is_nil(Accounts.get_identity_by_provider_uid("google", "provider-subject"))
    end
  end

  defp configure_provider(provider, email, uid, opts \\ []) do
    owner = self()
    {id_token, public_jwk} = google_token(provider, email, uid, opts)

    fixture = fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", path} when path in ["/login/oauth/access_token", "/token"] ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(owner, {:oauth_token_request, provider, URI.decode_query(body)})

          token = %{"access_token" => "fixture-access-token", "token_type" => "Bearer"}
          token = if id_token, do: Map.put(token, "id_token", id_token), else: token
          Req.Test.json(conn, token)

        {"GET", "/user"} ->
          assert Plug.Conn.get_req_header(conn, "authorization") == [
                   "Bearer fixture-access-token"
                 ]

          Req.Test.json(conn, %{"id" => uid, "login" => "fixture", "name" => "Provider Name"})

        {"GET", "/user/emails"} ->
          Req.Test.json(conn, [%{"primary" => true, "verified" => true, "email" => email}])

        {"GET", "/jwks"} ->
          Req.Test.json(conn, %{"keys" => [public_jwk]})

        unexpected ->
          flunk("Unexpected provider request: #{inspect(unexpected)}")
      end
    end

    configuration = [
      client_id: "fixture-client",
      client_secret: "fixture-client-secret",
      code_verifier: true,
      http_adapter: {Assent.HTTPAdapter.Req, [plug: fixture, retry: false]},
      json_library: Jason
    ]

    configuration =
      if provider == "google" do
        Keyword.put(configuration, :openid_configuration, %{
          "issuer" => "https://accounts.google.com",
          "authorization_endpoint" => "https://accounts.google.com/authorize",
          "token_endpoint" => "https://accounts.google.com/token",
          "jwks_uri" => "https://accounts.google.com/jwks"
        })
      else
        configuration
      end

    Application.put_env(:kith, :oauth_providers, %{provider => configuration})
  end

  defp google_token("github", _email, _uid, _opts), do: {nil, nil}

  defp google_token("google", email, uid, opts) do
    key = X509.PrivateKey.new_rsa(2048)
    signing_key = if opts[:invalid_signature], do: X509.PrivateKey.new_rsa(2048), else: key
    {:RSAPublicKey, modulus, exponent} = X509.PublicKey.derive(key)
    now = System.system_time(:second)

    claims = %{
      "iss" => "https://accounts.google.com",
      "sub" => uid,
      "aud" => "fixture-client",
      "iat" => now,
      "exp" => now + 300,
      "email" => email,
      "email_verified" => true,
      "name" => "Provider Name"
    }

    assert {:ok, token} =
             Assent.JWTAdapter.AssentJWT.sign(
               claims,
               "RS256",
               X509.PrivateKey.to_pem(signing_key),
               json_library: Jason,
               private_key_id: "fixture-key"
             )

    jwk = %{
      "kty" => "RSA",
      "kid" => "fixture-key",
      "n" => Base.url_encode64(:binary.encode_unsigned(modulus), padding: false),
      "e" => Base.url_encode64(:binary.encode_unsigned(exponent), padding: false)
    }

    {token, jwk}
  end
end
