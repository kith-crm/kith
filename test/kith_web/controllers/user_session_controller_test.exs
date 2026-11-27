defmodule KithWeb.UserSessionControllerTest do
  use KithWeb.ConnCase, async: true

  import Kith.AccountsFixtures

  setup do
    %{user: user_fixture()}
  end

  test "DAV credentials cannot log into the web", %{conn: conn, user: user} do
    user = %{user | authenticated_at: DateTime.utc_now(:second)}
    {:ok, _, secret} = Kith.Accounts.DavAppPasswords.create(user, %{name: "Phone"})
    conn = post(conn, ~p"/users/log-in", %{user: %{email: user.email, password: secret}})
    refute get_session(conn, :user_token)
    assert redirected_to(conn) == ~p"/users/log-in"
  end

  describe "POST /users/log-in" do
    test "logs the user in with valid credentials", %{conn: conn, user: user} do
      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{"email" => user.email, "password" => valid_user_password()}
        })

      assert get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/dashboard"
    end

    test "logs the user in with remember me", %{conn: conn, user: user} do
      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{
            "email" => user.email,
            "password" => valid_user_password(),
            "remember_me" => "true"
          }
        })

      assert conn.resp_cookies["_kith_web_user_remember_me"]
    end

    test "emits error message with invalid credentials", %{conn: conn} do
      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{"email" => "invalid@email.com", "password" => "invalid_password"}
        })

      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Invalid email or password"
      assert redirected_to(conn) == ~p"/users/log-in"
    end
  end

  describe "DELETE /users/log-out" do
    test "logs the user out", %{conn: conn, user: user} do
      conn = conn |> log_in_user(user) |> delete(~p"/users/log-out")
      assert redirected_to(conn) == ~p"/"
      refute get_session(conn, :user_token)
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Logged out successfully"
    end
  end
end
