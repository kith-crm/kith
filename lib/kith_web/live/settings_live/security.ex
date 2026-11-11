defmodule KithWeb.SettingsLive.Security do
  use KithWeb, :live_view

  on_mount {KithWeb.UserAuth, :require_sudo_mode}

  alias Kith.Accounts
  alias Kith.Auth.Policy

  @impl true
  def render(assigns) do
    ~H"""
    <KithWeb.SettingsComponents.security
      flash={@flash}
      current_scope={@current_scope}
      current_path={@current_path}
      pending_duplicates_count={@pending_duplicates_count}
      password_login_enabled={@password_login_enabled}
      password_form={@password_form}
      trigger_submit={@trigger_submit}
      current_email={@current_email}
      oidc_enabled={Policy.oidc_enabled?()}
      oidc_display_name={
        (Application.fetch_env!(:kith, :auth).oidc || [])[:display_name] || "OpenID Connect"
      }
      oidc_identities={@oidc_identities}
      oidc_trigger_submit={@oidc_trigger_submit}
      unlink_id={@unlink_id}
      oidc_status={@oidc_status}
    />
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user

    {:ok,
     socket
     |> assign(:current_email, user.email)
     |> assign(
       oidc_identities: current_identities(user),
       unlink_id: nil,
       oidc_status: nil,
       oidc_trigger_submit: false
     )
     |> assign(:password_login_enabled, Policy.password_login_enabled?())
     |> assign(
       :password_form,
       to_form(Accounts.change_user_password(user, %{}, hash_password: false))
     )
     |> assign(:trigger_submit, false)}
  end

  @impl true
  def handle_event(event, params, socket)
      when event in ["validate_password", "update_password"] do
    if Policy.password_login_enabled?() do
      handle_password_event(event, params, socket)
    else
      {:noreply, assign(socket, password_login_enabled: false, trigger_submit: false)}
    end
  end

  def handle_event("link_oidc", _, socket) do
    if KithWeb.Authentication.require_recent(socket.assigns.current_scope.user) == :ok do
      {:noreply, assign(socket, oidc_trigger_submit: Policy.oidc_enabled?())}
    else
      {:noreply, redirect(socket, to: ~p"/users/reauth?return_to=security")}
    end
  end

  def handle_event("confirm_unlink", %{"id" => id}, socket) do
    owned =
      Enum.find(current_identities(socket.assigns.current_scope.user), &(to_string(&1.id) == id))

    {:noreply, assign(socket, unlink_id: owned && owned.id)}
  end

  def handle_event("cancel_unlink", _, socket), do: {:noreply, assign(socket, unlink_id: nil)}

  def handle_event("unlink_oidc", _, socket) do
    user = socket.assigns.current_scope.user

    cond do
      KithWeb.Authentication.require_recent(user) != :ok ->
        {:noreply, redirect(socket, to: ~p"/users/reauth?return_to=security")}

      not Policy.oidc_enabled?() or is_nil(socket.assigns.unlink_id) ->
        {:noreply, assign(socket, oidc_status: "Please select an identity to unlink.")}

      true ->
        case Accounts.OIDC.unlink(user, socket.assigns.unlink_id) do
          :ok ->
            {:noreply,
             assign(socket,
               oidc_identities: current_identities(user),
               unlink_id: nil,
               oidc_status: "Identity unlinked."
             )}

          {:error, :last_login_method} ->
            {:noreply,
             assign(socket, oidc_status: "Cannot unlink your last available sign-in method.")}

          _ ->
            {:noreply,
             assign(socket, oidc_status: "Unable to unlink this identity. Please try again.")}
        end
    end
  end

  defp current_identities(user) do
    issuer = if Policy.oidc_enabled?(), do: Application.fetch_env!(:kith, :auth).oidc[:issuer]
    Enum.filter(Accounts.OIDC.list(user), &(&1.issuer == issuer))
  end

  defp handle_password_event("validate_password", params, socket) do
    %{"user" => user_params} = params

    password_form =
      socket.assigns.current_scope.user
      |> Accounts.change_user_password(user_params, hash_password: false)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, password_form: password_form)}
  end

  defp handle_password_event("update_password", params, socket) do
    %{"user" => user_params} = params
    user = socket.assigns.current_scope.user

    if KithWeb.Authentication.require_recent(user) == :ok do
      update_sensitive(socket, user, user_params)
    else
      {:noreply, redirect(socket, to: ~p"/users/reauth?return_to=security")}
    end
  end

  defp update_sensitive(socket, user, user_params) do
    case Accounts.change_user_password(user, user_params) do
      %{valid?: true} = changeset ->
        {:noreply, assign(socket, trigger_submit: true, password_form: to_form(changeset))}

      changeset ->
        {:noreply, assign(socket, password_form: to_form(changeset, action: :insert))}
    end
  end
end
