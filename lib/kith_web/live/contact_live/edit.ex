defmodule KithWeb.ContactLive.Edit do
  use KithWeb, :live_view

  alias Kith.Contacts
  alias Kith.Contacts.Contact

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Edit Contact")
     |> assign(:contact, nil)
     |> assign(:changeset, Contact.update_changeset(%Contact{}, %{}))
     |> assign(:genders, [])
     |> assign(:show_deceased_at, false)}
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    user = socket.assigns.current_scope.user

    if Kith.Policy.can?(user, :update, :contact) do
      account_id = socket.assigns.current_scope.account.id

      contact =
        Contacts.get_contact!(account_id, String.to_integer(id))
        |> Kith.Repo.preload([:gender])

      changeset = Contact.update_changeset(contact, %{})

      {:noreply,
       socket
       |> assign(:page_title, "Edit #{contact.display_name}")
       |> assign(:contact, contact)
       |> assign(:account_id, account_id)
       |> assign(:changeset, changeset)
       |> assign(:genders, Contacts.list_genders(account_id))
       |> assign(:show_deceased_at, contact.deceased || false)}
    else
      {:noreply,
       socket
       |> put_flash(:error, "You don't have permission to edit contacts")
       |> push_navigate(to: ~p"/contacts")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_path={@current_path}
      pending_duplicates_count={@pending_duplicates_count}
    >
      <div class="max-w-3xl mx-auto">
        <h1 class="text-2xl font-semibold text-[var(--color-text-primary)] tracking-tight mb-6">
          {if @contact, do: "Edit #{@contact.display_name}", else: "Edit Contact"}
        </h1>

        <UI.simple_form
          :let={f}
          for={@changeset}
          id="contact-form"
          as={:contact}
          phx-change="validate"
          phx-submit="save"
        >
          <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
            <UI.input field={f[:first_name]} type="text" label="First Name" />
            <UI.input field={f[:last_name]} type="text" label="Last Name" />
            <UI.input field={f[:nickname]} type="text" label="Nickname" />
            <UI.input
              field={f[:gender_id]}
              type="select"
              label="Gender"
              prompt="Select gender"
              options={Enum.map(@genders, &{&1.name, &1.id})}
            />
            <UI.input field={f[:birthdate]} type="date" label="Birthdate" />
            <UI.input field={f[:occupation]} type="text" label="Occupation" />
            <UI.input field={f[:company]} type="text" label="Company" />
            <UI.input field={f[:deceased]} type="checkbox" label="Deceased" />
            <UI.input field={f[:favorite]} type="checkbox" label="Favorite" />
          </div>

          <UI.input :if={@show_deceased_at} field={f[:deceased_at]} type="date" label="Date of Death" />

          <:actions>
            <UI.button
              variant="ghost"
              navigate={if @contact, do: ~p"/contacts/#{@contact.id}", else: ~p"/contacts"}
            >
              Cancel
            </UI.button>
            <UI.button type="submit" phx-disable-with="Saving...">Save Changes</UI.button>
          </:actions>
        </UI.simple_form>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("validate", %{"contact" => contact_params}, socket) do
    changeset =
      (socket.assigns.contact || %Contact{})
      |> Contact.update_changeset(contact_params)
      |> Map.put(:action, :validate)

    show_deceased = contact_params["deceased"] == "true"

    {:noreply,
     socket
     |> assign(:changeset, changeset)
     |> assign(:show_deceased_at, show_deceased)}
  end

  def handle_event("save", %{"contact" => contact_params}, socket) do
    account_id = socket.assigns.account_id
    user = socket.assigns.current_scope.user
    contact = socket.assigns.contact

    case Contacts.update_contact(contact, contact_params) do
      {:ok, updated_contact} ->
        Kith.AuditLogs.log_event(account_id, user, :contact_updated,
          contact_id: updated_contact.id,
          contact_name: updated_contact.display_name
        )

        {:noreply,
         socket
         |> put_flash(:info, "Contact updated successfully.")
         |> push_navigate(to: ~p"/contacts/#{updated_contact.id}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :changeset, changeset)}
    end
  end
end
