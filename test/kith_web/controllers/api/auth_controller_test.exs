defmodule KithWeb.API.AuthControllerTest do
  use KithWeb.ConnCase

  alias Kith.Accounts
  import Kith.AccountsFixtures

  @valid_password valid_user_password()

  test "DAV credentials cannot issue API tokens", %{conn: conn} do
    user = %{user_fixture() | authenticated_at: DateTime.utc_now(:second)}
    {:ok, _, secret} = Kith.Accounts.DavAppPasswords.create(user, %{name: "Phone"})
    conn = post(conn, ~p"/api/auth/token", %{email: user.email, password: secret})
    assert json_response(conn, 401)
  end

  describe "POST /api/auth/token" do
    test "returns token with valid credentials", %{conn: conn} do
      user = user_fixture()

      conn =
        post(conn, ~p"/api/auth/token", %{
          "email" => user.email,
          "password" => @valid_password
        })

      assert %{"token" => token, "expires_at" => nil} = json_response(conn, 201)
      assert is_binary(token)
      assert String.length(token) > 0
    end

    test "returns 401 with invalid credentials", %{conn: conn} do
      conn =
        post(conn, ~p"/api/auth/token", %{
          "email" => "bad@example.com",
          "password" => "wrongpassword1"
        })

      assert %{"status" => 401, "detail" => detail} = json_response(conn, 401)
      assert detail =~ "Invalid email or password"
    end

    test "returns 400 with missing params", %{conn: conn} do
      conn = post(conn, ~p"/api/auth/token", %{})
      assert %{"status" => 400} = json_response(conn, 400)
    end

    test "requires TOTP code when user has TOTP enabled", %{conn: conn} do
      user = user_fixture()
      secret = Accounts.generate_totp_secret()
      code = :pot.totp(secret)
      {:ok, _} = Accounts.enable_totp(user, secret, code)

      # Without TOTP code
      conn1 =
        post(conn, ~p"/api/auth/token", %{
          "email" => user.email,
          "password" => @valid_password
        })

      assert %{"detail" => "TOTP code required."} = json_response(conn1, 401)

      # With valid TOTP code
      new_code = :pot.totp(secret)

      conn2 =
        build_conn()
        |> post(~p"/api/auth/token", %{
          "email" => user.email,
          "password" => @valid_password,
          "totp_code" => new_code
        })

      assert %{"token" => _} = json_response(conn2, 201)
    end

    test "accepts recovery code when TOTP is enabled", %{conn: conn} do
      user = user_fixture()
      secret = Accounts.generate_totp_secret()
      code = :pot.totp(secret)
      {:ok, {user, recovery_codes}} = Accounts.enable_totp(user, secret, code)

      conn =
        post(conn, ~p"/api/auth/token", %{
          "email" => user.email,
          "password" => @valid_password,
          "totp_code" => List.first(recovery_codes)
        })

      assert %{"token" => _} = json_response(conn, 201)
      assert Accounts.recovery_code_count(user) == 7
    end
  end

  describe "token validation via FetchApiUser plug" do
    test "valid token grants access to protected endpoint", %{conn: conn} do
      user = user_fixture()
      {raw_token, _} = Accounts.generate_api_token(user)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw_token}")
        |> delete(~p"/api/auth/token")

      # Token self-revocation returns 204
      assert conn.status == 204
    end

    test "invalid token returns 401", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer invalid_token_here")
        |> delete(~p"/api/auth/token")

      assert %{"status" => 401} = json_response(conn, 401)
    end

    test "missing authorization header returns 401", %{conn: conn} do
      conn = delete(conn, ~p"/api/auth/token")
      assert %{"status" => 401} = json_response(conn, 401)
    end
  end

  describe "DELETE /api/auth/token (self-revocation)" do
    test "revokes the current token", %{conn: conn} do
      user = user_fixture()
      {raw_token, _} = Accounts.generate_api_token(user)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw_token}")
        |> delete(~p"/api/auth/token")

      assert conn.status == 204

      # Token should no longer work
      conn2 =
        build_conn()
        |> put_req_header("authorization", "Bearer #{raw_token}")
        |> delete(~p"/api/auth/token")

      assert json_response(conn2, 401)
    end
  end

  describe "DELETE /api/auth/token/:id" do
    test "revokes a specific token by id", %{conn: conn} do
      user = user_fixture()
      {raw_token, _} = Accounts.generate_api_token(user)
      {_other_raw, other_record} = Accounts.generate_api_token(user)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw_token}")
        |> delete(~p"/api/auth/token/#{other_record.id}")

      assert conn.status == 204
    end

    test "returns 404 for unknown token id", %{conn: conn} do
      user = user_fixture()
      {raw_token, _} = Accounts.generate_api_token(user)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw_token}")
        |> delete(~p"/api/auth/token/999999")

      assert json_response(conn, 404)
    end
  end
end
