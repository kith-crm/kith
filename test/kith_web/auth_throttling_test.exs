defmodule KithWeb.AuthThrottlingTest do
  use KithWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Kith.AccountsFixtures

  alias Kith.Accounts
  alias Kith.RateLimiter

  test "password login enforces ten attempts per verified peer with Retry-After", %{conn: conn} do
    user = user_fixture()
    peer = Plug.Conn.get_peer_data(conn).address
    for _ <- 1..9, do: assert(:ok = RateLimiter.check_login(peer))

    allowed =
      conn
      |> put_req_header("x-kith-client-ip", "203.0.113.10")
      |> post(~p"/users/log-in", user: %{email: user.email, password: "wrong-password"})

    assert redirected_to(allowed) == ~p"/users/log-in"

    denied =
      conn
      |> put_req_header("x-forwarded-for", "203.0.113.11")
      |> put_req_header("x-kith-client-ip", "203.0.113.12")
      |> post(~p"/users/log-in", user: %{email: user.email, password: valid_user_password()})

    assert denied.status == 429
    assert denied.halted
    assert [retry_after] = get_resp_header(denied, "retry-after")
    assert String.to_integer(retry_after) in 1..60
    refute get_session(denied, :user_token)
    refute Map.has_key?(denied.resp_cookies, "_kith_web_user_remember_me")

    # A genuinely different transport peer keeps its independent budget.
    other_peer = distinct_peer(peer)

    other =
      conn
      |> Map.put(:remote_ip, other_peer)
      |> Plug.Test.put_peer_data(%{address: other_peer, port: 12_345, ssl_cert: nil})
      |> post(~p"/users/log-in", user: %{email: user.email, password: valid_user_password()})

    assert get_session(other, :user_token)
  end

  test "signup counts invalid saves and blocks account creation on the sixth attempt", %{
    conn: conn
  } do
    {:ok, view, _} = live(conn, ~p"/users/register")

    for _ <- 1..5 do
      html =
        view
        |> form("#registration_form", user: %{email: "invalid", password: "short"})
        |> render_submit()

      assert html =~ "must have the @ sign"
      refute html =~ "Too many signup attempts"
    end

    email = unique_user_email()
    html = submit_signup(view, email)
    assert html =~ "Too many signup attempts. Please try again in"
    refute html =~ "phx-trigger-action"
    refute Accounts.get_user_by_email(email)
  end

  test "trusted canonical client identity governs both HTTP login and connected signup", %{
    conn: conn
  } do
    peer = Plug.Conn.get_peer_data(conn).address
    client = distinct_peer(peer)
    Kith.TestEnv.put_env_restoring(:kith, :trusted_proxies, [peer])
    for _ <- 1..10, do: assert(:ok = RateLimiter.check_login(client))
    for _ <- 1..5, do: assert(:ok = RateLimiter.check_signup(client))

    canonical = :inet.ntoa(client) |> to_string()
    conn = put_req_header(conn, "x-kith-client-ip", canonical)

    denied =
      post(conn, ~p"/users/log-in", user: %{email: "unused@example.com", password: "unused"})

    assert denied.status == 429
    assert denied.remote_ip == client

    {:ok, view, _} = live(conn, ~p"/users/register")
    email = unique_user_email()
    assert submit_signup(view, email) =~ "Too many signup attempts"
    refute Accounts.get_user_by_email(email)
  end

  test "signup ignores forged headers, mutable remote_ip and client connect params", %{conn: conn} do
    peer = Plug.Conn.get_peer_data(conn).address
    for _ <- 1..5, do: assert(:ok = RateLimiter.check_signup(peer))

    forged =
      conn
      |> Map.put(:remote_ip, {203, 0, 113, 50})
      |> put_req_header("x-kith-client-ip", "203.0.113.51")
      |> put_req_header("x-forwarded-for", "203.0.113.52")
      |> put_connect_params(%{"remote_ip" => "203.0.113.53", "ip" => "203.0.113.54"})

    {:ok, view, _} = live(forged, ~p"/users/register")
    email = unique_user_email()
    assert submit_signup(view, email) =~ "Too many signup attempts"
    refute Accounts.get_user_by_email(email)
  end

  test "connected signup fails closed without transport peer information", %{conn: conn} do
    conn =
      put_private(conn, :live_view_connect_info, %{
        x_headers: [{"x-kith-client-ip", "203.0.113.55"}]
      })

    {:ok, view, _} = live(conn, ~p"/users/register")
    email = unique_user_email()
    assert submit_signup(view, email) =~ "Unable to verify your connection"
    refute Accounts.get_user_by_email(email)
  end

  defp submit_signup(view, email) do
    view
    |> form("#registration_form", user: %{email: email, password: valid_user_password()})
    |> render_submit()
  end

  defp distinct_peer({_, _, third, fourth}), do: {198, 19, third, fourth}
end
