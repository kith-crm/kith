defmodule KithWeb.SettingsLive.ContactSync do
  use KithWeb, :live_view
  alias Kith.Accounts.{DavAppPassword, DavAppPasswords}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "Contact sync",
       revealed_secret: nil,
       created_credential: nil,
       selected: nil
     )
     |> assign(:carddav_url, KithWeb.Endpoint.url() <> "/dav/principals/")}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket =
      socket
      |> assign(revealed_secret: nil, created_credential: nil, selected: nil)
      |> assign(:credentials, DavAppPasswords.list(socket.assigns.current_scope.user))
      |> assign(:form, to_form(DavAppPassword.changeset(%DavAppPassword{}, %{}), as: :credential))

    case socket.assigns.live_action do
      :created ->
        {:noreply, push_patch(socket, to: ~p"/settings/contact-sync", replace: true)}

      :revoke ->
        selected =
          Enum.find(
            socket.assigns.credentials,
            &(to_string(&1.id) == params["id"] and is_nil(&1.revoked_at))
          )

        if selected,
          do: {:noreply, assign(socket, :selected, selected)},
          else: {:noreply, unavailable(socket)}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("create", %{"credential" => params}, socket) do
    if socket.assigns.live_action == :new and is_nil(socket.assigns.revealed_secret) do
      case DavAppPasswords.create(socket.assigns.current_scope.user, %{name: params["name"]}) do
        {:ok, row, plaintext} ->
          {:noreply,
           assign(socket,
             live_action: :created,
             created_credential: row,
             revealed_secret: plaintext
           )}

        {:error, :reauthentication_required} ->
          {:noreply, reauthenticate(socket, "new")}

        {:error, changeset} ->
          {:noreply, assign(socket, :form, to_form(changeset, as: :credential))}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("revoke", params, socket) do
    selected = socket.assigns.selected

    if selected && to_string(selected.id) == to_string(params["id"]) do
      case DavAppPasswords.revoke(socket.assigns.current_scope.user, selected.id) do
        :ok ->
          {:noreply,
           socket
           |> put_flash(:info, "App password revoked")
           |> push_patch(to: ~p"/settings/contact-sync")}

        {:error, :reauthentication_required} ->
          {:noreply, reauthenticate(socket, "index")}

        {:error, :not_found} ->
          {:noreply, unavailable(socket)}
      end
    else
      {:noreply, unavailable(socket)}
    end
  end

  defp reauthenticate(socket, destination) do
    socket
    |> assign(:revealed_secret, nil)
    |> redirect(to: ~p"/settings/contact-sync/reauth?return_to=#{destination}")
  end

  defp unavailable(socket) do
    socket
    |> assign(:revealed_secret, nil)
    |> put_flash(:error, "App password is unavailable.")
    |> push_patch(to: ~p"/settings/contact-sync")
  end

  @impl true
  def render(assigns) do
    ~H"""
    <KithWeb.SettingsComponents.contact_sync
      flash={@flash}
      current_scope={@current_scope}
      current_path={@current_path}
      pending_duplicates_count={@pending_duplicates_count}
      live_action={@live_action}
      credentials={@credentials}
      form={@form}
      revealed_secret={@revealed_secret}
      created_credential={@created_credential}
      selected={@selected}
      carddav_url={@carddav_url}
      password_login_enabled={Kith.Auth.Policy.password_login_enabled?()}
    />
    """
  end
end
