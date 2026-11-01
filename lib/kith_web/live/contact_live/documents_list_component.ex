defmodule KithWeb.ContactLive.DocumentsListComponent do
  use KithWeb, :live_component

  alias Kith.Contacts
  alias Kith.Storage

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:documents, [])
     |> allow_upload(:document,
       accept: :any,
       max_entries: 3,
       max_file_size: 50_000_000
     )}
  end

  @impl true
  def update(assigns, socket) do
    documents = Contacts.list_documents(assigns.contact_id)

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:documents, documents)}
  end

  @impl true
  def handle_event("validate", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("upload", _params, socket) do
    contact = Contacts.get_contact!(socket.assigns.account_id, socket.assigns.contact_id)

    results =
      consume_uploaded_entries(socket, :document, fn %{path: path}, entry ->
        {:ok, KithWeb.ContactUploads.save(contact, path, entry, :document)}
      end)

    uploaded = Enum.count(results, &match?({:ok, _}, &1))
    failed = Enum.any?(results, &match?({:error, _}, &1))

    socket =
      socket
      |> clear_flash(:error)
      |> assign(:documents, Contacts.list_documents(socket.assigns.contact_id))

    socket =
      if uploaded > 0,
        do: put_flash(socket, :info, "#{uploaded} document(s) uploaded."),
        else: socket

    socket =
      if failed,
        do: put_flash(socket, :error, "Some documents could not be uploaded. Please try again."),
        else: socket

    {:noreply, socket}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    doc = Contacts.get_document!(socket.assigns.account_id, String.to_integer(id))
    Storage.delete(doc.storage_key)
    {:ok, _} = Contacts.delete_document(doc)
    documents = Contacts.list_documents(socket.assigns.contact_id)

    {:noreply,
     socket
     |> assign(:documents, documents)
     |> put_flash(:info, "Document deleted.")}
  end

  defp format_size(nil), do: "—"
  defp format_size(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_size(bytes) when bytes < 1_048_576, do: "#{Float.round(bytes / 1024, 1)} KB"
  defp format_size(bytes), do: "#{Float.round(bytes / 1_048_576, 1)} MB"

  defp file_icon(nil), do: "hero-document"

  defp file_icon(content_type) do
    ct = content_type || ""
    file_icon_for_type(ct)
  end

  defp file_icon_for_type("image/" <> _), do: "hero-photo"

  defp file_icon_for_type(ct) do
    cond do
      String.contains?(ct, "pdf") -> "hero-document-text"
      String.contains?(ct, "spreadsheet") or String.contains?(ct, "csv") -> "hero-table-cells"
      true -> "hero-document"
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <p :if={@flash["error"]} role="alert">{@flash["error"]}</p>
      <div class="flex items-center justify-between mb-4">
        <h2 class="text-lg font-semibold">Documents</h2>
      </div>

      <%!-- Upload form --%>
      <%= if @can_edit do %>
        <form
          id={"doc-upload-#{@contact_id}"}
          phx-submit="upload"
          phx-change="validate"
          phx-target={@myself}
          class="mb-4"
        >
          <div class="flex items-center gap-3">
            <.live_file_input
              upload={@uploads.document}
              class="w-full rounded-[var(--radius-md)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] px-2.5 py-1.5 text-sm text-[var(--color-text-primary)] placeholder:text-[var(--color-text-disabled)] focus:border-[var(--color-border-focus)] focus:outline-none focus:ring-2 focus:ring-[var(--color-border-focus)]/20 transition-colors duration-150"
            />
            <button
              type="submit"
              class="inline-flex items-center gap-1.5 rounded-[var(--radius-md)] bg-[var(--color-accent)] text-[var(--color-accent-foreground)] px-3 py-1.5 text-xs font-medium hover:bg-[var(--color-accent-hover)] transition-colors cursor-pointer"
              disabled={@uploads.document.entries == []}
            >
              Upload
            </button>
          </div>
          <%= for entry <- @uploads.document.entries do %>
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
            <%= for err <- upload_errors(@uploads.document, entry) do %>
              <p class="text-[var(--color-error)] text-xs">{error_to_string(err)}</p>
            <% end %>
          <% end %>
        </form>
      <% end %>

      <%= if @documents == [] do %>
        <KithUI.empty_state
          size={:compact}
          icon="hero-document"
          title="No documents yet"
          message="Attach files like letters, receipts, or important records."
        />
      <% end %>

      <div class="space-y-2">
        <%= for doc <- @documents do %>
          <div class="flex items-center justify-between py-2 px-3 rounded-[var(--radius-lg)] hover:bg-[var(--color-surface-sunken)]/50">
            <div class="flex items-center gap-3">
              <.icon
                name={file_icon(doc.content_type)}
                class="size-5 text-[var(--color-text-disabled)]"
              />
              <div>
                <a
                  href={Storage.url(doc.storage_key)}
                  target="_blank"
                  class="text-[var(--color-accent)] hover:text-[var(--color-accent-hover)] transition-colors text-sm font-medium"
                >
                  {doc.file_name}
                </a>
                <div class="text-xs text-[var(--color-text-tertiary)]">
                  {format_size(doc.file_size)} &middot; {Calendar.strftime(
                    doc.inserted_at,
                    "%b %d, %Y"
                  )}
                </div>
              </div>
            </div>
            <%= if @can_edit do %>
              <button
                phx-click="delete"
                phx-value-id={doc.id}
                phx-target={@myself}
                data-confirm="Delete this document?"
                class="text-[var(--color-error)] hover:text-[var(--color-error)] transition-colors text-xs"
              >
                Delete
              </button>
            <% end %>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp error_to_string(:too_large), do: "File too large (max 50MB)"
  defp error_to_string(:too_many_files), do: "Too many files (max 3)"
  defp error_to_string(:not_accepted), do: "Invalid file type"
  defp error_to_string(err), do: to_string(err)
end
