defmodule KithWeb.ContactLive.PhotosGalleryComponent do
  use KithWeb, :live_component

  alias Kith.Contacts
  alias Kith.Storage

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:photos, [])
     |> allow_upload(:photo,
       accept: ~w(.jpg .jpeg .png .gif .webp),
       max_entries: 5,
       max_file_size: 10_000_000
     )}
  end

  @impl true
  def update(assigns, socket) do
    photos = Contacts.list_photos(assigns.contact.id)

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:photos, photos)}
  end

  @impl true
  def handle_event("validate", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("cancel-upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :photo, ref)}
  end

  def handle_event("upload", _params, socket) do
    contact = socket.assigns.contact

    uploaded_photos =
      consume_uploaded_entries(socket, :photo, fn %{path: path}, entry ->
        key = Storage.generate_key(contact.account_id, "photos", entry.client_name)
        {:ok, _} = Storage.upload(path, key)

        {:ok, photo} =
          Contacts.create_photo(contact, %{
            file_name: entry.client_name,
            storage_key: key,
            file_size: entry.client_size,
            content_type: entry.client_type
          })

        {:ok, photo}
      end)

    if uploaded_photos != [] do
      photos = Contacts.list_photos(contact.id)

      {:noreply,
       socket
       |> assign(:photos, photos)
       |> put_flash(:info, "#{length(uploaded_photos)} photo(s) uploaded.")}
    else
      {:noreply, socket}
    end
  end

  def handle_event("set-avatar", %{"id" => id}, socket) do
    contact = socket.assigns.contact
    photo = Contacts.get_photo!(contact.account_id, String.to_integer(id))
    send(self(), {:crop_avatar, photo.id})
    {:noreply, socket}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    contact = socket.assigns.contact
    photo = Contacts.get_photo!(contact.account_id, String.to_integer(id))
    {:ok, _} = Contacts.delete_photo(photo)
    photos = Contacts.list_photos(contact.id)

    # Refresh contact in case avatar was cleared
    updated_contact = Contacts.get_contact!(contact.account_id, contact.id)
    send(self(), {:avatar_updated, updated_contact})

    {:noreply,
     socket
     |> assign(:contact, updated_contact)
     |> assign(:photos, photos)
     |> put_flash(:info, "Photo deleted.")}
  end

  defp photo_url(photo) do
    Storage.url(photo.storage_key)
  end

  defp avatar?(photo, contact) do
    Contacts.avatar_photo?(contact, photo)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <div class="flex items-center justify-between mb-4">
        <h2 class="text-lg font-semibold">Photos</h2>
      </div>

      <%!-- Upload form --%>
      <%= if @can_edit do %>
        <form
          id={"photo-upload-#{@contact.id}"}
          phx-submit="upload"
          phx-change="validate"
          phx-target={@myself}
          class="mb-4"
        >
          <div class="flex items-center gap-3">
            <.live_file_input
              upload={@uploads.photo}
              class="w-full rounded-[var(--radius-md)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] px-2.5 py-1.5 text-sm text-[var(--color-text-primary)] file:me-3 file:rounded-[var(--radius-md)] file:border-0 file:bg-[var(--color-surface-sunken)] file:px-3 file:py-1 file:text-sm file:font-medium file:text-[var(--color-text-primary)]"
            />
            <button
              type="submit"
              class="inline-flex items-center gap-1.5 rounded-[var(--radius-md)] bg-[var(--color-accent)] text-[var(--color-accent-foreground)] px-3 py-1.5 text-xs font-medium hover:bg-[var(--color-accent-hover)] transition-colors cursor-pointer"
              disabled={@uploads.photo.entries == []}
            >
              Upload
            </button>
          </div>
          <%= for entry <- @uploads.photo.entries do %>
            <div class="text-sm mt-1 flex items-center gap-2">
              <span>{entry.client_name}</span>
              <progress
                value={entry.progress}
                max="100"
                class="h-2 w-24 rounded-[var(--radius-full)] accent-[var(--color-accent)]"
              >
                {entry.progress}%
              </progress>
              <button
                type="button"
                phx-click="cancel-upload"
                phx-value-ref={entry.ref}
                phx-target={@myself}
                class="text-[var(--color-error)] text-xs"
              >
                &times;
              </button>
            </div>
            <%= for err <- upload_errors(@uploads.photo, entry) do %>
              <p class="text-[var(--color-error)] text-xs">{error_to_string(err)}</p>
            <% end %>
          <% end %>
        </form>
      <% end %>

      <%= if @photos == [] do %>
        <KithUI.empty_state
          size={:compact}
          icon="hero-photo"
          title="No photos yet"
          message="Upload photos to keep faces and memories close."
        />
      <% end %>

      <%!-- Photo grid with Alpine.js lightbox --%>
      <div
        x-data="lightbox"
        x-on:keydown.escape.window="close"
      >
        <div class="grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 gap-3">
          <%= for photo <- @photos do %>
            <div class="relative group">
              <img
                src={photo_url(photo)}
                alt={photo.file_name}
                class="w-full aspect-square object-cover rounded-[var(--radius-lg)] cursor-pointer"
                x-on:click={"show('#{photo_url(photo)}', '#{photo.file_name}')"}
              />
              <%= if avatar?(photo, @contact) do %>
                <span class="absolute top-1 start-1 inline-flex items-center rounded-[var(--radius-full)] px-2 py-0.5 text-xs font-medium bg-[var(--color-accent)] text-[var(--color-accent-foreground)]">
                  Avatar
                </span>
              <% end %>
              <%= if @can_edit do %>
                <div class="absolute top-1 end-1 opacity-0 group-hover:opacity-100 transition-opacity flex gap-1">
                  <%= unless avatar?(photo, @contact) do %>
                    <button
                      phx-click="set-avatar"
                      phx-value-id={photo.id}
                      phx-target={@myself}
                      class="inline-flex items-center justify-center size-6 rounded-full bg-[var(--color-surface-elevated)]/80 text-[var(--color-text-secondary)] hover:bg-[var(--color-surface-sunken)] transition-colors cursor-pointer"
                      title="Set as avatar"
                    >
                      <.icon name="hero-star" class="size-3" />
                    </button>
                  <% end %>
                  <button
                    phx-click="delete"
                    phx-value-id={photo.id}
                    phx-target={@myself}
                    data-confirm="Delete this photo?"
                    class="inline-flex items-center justify-center size-6 rounded-full bg-[var(--color-surface-elevated)]/80 text-[var(--color-error)] hover:bg-[var(--color-error-subtle)] transition-colors cursor-pointer"
                    title="Delete"
                  >
                    <.icon name="hero-trash" class="size-3" />
                  </button>
                </div>
              <% end %>
            </div>
          <% end %>
        </div>

        <%!-- Lightbox overlay --%>
        <div
          x-show="open"
          x-transition.opacity
          x-cloak
          class="fixed inset-0 z-50 flex items-center justify-center bg-black/80 p-4"
          x-on:click.self="close"
        >
          <div class="relative max-w-4xl max-h-[90vh]">
            <img
              x-bind:src="currentSrc"
              x-bind:alt="currentName"
              class="max-w-full max-h-[85vh] object-contain rounded-[var(--radius-lg)]"
            />
            <button
              x-on:click="close"
              class="absolute -top-3 -end-3 inline-flex items-center justify-center size-8 rounded-full bg-[var(--color-surface-elevated)] border border-[var(--color-border)] text-[var(--color-text-primary)] hover:bg-[var(--color-surface-sunken)] transition-colors cursor-pointer"
            >
              &times;
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp error_to_string(:too_large), do: "File too large (max 10MB)"
  defp error_to_string(:too_many_files), do: "Too many files (max 5)"
  defp error_to_string(:not_accepted), do: "Invalid file type"
  defp error_to_string(err), do: to_string(err)
end
