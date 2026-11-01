defmodule KithWeb.ContactLive.NotesListComponent do
  use KithWeb, :live_component

  alias Kith.Contacts

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:notes, [])
     |> assign(:editing_note_id, nil)
     |> assign(:show_form, false)}
  end

  @impl true
  def update(assigns, socket) do
    notes = Contacts.list_notes(assigns.contact_id, assigns.current_user_id)

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:notes, notes)
     |> assign_new(:changeset, fn -> Contacts.Note.changeset(%Contacts.Note{}, %{}) end)}
  end

  @impl true
  def handle_event("show-form", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_form, true)
     |> assign(:editing_note_id, nil)
     |> assign(:changeset, Contacts.Note.changeset(%Contacts.Note{}, %{}))}
  end

  def handle_event("cancel-form", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_form, false)
     |> assign(:editing_note_id, nil)}
  end

  def handle_event("save-note", %{"note" => note_params}, socket) do
    contact = Contacts.get_contact!(socket.assigns.account_id, socket.assigns.contact_id)

    case Contacts.create_note(contact, socket.assigns.current_user_id, note_params) do
      {:ok, _note} ->
        notes = Contacts.list_notes(socket.assigns.contact_id, socket.assigns.current_user_id)

        {:noreply,
         socket
         |> assign(:notes, notes)
         |> assign(:show_form, false)
         |> put_flash(:info, "Note added.")}

      {:error, changeset} ->
        {:noreply, assign(socket, :changeset, changeset)}
    end
  end

  def handle_event("edit-note", %{"id" => id}, socket) do
    note =
      Contacts.get_note!(
        socket.assigns.account_id,
        String.to_integer(id),
        socket.assigns.current_user_id
      )

    changeset = Contacts.Note.changeset(note, %{})

    {:noreply,
     socket
     |> assign(:editing_note_id, note.id)
     |> assign(:show_form, false)
     |> assign(:changeset, changeset)}
  end

  def handle_event("update-note", %{"note" => note_params}, socket) do
    note =
      Contacts.get_note!(
        socket.assigns.account_id,
        socket.assigns.editing_note_id,
        socket.assigns.current_user_id
      )

    case Contacts.update_note(note, note_params) do
      {:ok, _note} ->
        notes = Contacts.list_notes(socket.assigns.contact_id, socket.assigns.current_user_id)

        {:noreply,
         socket
         |> assign(:notes, notes)
         |> assign(:editing_note_id, nil)
         |> put_flash(:info, "Note updated.")}

      {:error, changeset} ->
        {:noreply, assign(socket, :changeset, changeset)}
    end
  end

  def handle_event("toggle-favorite", %{"id" => id}, socket) do
    note =
      Contacts.get_note!(
        socket.assigns.account_id,
        String.to_integer(id),
        socket.assigns.current_user_id
      )

    {:ok, _} = Contacts.toggle_note_favorite(note)
    notes = Contacts.list_notes(socket.assigns.contact_id, socket.assigns.current_user_id)
    {:noreply, assign(socket, :notes, notes)}
  end

  def handle_event("delete-note", %{"id" => id}, socket) do
    note =
      Contacts.get_note!(
        socket.assigns.account_id,
        String.to_integer(id),
        socket.assigns.current_user_id
      )

    {:ok, _} = Contacts.delete_note(note)
    notes = Contacts.list_notes(socket.assigns.contact_id, socket.assigns.current_user_id)

    {:noreply,
     socket
     |> assign(:notes, notes)
     |> put_flash(:info, "Note deleted.")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <div class="flex items-center justify-between mb-4">
        <h2 class="text-lg font-semibold">Notes</h2>
        <%= if @can_edit do %>
          <button
            id={"add-note-#{@contact_id}"}
            phx-click="show-form"
            phx-target={@myself}
            class="inline-flex items-center gap-1.5 rounded-[var(--radius-md)] bg-[var(--color-accent)] text-[var(--color-accent-foreground)] px-3 py-1.5 text-xs font-medium hover:bg-[var(--color-accent-hover)] transition-colors cursor-pointer"
          >
            <.icon name="hero-plus" class="size-4" /> Add Note
          </button>
        <% end %>
      </div>

      <%!-- Add note form --%>
      <%= if @show_form do %>
        <div class="rounded-[var(--radius-lg)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] shadow-sm mb-4">
          <div class="p-4">
            <.form for={%{}} phx-submit="save-note" phx-target={@myself}>
              <div id={"trix-new-note-#{@contact_id}"} phx-hook="TrixEditor" data-input="note[body]">
                <input type="hidden" name="note[body]" value="" />
                <trix-editor class="trix-content min-h-[100px] prose prose-sm max-w-none border rounded-[var(--radius-lg)] p-2 bg-[var(--color-surface-elevated)]">
                </trix-editor>
              </div>
              <div class="mt-2">
                <label class="flex cursor-pointer justify-start gap-2">
                  <input
                    type="checkbox"
                    name="note[is_private]"
                    value="true"
                    class="size-4 rounded-[var(--radius-sm)] border border-[var(--color-border)] accent-[var(--color-accent)] cursor-pointer"
                  />
                  <span class="text-sm font-medium text-[var(--color-text-primary)] flex items-center gap-1">
                    <.icon name="hero-lock-closed" class="size-4" /> Private (only visible to you)
                  </span>
                </label>
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
        </div>
      <% end %>

      <%!-- Notes list --%>
      <%= if @notes == [] and not @show_form do %>
        <KithUI.empty_state
          size={:compact}
          icon="hero-document-text"
          title="No notes yet"
          message="Jot down something meaningful about this person."
        >
          <:actions :if={@can_edit}>
            <button
              phx-click="show-form"
              phx-target={@myself}
              class="inline-flex items-center gap-1.5 rounded-[var(--radius-md)] bg-[var(--color-accent)] text-[var(--color-accent-foreground)] px-3 py-1.5 text-xs font-medium hover:bg-[var(--color-accent-hover)] transition-colors cursor-pointer"
            >
              Add Note
            </button>
          </:actions>
        </KithUI.empty_state>
      <% end %>

      <div class="space-y-3">
        <%= for note <- @notes do %>
          <div class="rounded-[var(--radius-lg)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] shadow-sm">
            <div class="p-4">
              <%= if @editing_note_id == note.id do %>
                <%!-- Inline edit form --%>
                <.form for={%{}} phx-submit="update-note" phx-target={@myself}>
                  <div id={"trix-edit-note-#{note.id}"} phx-hook="TrixEditor" data-input="note[body]">
                    <input type="hidden" name="note[body]" value={note.body} />
                    <trix-editor class="trix-content min-h-[100px] prose prose-sm max-w-none border rounded-[var(--radius-lg)] p-2 bg-[var(--color-surface-elevated)]">
                    </trix-editor>
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
                <%!-- Note display --%>
                <div class="flex items-start justify-between">
                  <div class="prose prose-sm max-w-none flex-1">
                    {Kith.RichText.render(note.body)}
                  </div>
                  <div class="flex items-center gap-1 ms-2 shrink-0">
                    <%= if note.is_private do %>
                      <UI.tooltip text="Private note">
                        <.icon name="hero-lock-closed" class="size-4 text-[var(--color-warning)]" />
                      </UI.tooltip>
                    <% end %>
                    <button
                      phx-click="toggle-favorite"
                      phx-value-id={note.id}
                      phx-target={@myself}
                      class="inline-flex items-center gap-1.5 rounded-[var(--radius-md)] px-2.5 py-1.5 text-xs font-medium text-[var(--color-text-secondary)] hover:bg-[var(--color-surface-sunken)] hover:text-[var(--color-text-primary)] transition-colors cursor-pointer"
                    >
                      <.icon
                        name={if note.favorite, do: "hero-star-solid", else: "hero-star"}
                        class={["size-4", note.favorite && "text-[var(--color-warning)]"]}
                      />
                    </button>
                  </div>
                </div>
                <div class="flex items-center justify-between mt-2 text-xs text-[var(--color-text-tertiary)]">
                  <span><.datetime_display datetime={note.inserted_at} /></span>
                  <%= if @can_edit do %>
                    <div class="flex gap-2">
                      <button
                        phx-click="edit-note"
                        phx-value-id={note.id}
                        phx-target={@myself}
                        class="text-[var(--color-accent)] hover:text-[var(--color-accent-hover)] transition-colors"
                      >
                        Edit
                      </button>
                      <button
                        phx-click="delete-note"
                        phx-value-id={note.id}
                        phx-target={@myself}
                        data-confirm="Delete this note? This cannot be undone."
                        class="text-[var(--color-error)] hover:text-[var(--color-error)] transition-colors"
                      >
                        Delete
                      </button>
                    </div>
                  <% end %>
                </div>
              <% end %>
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end
end
