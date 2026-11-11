defmodule KithWeb.UserLive.OIDCRegistrationTest do
  use KithWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  test "registration without a pending verified identity returns to login", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(conn, "/users/oidc/register")
  end

  test "terms form renders only verified profile and accessible validation", %{conn: conn} do
    old = Application.fetch_env!(:kith, :auth)
    old_terms = Application.get_env(:kith, :require_tos_acceptance)

    Application.put_env(:kith, :auth, %{
      old
      | oidc_enabled: true,
        oidc: [issuer: "https://issuer.test"]
    })

    Application.put_env(:kith, :require_tos_acceptance, true)

    on_exit(fn ->
      Application.put_env(:kith, :auth, old)
      Application.put_env(:kith, :require_tos_acceptance, old_terms)
    end)

    binding = String.duplicate("b", 32)

    {:ok, pending} =
      Kith.Auth.OIDC.Transactions.start(
        %{
          intent: :registration,
          issuer: "https://issuer.test",
          redirect_uri: "https://kith.test/auth/oidc/callback",
          return_to: "/dashboard",
          principal: %{email: "verified@example.test"}
        },
        binding
      )

    conn =
      init_test_session(conn, %{oidc_registration: pending.state, auth_challenge_binding: binding})

    {:ok, view, html} = live(conn, "/users/oidc/register")
    assert html =~ "verified@example.test"
    refute has_element?(view, "input[name='user[email]']")
    view |> form("#oidc-registration-form", user: %{tos_accepted: "false"}) |> render_submit()
    assert has_element?(view, "[role='alert']", "Please accept")
    refute has_element?(view, "form[phx-trigger-action]")
    view |> form("#oidc-registration-form", user: %{tos_accepted: "true"}) |> render_submit()
    assert has_element?(view, "form[phx-trigger-action]")
    {:ok, changed, _} = live(conn, "/users/oidc/register")
    config = Application.fetch_env!(:kith, :auth)
    Application.put_env(:kith, :auth, %{config | registration_enabled: false})
    changed |> form("#oidc-registration-form", user: %{tos_accepted: "true"}) |> render_submit()
    assert_redirect(changed, "/users/log-in")
  end
end
