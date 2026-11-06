defmodule KithWeb.ContactLive.RelationshipsComponent do
  use KithWeb, :live_component

  alias Kith.Contacts

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:relationships, [])
     |> assign(:relationship_types, [])
     |> assign(:show_form, false)
     |> assign(:selected_type_id, nil)
     |> assign(:selected_contact_id, nil)
     |> assign(:confirming_delete_id, nil)
     |> assign(:contact_search, "")
     |> assign(:contact_results, [])}
  end

  @impl true
  def update(assigns, socket) do
    relationships = Contacts.list_relationships_for_contact(assigns.contact_id)
    types = Contacts.list_relationship_types(assigns.account_id)

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:relationships, relationships)
     |> assign(:relationship_types, types)}
  end

  @impl true
  def handle_event("show-form", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_form, true)
     |> assign(:selected_type_id, nil)
     |> assign(:selected_contact_id, nil)
     |> assign(:contact_search, "")
     |> assign(:contact_results, [])}
  end

  def handle_event("cancel-form", _params, socket) do
    {:noreply, socket |> assign(:show_form, false)}
  end

  def handle_event("validate", %{"relationship" => params}, socket) do
    {:noreply,
     socket
     |> assign(:selected_type_id, params["relationship_type_id"])
     |> assign(:selected_contact_id, params["related_contact_id"])}
  end

  def handle_event("search-contacts", %{"value" => query}, socket) do
    results =
      if String.length(query) >= 2 do
        socket.assigns.account_id
        |> Contacts.search_contacts(query)
        |> Enum.reject(&(&1.id == socket.assigns.contact_id))
        |> Enum.take(10)
      else
        []
      end

    {:noreply,
     socket
     |> assign(:contact_search, query)
     |> assign(:contact_results, results)}
  end

  def handle_event("save", %{"relationship" => params}, socket) do
    contact = Contacts.get_contact!(socket.assigns.account_id, socket.assigns.contact_id)

    case Contacts.create_relationship(contact, params) do
      {:ok, _} ->
        relationships = Contacts.list_relationships_for_contact(socket.assigns.contact_id)

        {:noreply,
         socket
         |> assign(:relationships, relationships)
         |> assign(:show_form, false)
         |> put_flash(:info, "Relationship added.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to save relationship.")}
    end
  end

  def handle_event("confirm-delete", %{"id" => id}, socket) do
    {:noreply, assign(socket, :confirming_delete_id, String.to_integer(id))}
  end

  def handle_event("cancel-delete", _params, socket) do
    {:noreply, assign(socket, :confirming_delete_id, nil)}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    rel = Contacts.get_relationship!(socket.assigns.account_id, String.to_integer(id))
    {:ok, _} = Contacts.delete_relationship(rel)
    relationships = Contacts.list_relationships_for_contact(socket.assigns.contact_id)

    {:noreply,
     socket
     |> assign(:relationships, relationships)
     |> assign(:confirming_delete_id, nil)
     |> put_flash(:info, "Relationship removed.")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <div class="flex items-center justify-between mb-2">
        <span class="font-semibold text-xs text-[var(--color-text-primary)]">Relationships</span>
        <%= if @can_edit do %>
          <button
            phx-click="show-form"
            phx-target={@myself}
            class="text-[var(--color-accent)] text-xs font-medium cursor-pointer"
          >
            + Add
          </button>
        <% end %>
      </div>

      <%= if @show_form do %>
        <div class="mb-4">
          <.form
            id={"#{@id}-relationship-form"}
            for={%{}}
            phx-submit="save"
            phx-change="validate"
            phx-target={@myself}
          >
            <div class="space-y-2">
              <div>
                <label class="block mb-1">
                  <span class="text-xs font-medium text-[var(--color-text-secondary)]">
                    Relationship Type
                  </span>
                </label>
                <select
                  name="relationship[relationship_type_id]"
                  class="w-full rounded-[var(--radius-md)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] px-2.5 py-1.5 text-sm text-[var(--color-text-primary)] placeholder:text-[var(--color-text-disabled)] focus:border-[var(--color-border-focus)] focus:outline-none focus:ring-2 focus:ring-[var(--color-border-focus)]/20 transition-colors duration-150"
                  required
                >
                  <option value="">Select type...</option>
                  <%= for type <- @relationship_types do %>
                    <option value={type.id} selected={to_string(type.id) == @selected_type_id}>
                      {type.name}
                    </option>
                  <% end %>
                </select>
              </div>
              <div>
                <label class="block mb-1">
                  <span class="text-xs font-medium text-[var(--color-text-secondary)]">
                    Related Contact
                  </span>
                </label>
                <input
                  type="text"
                  placeholder="Search contacts..."
                  value={@contact_search}
                  phx-keyup="search-contacts"
                  phx-target={@myself}
                  class="w-full rounded-[var(--radius-md)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] px-2.5 py-1.5 text-sm text-[var(--color-text-primary)] placeholder:text-[var(--color-text-disabled)] focus:border-[var(--color-border-focus)] focus:outline-none focus:ring-2 focus:ring-[var(--color-border-focus)]/20 transition-colors duration-150"
                  autocomplete="off"
                />
                <%= if @contact_results != [] do %>
                  <div class="mt-1 border border-[var(--color-border)] rounded-[var(--radius-lg)] bg-[var(--color-surface-elevated)] shadow-sm max-h-32 overflow-y-auto">
                    <%= for c <- @contact_results do %>
                      <label class="block w-full text-start px-3 py-1.5 text-sm hover:bg-[var(--color-surface-sunken)] cursor-pointer">
                        <input
                          type="radio"
                          name="relationship[related_contact_id]"
                          value={c.id}
                          checked={to_string(c.id) == @selected_contact_id}
                          class="size-4 rounded-[var(--radius-sm)] border border-[var(--color-border)] accent-[var(--color-accent)] cursor-pointer me-2"
                        />
                        {c.display_name}
                      </label>
                    <% end %>
                  </div>
                <% end %>
              </div>
            </div>
            <div class="flex gap-2 mt-3">
              <button
                type="submit"
                class="inline-flex items-center gap-1.5 rounded-[var(--radius-md)] bg-[var(--color-accent)] text-[var(--color-accent-foreground)] px-3 py-1.5 text-xs font-medium hover:bg-[var(--color-accent-hover)] transition-colors cursor-pointer"
              >
                Save
              </button>
              <button
                type="button"
                phx-click="cancel-form"
                phx-target={@myself}
                class="inline-flex items-center gap-1.5 rounded-[var(--radius-md)] px-2.5 py-1.5 text-xs font-medium text-[var(--color-text-secondary)] hover:bg-[var(--color-surface-sunken)] hover:text-[var(--color-text-primary)] transition-colors cursor-pointer"
              >
                Cancel
              </button>
            </div>
          </.form>
        </div>
      <% end %>

      <%= if @relationships == [] and not @show_form do %>
        <p class="text-xs text-[var(--color-text-disabled)]">No relationships added.</p>
      <% end %>

      <div class="space-y-2.5">
        <%= for rel <- @relationships do %>
          <div class="group flex items-center justify-between">
            <.link
              navigate={~p"/contacts/#{rel.related_contact.id}"}
              class="flex items-center gap-2.5 hover:opacity-80 transition-opacity"
            >
              <KithUI.avatar name={rel.related_contact.display_name} size={:sm} />
              <div>
                <div class="text-sm font-medium text-[var(--color-text-primary)]">
                  {rel.related_contact.display_name}
                </div>
                <div class="text-[11px] text-[var(--color-text-tertiary)]">{rel.label}</div>
              </div>
            </.link>
            <%= if @can_edit do %>
              <%= if @confirming_delete_id == rel.relationship.id do %>
                <div class="flex items-center gap-1.5">
                  <span class="text-xs text-[var(--color-text-secondary)]">Remove?</span>
                  <button
                    phx-click="delete"
                    phx-value-id={rel.relationship.id}
                    phx-target={@myself}
                    class="text-[var(--color-error)] hover:text-[var(--color-error)] transition-colors text-xs font-medium cursor-pointer"
                  >
                    Yes
                  </button>
                  <button
                    phx-click="cancel-delete"
                    phx-target={@myself}
                    class="text-[var(--color-text-secondary)] hover:text-[var(--color-text-primary)] transition-colors text-xs cursor-pointer"
                  >
                    No
                  </button>
                </div>
              <% else %>
                <button
                  phx-click="confirm-delete"
                  phx-value-id={rel.relationship.id}
                  phx-target={@myself}
                  class="text-[var(--color-error)] hover:text-[var(--color-error)] transition-colors text-xs cursor-pointer"
                >
                  Remove
                </button>
              <% end %>
            <% end %>
          </div>
        <% end %>
      </div>
    </div>
    """
  end
end
