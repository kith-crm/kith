defmodule KithWeb.ContactLive.AboutComponent do
  use KithWeb, :live_component

  alias Kith.Contacts

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:editing, false)
     |> assign(:contact_search, "")
     |> assign(:contact_results, [])
     |> assign(:selected_contact_id, nil)}
  end

  @impl true
  def update(assigns, socket) do
    {:ok, socket |> assign(assigns)}
  end

  @impl true
  def handle_event("edit", _params, socket) do
    selected_id = socket.assigns.contact.first_met_through_id

    {:noreply,
     socket
     |> assign(:editing, true)
     |> assign(:contact_search, "")
     |> assign(:contact_results, [])
     |> assign(:selected_contact_id, selected_id && to_string(selected_id))}
  end

  def handle_event("cancel", _params, socket) do
    {:noreply,
     socket
     |> assign(:editing, false)
     |> assign(:contact_search, "")
     |> assign(:contact_results, [])}
  end

  def handle_event("search-contacts", %{"value" => query}, socket) do
    results =
      if String.length(query) >= 2 do
        socket.assigns.account_id
        |> Contacts.search_contacts(query)
        |> Enum.reject(&(&1.id == socket.assigns.contact.id))
        |> Enum.take(8)
      else
        []
      end

    {:noreply,
     socket
     |> assign(:contact_search, query)
     |> assign(:contact_results, results)}
  end

  def handle_event("select-contact", %{"id" => id}, socket) do
    {:noreply,
     socket
     |> assign(:selected_contact_id, id)
     |> assign(:contact_search, "")
     |> assign(:contact_results, [])}
  end

  def handle_event("clear-contact", _params, socket) do
    {:noreply, assign(socket, :selected_contact_id, nil)}
  end

  def handle_event("save", %{"contact" => params}, socket) do
    contact = socket.assigns.contact

    params =
      Map.put(params, "first_met_through_id", socket.assigns.selected_contact_id || "")

    case Contacts.update_contact(contact, params) do
      {:ok, updated} ->
        updated = Kith.Repo.preload(updated, [:first_met_through], force: true)
        send(self(), {:contact_updated, updated})

        {:noreply,
         socket
         |> assign(:contact, updated)
         |> assign(:editing, false)
         |> put_flash(:info, "Updated.")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not save changes.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id}>
      <div class="flex justify-between items-center">
        <span class="font-semibold text-xs text-[var(--color-text-primary)]">About</span>
        <button
          :if={@can_edit && !@editing}
          phx-click="edit"
          phx-target={@myself}
          class="text-[var(--color-accent)] text-xs font-medium cursor-pointer hover:underline"
        >
          Edit
        </button>
      </div>

      <%= if @editing do %>
        <.form for={%{}} phx-submit="save" phx-target={@myself} class="mt-2 space-y-2.5">
          <div>
            <label class="block text-xs font-medium text-[var(--color-text-secondary)] mb-0.5">
              About
            </label>
            <textarea
              name="contact[description]"
              rows="3"
              class="w-full rounded-[var(--radius-md)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] px-2 py-1.5 text-xs text-[var(--color-text-primary)] placeholder:text-[var(--color-text-disabled)] focus:border-[var(--color-border-focus)] focus:outline-none focus:ring-2 focus:ring-[var(--color-border-focus)]/20"
              placeholder="A short description..."
            >{@contact.description}</textarea>
          </div>

          <div class="border-t border-[var(--color-border-subtle)] pt-2">
            <span class="text-[11px] text-[var(--color-text-tertiary)] font-medium">
              How we met
            </span>
          </div>

          <div>
            <label class="block text-xs font-medium text-[var(--color-text-secondary)] mb-0.5">
              When
            </label>
            <input
              type="date"
              name="contact[first_met_at]"
              value={@contact.first_met_at}
              class="w-full rounded-[var(--radius-md)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] px-2 py-1.5 text-xs text-[var(--color-text-primary)] focus:border-[var(--color-border-focus)] focus:outline-none focus:ring-2 focus:ring-[var(--color-border-focus)]/20"
            />
          </div>

          <label class="flex items-center gap-2 text-xs text-[var(--color-text-secondary)] cursor-pointer">
            <input type="hidden" name="contact[first_met_reminder]" value="false" />
            <input
              type="checkbox"
              name="contact[first_met_reminder]"
              value="true"
              checked={@contact.first_met_reminder}
              class="rounded border-[var(--color-border)]"
            /> Remind me every year
          </label>

          <div>
            <label class="block text-xs font-medium text-[var(--color-text-secondary)] mb-0.5">
              Where
            </label>
            <input
              type="text"
              name="contact[first_met_where]"
              value={@contact.first_met_where}
              placeholder="e.g. Coffee shop, conference..."
              class="w-full rounded-[var(--radius-md)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] px-2 py-1.5 text-xs text-[var(--color-text-primary)] placeholder:text-[var(--color-text-disabled)] focus:border-[var(--color-border-focus)] focus:outline-none focus:ring-2 focus:ring-[var(--color-border-focus)]/20"
            />
          </div>

          <div>
            <label class="block text-xs font-medium text-[var(--color-text-secondary)] mb-0.5">
              Through
            </label>
            <%= if @selected_contact_id do %>
              <.selected_contact_badge
                id={"#{@id}-through-avatar"}
                contact={find_selected_contact(@contact, @selected_contact_id)}
                myself={@myself}
              />
            <% else %>
              <input
                type="text"
                placeholder="Search contacts..."
                value={@contact_search}
                phx-keyup="search-contacts"
                phx-target={@myself}
                class="w-full rounded-[var(--radius-md)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] px-2 py-1.5 text-xs text-[var(--color-text-primary)] placeholder:text-[var(--color-text-disabled)] focus:border-[var(--color-border-focus)] focus:outline-none focus:ring-2 focus:ring-[var(--color-border-focus)]/20"
                autocomplete="off"
              />
              <%= if @contact_results != [] do %>
                <div class="mt-1 border border-[var(--color-border)] rounded-[var(--radius-md)] bg-[var(--color-surface-elevated)] shadow-sm max-h-36 overflow-y-auto">
                  <%= for c <- @contact_results do %>
                    <button
                      type="button"
                      phx-click="select-contact"
                      phx-value-id={c.id}
                      phx-target={@myself}
                      class="flex items-center gap-2 w-full text-start px-2 py-1.5 text-xs hover:bg-[var(--color-surface-sunken)] cursor-pointer transition-colors"
                    >
                      <KithUI.avatar
                        id={"#{@id}-search-avatar-#{c.id}"}
                        name={c.display_name}
                        src={KithUI.avatar_url(c)}
                        size={:sm}
                      />
                      <span class="truncate">{c.display_name}</span>
                    </button>
                  <% end %>
                </div>
              <% end %>
            <% end %>
          </div>

          <div>
            <label class="block text-xs font-medium text-[var(--color-text-secondary)] mb-0.5">
              Additional info
            </label>
            <textarea
              name="contact[first_met_additional_info]"
              rows="2"
              class="w-full rounded-[var(--radius-md)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] px-2 py-1.5 text-xs text-[var(--color-text-primary)] placeholder:text-[var(--color-text-disabled)] focus:border-[var(--color-border-focus)] focus:outline-none focus:ring-2 focus:ring-[var(--color-border-focus)]/20"
              placeholder="Extra context about how you met..."
            >{@contact.first_met_additional_info}</textarea>
          </div>

          <div class="flex gap-2">
            <button
              type="submit"
              class="inline-flex items-center gap-1 rounded-[var(--radius-md)] bg-[var(--color-accent)] text-[var(--color-accent-foreground)] px-2.5 py-1 text-xs font-medium hover:bg-[var(--color-accent-hover)] transition-colors cursor-pointer"
            >
              Save
            </button>
            <button
              type="button"
              phx-click="cancel"
              phx-target={@myself}
              class="rounded-[var(--radius-md)] px-2.5 py-1 text-xs font-medium text-[var(--color-text-secondary)] hover:bg-[var(--color-surface-sunken)] transition-colors cursor-pointer"
            >
              Cancel
            </button>
          </div>
        </.form>
      <% else %>
        <p
          :if={@contact.description}
          class="text-xs text-[var(--color-text-secondary)] mt-1 leading-relaxed"
        >
          {@contact.description}
        </p>
        <p :if={!@contact.description} class="text-xs text-[var(--color-text-disabled)] mt-1">
          No description added.
        </p>
        <div class="border-t border-[var(--color-border-subtle)] mt-2 pt-2">
          <span class="text-[11px] text-[var(--color-text-tertiary)]">How we met</span>
          <%= if has_first_met_data?(@contact) do %>
            <dl class="mt-1 space-y-1 text-xs">
              <div :if={@contact.first_met_at} class="flex justify-between">
                <dt class="text-[var(--color-text-tertiary)]">When</dt>
                <dd>
                  <KithUI.date_display
                    date={@contact.first_met_at}
                    year_unknown={@contact.first_met_year_unknown}
                  />
                </dd>
              </div>
              <div :if={@contact.first_met_where} class="flex justify-between">
                <dt class="text-[var(--color-text-tertiary)]">Where</dt>
                <dd>{@contact.first_met_where}</dd>
              </div>
              <div :if={@contact.first_met_through} class="flex justify-between">
                <dt class="text-[var(--color-text-tertiary)]">Through</dt>
                <dd>
                  <.link
                    navigate={~p"/contacts/#{@contact.first_met_through.id}"}
                    class="text-[var(--color-accent)] hover:underline"
                  >
                    {@contact.first_met_through.display_name}
                  </.link>
                </dd>
              </div>
            </dl>
            <p
              :if={@contact.first_met_additional_info}
              class="text-xs text-[var(--color-text-secondary)] mt-1 leading-relaxed"
            >
              {@contact.first_met_additional_info}
            </p>
          <% else %>
            <p class="text-xs text-[var(--color-text-disabled)] mt-1">Not recorded yet.</p>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  defp selected_contact_badge(assigns) do
    ~H"""
    <div class="flex items-center gap-2 rounded-[var(--radius-md)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] px-2 py-1.5">
      <%= if @contact do %>
        <KithUI.avatar
          id={@id}
          name={@contact.display_name}
          src={KithUI.avatar_url(@contact)}
          size={:sm}
        />
        <span class="text-xs text-[var(--color-text-primary)] flex-1 truncate">
          {@contact.display_name}
        </span>
      <% else %>
        <span class="text-xs text-[var(--color-text-disabled)] flex-1">Unknown contact</span>
      <% end %>
      <button
        type="button"
        phx-click="clear-contact"
        phx-target={@myself}
        class="text-[var(--color-text-tertiary)] hover:text-[var(--color-error)] cursor-pointer"
      >
        <.icon name="hero-x-mark" class="size-3.5" />
      </button>
    </div>
    """
  end

  defp find_selected_contact(contact, selected_id) do
    id = if is_binary(selected_id), do: String.to_integer(selected_id), else: selected_id

    if contact.first_met_through && contact.first_met_through.id == id do
      contact.first_met_through
    else
      try do
        Contacts.get_contact!(contact.account_id, id)
      rescue
        Ecto.NoResultsError -> nil
      end
    end
  end

  defp has_first_met_data?(contact) do
    contact.first_met_at != nil or
      contact.first_met_where not in [nil, ""] or
      contact.first_met_through_id != nil or
      contact.first_met_additional_info not in [nil, ""]
  end
end
