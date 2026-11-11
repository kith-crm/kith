defmodule KithWeb.OIDCController do
  use KithWeb, :controller

  alias Kith.Accounts
  alias Kith.Auth.{OIDC, Policy, Principal}
  alias Kith.Auth.OIDC.Transactions
  alias KithWeb.Authentication

  plug :private_response

  @cookie "__Host-kith_oidc"
  @cookie_options [
    sign: true,
    secure: true,
    http_only: true,
    same_site: "Lax",
    path: "/",
    max_age: 300
  ]

  defp private_response(conn, _opts) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("referrer-policy", "no-referrer")
  end

  def request(conn, _params), do: start(conn, :login)
  def link(conn, _params), do: start(conn, :link)
  def reauth(conn, _params), do: start(conn, :reauth)

  defp start(conn, intent) do
    if Policy.oidc_enabled?() and authorized_start?(conn, intent) do
      conn = fetch_cookies(conn, signed: [@cookie])
      binding = get_session(conn, :auth_challenge_binding) || conn.cookies[@cookie] || random()
      user = conn.assigns[:current_scope] && conn.assigns.current_scope.user

      attrs = %{
        intent: intent,
        issuer: config()[:issuer],
        redirect_uri: KithWeb.Endpoint.url() <> "/auth/oidc/callback",
        return_to: return_to(conn, intent),
        user_id: user && user.id,
        session_token: if(intent != :login, do: get_session(conn, :user_token))
      }

      with {:ok, flow} <- Transactions.start(attrs, binding),
           {:ok, url} <- OIDC.authorize(flow, config()) do
        conn
        |> put_session(:auth_challenge_binding, binding)
        |> put_resp_cookie(@cookie, binding, @cookie_options)
        |> redirect(external: url)
      else
        _ -> failed(conn)
      end
    else
      failed(conn)
    end
  end

  def callback(conn, params) do
    conn |> register_before_send(&commit_browser_origin/1) |> complete_callback(params)
  end

  # A Strict cookie is withheld for the entire cross-site redirect chain, even
  # after the callback sets a new cookie. Commit a clean same-site document
  # before navigating to a route that needs that cookie. The signed value only
  # selects a local destination; it is never authentication evidence.
  def complete(conn, %{"destination" => token}) do
    case Phoenix.Token.verify(KithWeb.Endpoint, "oidc-browser-destination", token, max_age: 60) do
      {:ok, destination} when is_binary(destination) ->
        destination = Authentication.safe_return_to(destination)

        conn
        |> put_view(html: KithWeb.OIDCHTML)
        |> put_root_layout(false)
        |> render(:complete, destination: destination)

      _ ->
        conn |> fetch_flash() |> failed()
    end
  end

  def complete(conn, _params), do: conn |> fetch_flash() |> failed()

  defp commit_browser_origin(%{status: status} = conn) when status in [302, 303] do
    case get_resp_header(conn, "location") do
      ["/" <> _ = destination] ->
        token =
          Phoenix.Token.sign(
            KithWeb.Endpoint,
            "oidc-browser-destination",
            Authentication.safe_return_to(destination)
          )

        put_resp_header(conn, "location", ~p"/auth/oidc/complete?destination=#{token}")

      _ ->
        conn
    end
  end

  defp commit_browser_origin(conn), do: conn

  defp complete_callback(conn, params) do
    conn = fetch_cookies(conn, signed: [@cookie])
    binding = conn.cookies[@cookie]

    with {:ok, flow} <- Transactions.consume(params["state"], binding),
         true <- Policy.oidc_enabled?() and flow.issuer == config()[:issuer],
         true <- flow.intent in [:login, :link, :reauth],
         true <- same_browser_user?(conn, flow),
         false <- Map.has_key?(params, "error"),
         {:ok, principal} <- OIDC.callback(flow, params, config()) do
      dispatch(conn, flow, principal, binding)
    else
      _ -> failed(conn)
    end
  end

  defp dispatch(conn, %{intent: :login} = flow, principal, binding) do
    case Accounts.OIDC.resolve(principal) do
      {:ok, user} ->
        Authentication.begin_oidc(conn, user, flow, principal, browser_binding: binding)

      {:error, :registration_required} ->
        pending(conn, flow, principal, binding)

      {:error, :email_collision} ->
        collision(conn)
    end
  end

  defp dispatch(conn, flow, principal, binding) do
    case Accounts.get_user_by_session_token(flow.session_token) do
      {%{id: id} = user, _} when id == flow.user_id ->
        Authentication.begin_oidc(conn, user, flow, principal, browser_binding: binding)

      _ ->
        failed(conn)
    end
  end

  defp pending(conn, flow, principal, binding) do
    if Policy.registration_enabled?() and principal.email_verified == true and
         usable_email?(principal) do
      attrs = %{
        intent: :registration,
        issuer: flow.issuer,
        redirect_uri: flow.redirect_uri,
        return_to: flow.return_to,
        principal: Map.from_struct(principal)
      }

      {:ok, pending} = Transactions.start(attrs, binding)

      conn
      |> put_session(:auth_challenge_binding, binding)
      |> put_session(:oidc_registration, pending.state)
      |> redirect(to: ~p"/users/oidc/register")
    else
      conn
      |> put_flash(
        :error,
        "Registration requires enabled signups and a verified email from your provider."
      )
      |> redirect(to: ~p"/users/log-in")
    end
  end

  def register(conn, %{"cancel" => "true"} = params) do
    Transactions.consume(
      registration_handle(conn, params),
      get_session(conn, :auth_challenge_binding)
    )

    conn |> delete_session(:oidc_registration) |> redirect(to: ~p"/users/log-in")
  end

  def register(conn, params) do
    binding = get_session(conn, :auth_challenge_binding)
    handle = registration_handle(conn, params)
    attrs = registration_attrs(params)

    with true <- Policy.oidc_enabled?() and Policy.registration_enabled?(),
         {:ok, pending} <- Transactions.pending_registration(handle, binding),
         true <- pending.issuer == config()[:issuer] do
      complete_registration(conn, pending, binding, attrs)
    else
      _ -> failed(conn)
    end
  end

  defp complete_registration(conn, pending, binding, attrs) do
    principal = principal(pending.principal)

    if terms_accepted?(attrs) do
      with {:ok, consumed} <- Transactions.consume(pending.state, binding),
           {:ok, user} <- Accounts.OIDC.register(principal, attrs) do
        conn
        |> delete_session(:oidc_registration)
        |> Authentication.begin_oidc(user, %{consumed | intent: :login}, principal,
          browser_binding: binding
        )
      else
        {:error, :email_collision} -> collision(conn)
        _ -> failed(conn)
      end
    else
      conn
      |> put_flash(:error, "Please accept the Terms of Service to create your account.")
      |> redirect(to: ~p"/users/oidc/register")
    end
  end

  defp registration_handle(conn, params),
    do: params["registration_token"] || get_session(conn, :oidc_registration)

  defp registration_attrs(%{"user" => attrs}) when is_map(attrs),
    do: Map.take(attrs, ["tos_accepted"])

  defp registration_attrs(_), do: %{}

  defp terms_accepted?(attrs),
    do:
      not Application.get_env(:kith, :require_tos_acceptance, false) or
        attrs["tos_accepted"] in [true, "true"]

  defp same_browser_user?(_conn, %{intent: :login}), do: true

  defp same_browser_user?(conn, flow) do
    case conn.assigns[:current_scope] do
      nil -> true
      %{user: user} -> user.id == flow.user_id
    end
  end

  defp usable_email?(principal) do
    Accounts.User.oidc_registration_changeset(%Accounts.User{}, %{
      email: principal.email,
      tos_accepted: true
    }).valid?
  end

  defp principal(p),
    do: %Principal{
      issuer: p["issuer"],
      subject: p["subject"],
      email: p["email"],
      email_verified: p["email_verified"],
      name: p["name"],
      auth_time: p["auth_time"]
    }

  defp authorized_start?(_conn, :login), do: true

  defp authorized_start?(conn, intent) do
    case conn.assigns[:current_scope] do
      %{user: user} -> intent == :reauth or Authentication.require_recent(user) == :ok
      _ -> false
    end
  end

  defp return_to(_conn, :link), do: "/settings/security"
  defp return_to(conn, _), do: Authentication.safe_return_to(get_session(conn, :user_return_to))
  defp config, do: Application.fetch_env!(:kith, :auth).oidc
  defp random, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

  defp collision(conn),
    do:
      conn
      |> put_flash(
        :error,
        "Sign in to your existing account, then connect OpenID Connect in Security settings."
      )
      |> redirect(to: ~p"/users/log-in")

  defp failed(conn),
    do:
      conn
      |> put_flash(:error, "OpenID Connect is unavailable. Please try again.")
      |> redirect(to: ~p"/users/log-in")
end
