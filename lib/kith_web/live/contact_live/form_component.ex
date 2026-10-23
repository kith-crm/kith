defmodule KithWeb.ContactLive.FormComponent do
  use KithWeb, :live_component

  alias Kith.Contacts
  alias Kith.Contacts.Contact

  @impl true
  def update(%{contact: contact, account_id: account_id} = assigns, socket) do
    changeset = Contact.update_changeset(contact, %{})

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:changeset, changeset)
     |> assign(:genders, Contacts.list_genders(account_id))
     |> assign(:show_deceased_at, contact.deceased || false)}
  end

  @impl true
  def handle_event("validate", %{"contact" => contact_params}, socket) do
    changeset =
      socket.assigns.contact
      |> Contact.update_changeset(contact_params)
      |> Map.put(:action, :validate)

    show_deceased = contact_params["deceased"] == "true"

    {:noreply,
     socket
     |> assign(:changeset, changeset)
     |> assign(:show_deceased_at, show_deceased)}
  end

  def handle_event("save", %{"contact" => contact_params}, socket) do
    save_contact(socket, socket.assigns.action, contact_params)
  end

  defp save_contact(socket, :new, contact_params) do
    account_id = socket.assigns.account_id
    user = socket.assigns.current_scope.user

    case Contacts.create_contact(account_id, contact_params) do
      {:ok, contact} ->
        Kith.AuditLogs.log_event(account_id, user, :contact_created,
          contact_id: contact.id,
          contact_name: contact.display_name
        )

        {:noreply,
         socket
         |> put_flash(:info, "Contact created successfully.")
         |> push_navigate(to: ~p"/contacts/#{contact.id}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :changeset, changeset)}
    end
  end

  defp save_contact(socket, :edit, contact_params) do
    account_id = socket.assigns.account_id
    user = socket.assigns.current_scope.user
    contact = socket.assigns.contact

    case Contacts.update_contact(contact, contact_params) do
      {:ok, updated_contact} ->
        Kith.AuditLogs.log_event(account_id, user, :contact_updated,
          contact_id: updated_contact.id,
          contact_name: updated_contact.display_name,
          metadata: %{changed_fields: changed_fields(contact_params, contact)}
        )

        {:noreply,
         socket
         |> put_flash(:info, "Contact updated successfully.")
         |> push_navigate(to: ~p"/contacts/#{updated_contact.id}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :changeset, changeset)}
    end
  end

  defp changed_fields(params, contact) do
    params
    |> Enum.filter(fn {key, value} ->
      current = Map.get(contact, String.to_existing_atom(key))
      to_string(current) != to_string(value)
    end)
    |> Enum.map(fn {key, _} -> key end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <.form
        for={@changeset}
        id="contact-form"
        phx-target={@myself}
        phx-change="validate"
        phx-submit="save"
      >
        <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
          <div>
            <label class="block text-sm font-medium text-[var(--color-text-primary)] mb-1.5">
              First Name
            </label>
            <input
              type="text"
              name="contact[first_name]"
              value={Ecto.Changeset.get_field(@changeset, :first_name)}
              class="w-full rounded-[var(--radius-md)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] px-3 py-2 text-sm text-[var(--color-text-primary)] placeholder:text-[var(--color-text-disabled)] focus:border-[var(--color-border-focus)] focus:outline-none focus:ring-2 focus:ring-[var(--color-border-focus)]/20 transition-colors duration-150"
            />
            <p
              :for={msg <- changeset_errors(@changeset, :first_name)}
              class="mt-1.5 flex items-center gap-1.5 text-xs text-[var(--color-error)]"
            >
              <.icon name="hero-exclamation-circle-mini" class="size-4 shrink-0" />
              {msg}
            </p>
          </div>

          <div>
            <label class="block text-sm font-medium text-[var(--color-text-primary)] mb-1.5">
              Last Name
            </label>
            <input
              type="text"
              name="contact[last_name]"
              value={Ecto.Changeset.get_field(@changeset, :last_name)}
              class="w-full rounded-[var(--radius-md)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] px-3 py-2 text-sm text-[var(--color-text-primary)] placeholder:text-[var(--color-text-disabled)] focus:border-[var(--color-border-focus)] focus:outline-none focus:ring-2 focus:ring-[var(--color-border-focus)]/20 transition-colors duration-150"
            />
          </div>

          <div>
            <label class="block text-sm font-medium text-[var(--color-text-primary)] mb-1.5">
              Nickname
            </label>
            <input
              type="text"
              name="contact[nickname]"
              value={Ecto.Changeset.get_field(@changeset, :nickname)}
              class="w-full rounded-[var(--radius-md)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] px-3 py-2 text-sm text-[var(--color-text-primary)] placeholder:text-[var(--color-text-disabled)] focus:border-[var(--color-border-focus)] focus:outline-none focus:ring-2 focus:ring-[var(--color-border-focus)]/20 transition-colors duration-150"
            />
          </div>

          <div>
            <label class="block text-sm font-medium text-[var(--color-text-primary)] mb-1.5">
              Gender
            </label>
            <select
              name="contact[gender_id]"
              class="w-full rounded-[var(--radius-md)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] px-3 py-2 text-sm text-[var(--color-text-primary)] focus:border-[var(--color-border-focus)] focus:outline-none focus:ring-2 focus:ring-[var(--color-border-focus)]/20 transition-colors duration-150"
            >
              <option value="">Select gender</option>
              <%= for gender <- @genders do %>
                <option
                  value={gender.id}
                  selected={Ecto.Changeset.get_field(@changeset, :gender_id) == gender.id}
                >
                  {gender.name}
                </option>
              <% end %>
            </select>
          </div>

          <div>
            <label class="block text-sm font-medium text-[var(--color-text-primary)] mb-1.5">
              Birthdate
            </label>
            <input
              type="date"
              name="contact[birthdate]"
              value={Ecto.Changeset.get_field(@changeset, :birthdate)}
              class="w-full rounded-[var(--radius-md)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] px-3 py-2 text-sm text-[var(--color-text-primary)] focus:border-[var(--color-border-focus)] focus:outline-none focus:ring-2 focus:ring-[var(--color-border-focus)]/20 transition-colors duration-150"
            />
          </div>

          <div>
            <label class="block text-sm font-medium text-[var(--color-text-primary)] mb-1.5">
              Occupation
            </label>
            <input
              type="text"
              name="contact[occupation]"
              value={Ecto.Changeset.get_field(@changeset, :occupation)}
              class="w-full rounded-[var(--radius-md)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] px-3 py-2 text-sm text-[var(--color-text-primary)] placeholder:text-[var(--color-text-disabled)] focus:border-[var(--color-border-focus)] focus:outline-none focus:ring-2 focus:ring-[var(--color-border-focus)]/20 transition-colors duration-150"
            />
          </div>

          <div>
            <label class="block text-sm font-medium text-[var(--color-text-primary)] mb-1.5">
              Company
            </label>
            <input
              type="text"
              name="contact[company]"
              value={Ecto.Changeset.get_field(@changeset, :company)}
              class="w-full rounded-[var(--radius-md)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] px-3 py-2 text-sm text-[var(--color-text-primary)] placeholder:text-[var(--color-text-disabled)] focus:border-[var(--color-border-focus)] focus:outline-none focus:ring-2 focus:ring-[var(--color-border-focus)]/20 transition-colors duration-150"
            />
          </div>

          <div class="flex items-start gap-3 pt-6">
            <input
              type="checkbox"
              name="contact[deceased]"
              value="true"
              checked={Ecto.Changeset.get_field(@changeset, :deceased)}
              class="mt-0.5 size-4 rounded-[var(--radius-sm)] border border-[var(--color-border)] accent-[var(--color-accent)] cursor-pointer"
            />
            <label class="text-sm font-medium text-[var(--color-text-primary)] cursor-pointer select-none">
              Deceased
            </label>
          </div>

          <%= if @show_deceased_at do %>
            <div>
              <label class="block text-sm font-medium text-[var(--color-text-primary)] mb-1.5">
                Date of Death
              </label>
              <input
                type="date"
                name="contact[deceased_at]"
                value={Ecto.Changeset.get_field(@changeset, :deceased_at)}
                class="w-full rounded-[var(--radius-md)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] px-3 py-2 text-sm text-[var(--color-text-primary)] focus:border-[var(--color-border-focus)] focus:outline-none focus:ring-2 focus:ring-[var(--color-border-focus)]/20 transition-colors duration-150"
              />
            </div>
          <% end %>
        </div>

        <div class="mt-4">
          <label class="block text-sm font-medium text-[var(--color-text-primary)] mb-1.5">
            Description
          </label>
          <textarea
            name="contact[description]"
            class="w-full rounded-[var(--radius-md)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] px-3 py-2.5 text-sm text-[var(--color-text-primary)] placeholder:text-[var(--color-text-disabled)] focus:border-[var(--color-border-focus)] focus:outline-none focus:ring-2 focus:ring-[var(--color-border-focus)]/20 transition-colors duration-150 min-h-[80px]"
          >{Ecto.Changeset.get_field(@changeset, :description)}</textarea>
        </div>

        <div class="mt-6 flex justify-end gap-3">
          <UI.button variant="ghost" navigate={@return_to}>Cancel</UI.button>
          <UI.button type="submit" phx-disable-with="Saving...">
            {if @action == :new, do: "Create Contact", else: "Save Changes"}
          </UI.button>
        </div>
      </.form>
    </div>
    """
  end

  defp changeset_errors(changeset, field) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Map.get(field, [])
  end
end
