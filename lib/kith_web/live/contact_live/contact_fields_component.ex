defmodule KithWeb.ContactLive.ContactFieldsComponent do
  use KithWeb, :live_component

  alias Kith.Contacts
  alias Kith.Contacts.PhoneFormatter

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:fields, [])
     |> assign(:field_types, [])
     |> assign(:show_form, false)
     |> assign(:editing_id, nil)}
  end

  @impl true
  def update(assigns, socket) do
    fields = Contacts.list_contact_fields(assigns.contact_id)
    field_types = Contacts.list_contact_field_types(assigns.account_id)

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:fields, fields)
     |> assign(:field_types, field_types)}
  end

  @impl true
  def handle_event("show-form", _params, socket) do
    {:noreply, socket |> assign(:show_form, true) |> assign(:editing_id, nil)}
  end

  def handle_event("cancel-form", _params, socket) do
    {:noreply, socket |> assign(:show_form, false) |> assign(:editing_id, nil)}
  end

  def handle_event("save", %{"contact_field" => params}, socket) do
    contact = Contacts.get_contact!(socket.assigns.account_id, socket.assigns.contact_id)

    case Contacts.create_contact_field(contact, params) do
      {:ok, _} ->
        fields = Contacts.list_contact_fields(socket.assigns.contact_id)

        {:noreply,
         socket
         |> assign(:fields, fields)
         |> assign(:show_form, false)
         |> put_flash(:info, "Contact field added.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to save contact field.")}
    end
  end

  def handle_event("edit", %{"id" => id}, socket) do
    {:noreply, socket |> assign(:editing_id, String.to_integer(id)) |> assign(:show_form, false)}
  end

  def handle_event("update", %{"contact_field" => params}, socket) do
    field = Contacts.get_contact_field!(socket.assigns.account_id, socket.assigns.editing_id)

    case Contacts.update_contact_field(field, params) do
      {:ok, _} ->
        fields = Contacts.list_contact_fields(socket.assigns.contact_id)

        {:noreply,
         socket
         |> assign(:fields, fields)
         |> assign(:editing_id, nil)
         |> put_flash(:info, "Contact field updated.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update contact field.")}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    field = Contacts.get_contact_field!(socket.assigns.account_id, String.to_integer(id))
    {:ok, _} = Contacts.delete_contact_field(field)
    fields = Contacts.list_contact_fields(socket.assigns.contact_id)

    {:noreply,
     socket
     |> assign(:fields, fields)
     |> put_flash(:info, "Contact field deleted.")}
  end

  defp field_link(field) do
    case field.contact_field_type.protocol do
      proto when proto in ["mailto", "mailto:"] -> "mailto:#{field.value}"
      proto when proto in ["tel", "tel:"] -> "tel:#{field.value}"
      proto when proto in ["https", "https://"] -> web_link("https", field.value)
      proto when proto in ["http", "http://"] -> web_link("http", field.value)
      proto when is_binary(proto) and proto != "" -> "#{proto}#{field.value}"
      _ -> nil
    end
  end

  defp web_link(protocol, value) do
    if String.starts_with?(value, ["http://", "https://"]),
      do: value,
      else: "#{protocol}://#{value}"
  end

  defp display_value(field, phone_format) do
    case field.contact_field_type.protocol do
      proto when proto in ["tel", "tel:"] ->
        PhoneFormatter.format(field.value, phone_format)

      _ ->
        field.value
    end
  end

  defp field_icon(field) do
    case field.contact_field_type.icon do
      "envelope" -> "hero-envelope"
      "phone" -> "hero-phone"
      "globe" -> "hero-globe-alt"
      "link" -> "hero-link"
      _ -> "hero-information-circle"
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <div class="flex items-center justify-between mb-2">
        <span class="font-semibold text-xs text-[var(--color-text-primary)]">Contact</span>
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
          <.form for={%{}} phx-submit="save" phx-target={@myself}>
            <div class="space-y-2">
              <div>
                <label class="block mb-1">
                  <span class="text-xs font-medium text-[var(--color-text-secondary)]">Type</span>
                </label>
                <select
                  name="contact_field[contact_field_type_id]"
                  class="w-full rounded-[var(--radius-md)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] px-2.5 py-1.5 text-sm text-[var(--color-text-primary)] placeholder:text-[var(--color-text-disabled)] focus:border-[var(--color-border-focus)] focus:outline-none focus:ring-2 focus:ring-[var(--color-border-focus)]/20 transition-colors duration-150"
                  required
                >
                  <option value="">Select type...</option>
                  <%= for type <- @field_types do %>
                    <option value={type.id}>{type.name}</option>
                  <% end %>
                </select>
              </div>
              <div>
                <label class="block mb-1">
                  <span class="text-xs font-medium text-[var(--color-text-secondary)]">Value</span>
                </label>
                <input
                  type="text"
                  name="contact_field[value]"
                  class="w-full rounded-[var(--radius-md)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] px-2.5 py-1.5 text-sm text-[var(--color-text-primary)] placeholder:text-[var(--color-text-disabled)] focus:border-[var(--color-border-focus)] focus:outline-none focus:ring-2 focus:ring-[var(--color-border-focus)]/20 transition-colors duration-150"
                  required
                />
              </div>
              <div>
                <label class="block mb-1">
                  <span class="text-xs font-medium text-[var(--color-text-secondary)]">
                    Label (optional)
                  </span>
                </label>
                <input
                  type="text"
                  name="contact_field[label]"
                  class="w-full rounded-[var(--radius-md)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] px-2.5 py-1.5 text-sm text-[var(--color-text-primary)] placeholder:text-[var(--color-text-disabled)] focus:border-[var(--color-border-focus)] focus:outline-none focus:ring-2 focus:ring-[var(--color-border-focus)]/20 transition-colors duration-150"
                  placeholder="e.g. Work, Personal"
                />
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

      <%= if @fields == [] and not @show_form do %>
        <p class="text-xs text-[var(--color-text-disabled)]">No contact info added.</p>
      <% end %>

      <div class="space-y-2">
        <%= for field <- @fields do %>
          <%= if @editing_id == field.id do %>
            <.form for={%{}} phx-submit="update" phx-target={@myself}>
              <div class="space-y-2">
                <div>
                  <select
                    name="contact_field[contact_field_type_id]"
                    class="w-full rounded-[var(--radius-md)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] px-2.5 py-1.5 text-sm text-[var(--color-text-primary)] placeholder:text-[var(--color-text-disabled)] focus:border-[var(--color-border-focus)] focus:outline-none focus:ring-2 focus:ring-[var(--color-border-focus)]/20 transition-colors duration-150"
                    required
                  >
                    <%= for type <- @field_types do %>
                      <option value={type.id} selected={type.id == field.contact_field_type_id}>
                        {type.name}
                      </option>
                    <% end %>
                  </select>
                </div>
                <div>
                  <input
                    type="text"
                    name="contact_field[value]"
                    class="w-full rounded-[var(--radius-md)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] px-2.5 py-1.5 text-sm text-[var(--color-text-primary)] placeholder:text-[var(--color-text-disabled)] focus:border-[var(--color-border-focus)] focus:outline-none focus:ring-2 focus:ring-[var(--color-border-focus)]/20 transition-colors duration-150"
                    required
                    value={field.value}
                  />
                </div>
                <div>
                  <input
                    type="text"
                    name="contact_field[label]"
                    class="w-full rounded-[var(--radius-md)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] px-2.5 py-1.5 text-sm text-[var(--color-text-primary)] placeholder:text-[var(--color-text-disabled)] focus:border-[var(--color-border-focus)] focus:outline-none focus:ring-2 focus:ring-[var(--color-border-focus)]/20 transition-colors duration-150"
                    value={field.label}
                  />
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
          <% else %>
            <div class="group flex items-center gap-2 py-1.5 text-sm">
              <span class="text-[var(--color-text-tertiary)] w-4 text-center shrink-0">
                <.icon name={field_icon(field)} class="size-4" />
              </span>
              <span class="flex-1 min-w-0 truncate">
                <%= if link = field_link(field) do %>
                  <a href={link} class="text-[var(--color-accent)] hover:underline">
                    {display_value(field, @phone_format)}
                  </a>
                <% else %>
                  {display_value(field, @phone_format)}
                <% end %>
              </span>
              <span :if={field.label} class="text-[10px] text-[var(--color-text-disabled)] shrink-0">
                {field.label}
              </span>
              <span :if={!field.label} class="text-[10px] text-[var(--color-text-disabled)] shrink-0">
                {field.contact_field_type.name}
              </span>
              <%= if @can_edit do %>
                <div class="opacity-0 group-hover:opacity-100 flex gap-1.5 text-[10px] shrink-0 transition-opacity">
                  <button
                    phx-click="edit"
                    phx-value-id={field.id}
                    phx-target={@myself}
                    class="text-[var(--color-accent)] cursor-pointer"
                  >
                    Edit
                  </button>
                  <button
                    phx-click="delete"
                    phx-value-id={field.id}
                    phx-target={@myself}
                    data-confirm="Delete this field?"
                    class="text-[var(--color-error)] cursor-pointer"
                  >
                    Del
                  </button>
                </div>
              <% end %>
            </div>
          <% end %>
        <% end %>
      </div>
    </div>
    """
  end
end
