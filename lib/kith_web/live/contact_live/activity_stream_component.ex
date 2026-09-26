defmodule KithWeb.ContactLive.ActivityStreamComponent do
  @moduledoc """
  Unified activity timeline component that merges all entry types
  (notes, calls, life events, activities, tasks, gifts, conversations, photos)
  into a single chronological stream with multi-select filtering.
  """
  use KithWeb, :live_component

  alias Kith.Activities
  alias Kith.Contacts
  alias Kith.Contacts.ActivityStream
  alias Kith.Conversations
  alias Kith.Gifts
  alias Kith.Storage
  alias Kith.Tasks
  alias KithWeb.ContactLive.PhotoThumbComponent

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:entries, [])
     |> assign(:active_filters, MapSet.new())
     |> assign(:all_types, ActivityStream.all_types())
     |> assign(:modal_type, nil)
     |> assign(:modal_entry_id, nil)
     |> assign(:modal_error, nil)
     |> allow_upload(:photo,
       accept: ~w(.jpg .jpeg .png .gif .webp),
       max_entries: 5,
       max_file_size: 10_000_000
     )}
  end

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)
    {:ok, load_entries(socket)}
  end

  # --- Filter events ---

  @impl true
  def handle_event("filter-toggle", %{"type" => type_str}, socket) do
    type = String.to_existing_atom(type_str)
    filters = socket.assigns.active_filters

    filters =
      if MapSet.member?(filters, type),
        do: MapSet.delete(filters, type),
        else: MapSet.put(filters, type)

    {:noreply, socket |> assign(:active_filters, filters) |> load_entries()}
  end

  def handle_event("filter-clear", _params, socket) do
    {:noreply, socket |> assign(:active_filters, MapSet.new()) |> load_entries()}
  end

  # --- Modal events ---

  def handle_event("open-entry-modal", %{"type" => type_str}, socket) do
    type = String.to_existing_atom(type_str)

    {:noreply,
     socket
     |> assign(:modal_type, type)
     |> assign(:modal_entry_id, nil)
     |> assign(:modal_error, nil)}
  end

  def handle_event("edit-entry", %{"type" => type_str, "id" => id_str}, socket) do
    type = String.to_existing_atom(type_str)
    id = String.to_integer(id_str)

    {:noreply,
     socket
     |> assign(:modal_type, type)
     |> assign(:modal_entry_id, id)
     |> assign(:modal_error, nil)}
  end

  def handle_event("close-modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:modal_type, nil)
     |> assign(:modal_entry_id, nil)
     |> assign(:modal_error, nil)}
  end

  def handle_event("save-entry", params, socket) do
    %{modal_type: type, modal_entry_id: entry_id} = socket.assigns

    result =
      if entry_id,
        do: update_entry(type, entry_id, params, socket.assigns),
        else: create_entry(type, params, socket.assigns)

    case result do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:modal_type, nil)
         |> assign(:modal_entry_id, nil)
         |> assign(:modal_error, nil)
         |> load_entries()}

      {:error, message} ->
        {:noreply, assign(socket, :modal_error, message)}
    end
  end

  def handle_event("delete-entry", %{"type" => type_str, "id" => id_str}, socket) do
    type = String.to_existing_atom(type_str)
    id = String.to_integer(id_str)

    case delete_entry(type, id, socket.assigns) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:modal_type, nil)
         |> assign(:modal_entry_id, nil)
         |> load_entries()}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  # --- Photo upload events ---

  def handle_event("validate-photo", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("upload-photo", _params, socket) do
    contact_id = socket.assigns.contact_id

    uploaded_photos =
      consume_uploaded_entries(socket, :photo, fn %{path: path}, entry ->
        key = "contacts/#{contact_id}/photos/#{entry.uuid}-#{entry.client_name}"
        {:ok, _} = Storage.upload(path, key)

        {:ok, photo} =
          Contacts.create_photo(
            Contacts.get_contact!(socket.assigns.account_id, contact_id),
            %{
              file_name: entry.client_name,
              storage_key: key,
              file_size: entry.client_size,
              content_type: entry.client_type
            }
          )

        {:ok, photo}
      end)

    if uploaded_photos != [] do
      {:noreply,
       socket
       |> assign(:modal_type, nil)
       |> load_entries()
       |> put_flash(:info, "#{length(uploaded_photos)} photo(s) uploaded.")}
    else
      {:noreply, socket}
    end
  end

  def handle_event("cancel-photo-upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :photo, ref)}
  end

  # --- CRUD helpers ---

  defp create_entry(:note, %{"entry" => params}, assigns) do
    contact = Contacts.get_contact!(assigns.account_id, assigns.contact_id)

    Contacts.create_note(contact, assigns.current_user_id, params)
    |> normalize_result()
  end

  defp create_entry(:call, %{"entry" => params}, assigns) do
    contact = Contacts.get_contact!(assigns.account_id, assigns.contact_id)
    Activities.create_call(contact, params) |> normalize_result()
  end

  defp create_entry(:life_event, %{"entry" => params}, assigns) do
    contact = Contacts.get_contact!(assigns.account_id, assigns.contact_id)
    Activities.create_life_event(contact, params) |> normalize_result()
  end

  defp create_entry(:task, %{"entry" => params}, assigns) do
    params = Map.put(params, "contact_id", assigns.contact_id)
    Tasks.create_task(assigns.account_id, assigns.current_user_id, params) |> normalize_result()
  end

  defp create_entry(:gift, %{"entry" => params}, assigns) do
    params = Map.put(params, "contact_id", assigns.contact_id)
    Gifts.create_gift(assigns.account_id, assigns.current_user_id, params) |> normalize_result()
  end

  defp create_entry(:conversation, %{"entry" => params}, assigns) do
    params = Map.put(params, "contact_id", assigns.contact_id)

    Conversations.create_conversation(assigns.account_id, assigns.current_user_id, params)
    |> normalize_result()
  end

  defp create_entry(:activity, %{"entry" => params}, assigns) do
    Activities.create_activity(assigns.account_id, params, [assigns.contact_id])
    |> normalize_result()
  end

  defp create_entry(_, _, _), do: {:error, "Unsupported type"}

  defp update_entry(:note, id, %{"entry" => params}, assigns) do
    note = Contacts.get_note!(assigns.account_id, id, assigns.current_user_id)
    Contacts.update_note(note, params) |> normalize_result()
  end

  defp update_entry(:call, id, %{"entry" => params}, assigns) do
    call = Activities.get_call!(assigns.account_id, id)
    Activities.update_call(call, params) |> normalize_result()
  end

  defp update_entry(:task, id, %{"entry" => params}, assigns) do
    task = Tasks.get_task!(assigns.account_id, id)
    Tasks.update_task(task, params) |> normalize_result()
  end

  defp update_entry(:gift, id, %{"entry" => params}, assigns) do
    gift = Gifts.get_gift!(assigns.account_id, id)
    Gifts.update_gift(gift, params) |> normalize_result()
  end

  defp update_entry(_, _, _, _), do: {:error, "Update not supported for this type"}

  defp delete_entry(:note, id, assigns) do
    note = Contacts.get_note!(assigns.account_id, id, assigns.current_user_id)
    Contacts.delete_note(note) |> normalize_result()
  end

  defp delete_entry(:call, id, assigns) do
    call = Activities.get_call!(assigns.account_id, id)
    Activities.delete_call(call) |> normalize_result()
  end

  defp delete_entry(:task, id, assigns) do
    task = Tasks.get_task!(assigns.account_id, id)
    Tasks.delete_task(task) |> normalize_result()
  end

  defp delete_entry(:gift, id, assigns) do
    gift = Gifts.get_gift!(assigns.account_id, id)
    Gifts.delete_gift(gift) |> normalize_result()
  end

  defp delete_entry(_, _, _), do: {:error, "Delete not supported for this type"}

  defp normalize_result({:ok, result}), do: {:ok, result}
  defp normalize_result({:error, %Ecto.Changeset{} = cs}), do: {:error, changeset_error(cs)}
  defp normalize_result({:error, _, %Ecto.Changeset{} = cs, _}), do: {:error, changeset_error(cs)}
  defp normalize_result({:error, msg}) when is_binary(msg), do: {:error, msg}
  defp normalize_result({:error, _}), do: {:error, "Something went wrong"}

  defp changeset_error(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Enum.map_join(", ", fn {field, errors} -> "#{field}: #{Enum.join(errors, ", ")}" end)
  end

  # --- Data loading ---

  defp load_entries(socket) do
    %{account_id: account_id, contact_id: contact_id, current_user_id: current_user_id} =
      socket.assigns

    filters = socket.assigns.active_filters
    opts = [current_user_id: current_user_id, limit: 50]

    opts =
      if MapSet.size(filters) > 0,
        do: Keyword.put(opts, :types, MapSet.to_list(filters)),
        else: opts

    entries = ActivityStream.list_activity(account_id, contact_id, opts)
    assign(socket, :entries, entries)
  end

  defp photos_only?(filters) do
    MapSet.size(filters) == 1 and MapSet.member?(filters, :photo)
  end

  # --- Render ---

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <%!-- Stream Header --%>
      <div class="bg-[var(--color-surface-elevated)] rounded-xl p-3.5 shadow-[var(--shadow-card)] border border-[var(--color-border-subtle)] mb-3.5">
        <div class="flex justify-between items-center">
          <span class="font-semibold text-sm text-[var(--color-text-primary)]">Activity</span>
          <div class="flex gap-1.5">
            <.filter_dropdown
              active_filters={@active_filters}
              all_types={@all_types}
              target={@myself}
            />
            <button
              phx-click="open-entry-modal"
              phx-value-type="note"
              phx-target={@myself}
              class="inline-flex items-center gap-1 rounded-lg border border-[var(--color-border)] px-3 py-1.5 text-xs text-[var(--color-text-secondary)] hover:bg-[var(--color-surface-elevated)] transition-colors cursor-pointer"
            >
              + Note
            </button>
            <button
              phx-click="open-entry-modal"
              phx-value-type="call"
              phx-target={@myself}
              class="inline-flex items-center gap-1 rounded-lg border border-[var(--color-border)] px-3 py-1.5 text-xs text-[var(--color-text-secondary)] hover:bg-[var(--color-surface-elevated)] transition-colors cursor-pointer"
            >
              + Call
            </button>
            <button
              phx-click="open-entry-modal"
              phx-value-type="life_event"
              phx-target={@myself}
              class="inline-flex items-center gap-1 rounded-lg border border-[var(--color-border)] px-3 py-1.5 text-xs text-[var(--color-text-secondary)] hover:bg-[var(--color-surface-elevated)] transition-colors cursor-pointer"
            >
              + Event
            </button>
            <%!-- More types overflow --%>
            <div x-data="{ open: false }" class="relative">
              <button
                @click="open = !open"
                class="inline-flex items-center justify-center size-8 rounded-lg border border-[var(--color-border)] text-[var(--color-text-secondary)] hover:bg-[var(--color-surface-elevated)] transition-colors cursor-pointer"
              >
                <.icon name="hero-plus-mini" class="size-4" />
              </button>
              <div
                x-show="open"
                x-transition
                @click.outside="open = false"
                class="absolute end-0 top-full mt-1 z-10 w-40 rounded-lg bg-[var(--color-surface-overlay)] border border-[var(--color-border)] shadow-[var(--shadow-dropdown)] p-1"
              >
                <button
                  :for={type <- [:task, :gift, :conversation, :activity, :photo]}
                  phx-click="open-entry-modal"
                  phx-value-type={type}
                  phx-target={@myself}
                  @click="open = false"
                  class="flex w-full items-center gap-2 rounded-md px-2.5 py-1.5 text-xs text-[var(--color-text-primary)] hover:bg-[var(--color-surface)] transition-colors cursor-pointer"
                >
                  + {type_label(type)}
                </button>
              </div>
            </div>
          </div>
        </div>
        <div :if={MapSet.size(@active_filters) > 0} class="mt-2.5">
          <.filter_chips active_filters={@active_filters} target={@myself} />
        </div>
      </div>

      <%!-- Entry Modal --%>
      <.modal
        :if={@modal_type}
        id="entry-modal"
        show
        on_cancel={JS.push("close-modal", target: @myself)}
      >
        <.entry_modal_content
          type={@modal_type}
          entry_id={@modal_entry_id}
          error={@modal_error}
          myself={@myself}
          account_id={@account_id}
          contact_id={@contact_id}
          uploads={@uploads}
        />
      </.modal>

      <%!-- Photos Gallery Mode --%>
      <div
        :if={photos_only?(@active_filters) && length(@entries) > 0}
        class="grid grid-cols-3 sm:grid-cols-4 gap-2"
      >
        <div
          :for={entry <- @entries}
          class="aspect-square rounded-lg bg-[var(--color-surface)] border border-[var(--color-border-subtle)] overflow-hidden"
        >
          <.live_component
            module={PhotoThumbComponent}
            id={"photo-#{entry.id}"}
            variant={:tile}
            storage_key={entry.record.storage_key}
            alt={entry.title}
            pending_sync={Contacts.Photo.pending_sync?(entry.record)}
          />
        </div>
      </div>

      <%!-- Timeline Mode --%>
      <div :if={!photos_only?(@active_filters) || length(@entries) == 0} class="relative ps-[22px]">
        <div class="absolute start-2 top-0 bottom-0 w-0.5 bg-[var(--color-border)] rounded-full" />

        <div :if={length(@entries) == 0} class="py-12 text-center">
          <.icon name="hero-clock" class="size-8 text-[var(--color-text-disabled)] mx-auto mb-2" />
          <p class="text-sm text-[var(--color-text-tertiary)]">No activity yet</p>
          <p class="text-xs text-[var(--color-text-disabled)] mt-1">
            Add a note, log a call, or record an event to get started.
          </p>
        </div>

        <div
          :for={entry <- @entries}
          class="bg-[var(--color-surface-elevated)] rounded-xl p-4 mb-3 shadow-[var(--shadow-card)] border border-[var(--color-border-subtle)] relative"
        >
          <.timeline_dot type={entry.type} />

          <div class="flex justify-between items-center mb-1.5">
            <div class="flex items-center gap-2">
              <span class="text-[11px] text-[var(--color-text-tertiary)]">
                <.relative_time_or_date datetime={entry.occurred_at} />
              </span>
              <.type_badge type={entry.type} />
              <span
                :if={entry.type == :call && entry.record.duration_mins}
                class="text-[11px] text-[var(--color-text-tertiary)]"
              >
                {duration_text(entry.record.duration_mins)}
              </span>
              <span
                :if={entry.type == :conversation && entry.record.platform}
                class="text-[11px] text-[var(--color-text-tertiary)]"
              >
                {entry.record.platform}
              </span>
            </div>
            <%!-- Entry overflow menu --%>
            <div x-data="{ open: false }" class="relative">
              <button
                @click="open = !open"
                class="text-[var(--color-text-disabled)] hover:text-[var(--color-text-secondary)] text-base leading-none cursor-pointer"
              >
                &hellip;
              </button>
              <div
                x-show="open"
                x-transition
                @click.outside="open = false"
                class="absolute end-0 top-full mt-1 z-10 w-32 rounded-lg bg-[var(--color-surface-overlay)] border border-[var(--color-border)] shadow-[var(--shadow-dropdown)] p-1"
              >
                <button
                  phx-click="edit-entry"
                  phx-value-type={entry.type}
                  phx-value-id={entry.id}
                  phx-target={@myself}
                  @click="open = false"
                  class="flex w-full items-center gap-2 rounded-md px-2.5 py-1.5 text-xs text-[var(--color-text-primary)] hover:bg-[var(--color-surface)] transition-colors cursor-pointer"
                >
                  <.icon name="hero-pencil-square-mini" class="size-3.5" /> Edit
                </button>
                <button
                  phx-click="delete-entry"
                  phx-value-type={entry.type}
                  phx-value-id={entry.id}
                  phx-target={@myself}
                  @click="open = false"
                  data-confirm="Delete this entry? This cannot be undone."
                  class="flex w-full items-center gap-2 rounded-md px-2.5 py-1.5 text-xs text-[var(--color-error)] hover:bg-[var(--color-error-subtle)] transition-colors cursor-pointer"
                >
                  <.icon name="hero-trash-mini" class="size-3.5" /> Delete
                </button>
              </div>
            </div>
          </div>

          <div
            :if={entry.type != :note}
            class="font-semibold text-[13px] text-[var(--color-text-primary)] mb-1"
          >
            <span
              :if={entry.type == :task && entry.record.status == "completed"}
              class="line-through text-[var(--color-text-tertiary)]"
            >
              {entry.title}
            </span>
            <span :if={entry.type != :task || entry.record.status != "completed"}>
              {entry.title}
            </span>
          </div>

          <div
            :if={entry.body}
            class="text-xs text-[var(--color-text-secondary)] leading-relaxed line-clamp-3"
          >
            {if entry.type == :note, do: strip_html(entry.body), else: entry.body}
          </div>

          <.live_component
            :if={entry.type == :photo}
            module={PhotoThumbComponent}
            id={"photo-#{entry.id}"}
            variant={:timeline}
            storage_key={entry.record.storage_key}
            alt={entry.title}
            pending_sync={Contacts.Photo.pending_sync?(entry.record)}
          />
        </div>
      </div>
    </div>
    """
  end

  # --- Modal form content per type ---

  defp entry_modal_content(%{type: :note} = assigns) do
    ~H"""
    <div>
      <h3 class="text-lg font-semibold mb-4">{if @entry_id, do: "Edit Note", else: "New Note"}</h3>
      <.entry_error error={@error} />
      <.form for={%{}} phx-submit="save-entry" phx-target={@myself}>
        <div class="space-y-3">
          <div>
            <label class="block text-sm font-medium text-[var(--color-text-primary)] mb-1">
              Content
            </label>
            <textarea
              name="entry[body]"
              rows="5"
              class="w-full rounded-[var(--radius-md)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] px-3 py-2 text-sm focus:border-[var(--color-border-focus)] focus:outline-none focus:ring-2 focus:ring-[var(--color-border-focus)]/20"
              placeholder="Write a note..."
            />
          </div>
          <label class="flex items-center gap-2 cursor-pointer">
            <input
              type="checkbox"
              name="entry[is_private]"
              value="true"
              class="size-4 rounded border border-[var(--color-border)] accent-[var(--color-accent)]"
            />
            <span class="text-sm text-[var(--color-text-secondary)]">
              Private (only visible to you)
            </span>
          </label>
        </div>
        <.modal_actions myself={@myself} entry_id={@entry_id} type={:note} />
      </.form>
    </div>
    """
  end

  defp entry_modal_content(%{type: :call} = assigns) do
    ~H"""
    <div>
      <h3 class="text-lg font-semibold mb-4">{if @entry_id, do: "Edit Call", else: "Log Call"}</h3>
      <.entry_error error={@error} />
      <.form for={%{}} phx-submit="save-entry" phx-target={@myself}>
        <div class="space-y-3">
          <div>
            <label class="block text-sm font-medium text-[var(--color-text-primary)] mb-1">
              When
            </label>
            <input
              type="datetime-local"
              name="entry[occurred_at]"
              value={Calendar.strftime(DateTime.utc_now(), "%Y-%m-%dT%H:%M")}
              class="w-full rounded-[var(--radius-md)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] px-3 py-2 text-sm focus:border-[var(--color-border-focus)] focus:outline-none focus:ring-2 focus:ring-[var(--color-border-focus)]/20"
            />
          </div>
          <div>
            <label class="block text-sm font-medium text-[var(--color-text-primary)] mb-1">
              Duration (minutes)
            </label>
            <input
              type="number"
              name="entry[duration_mins]"
              min="0"
              placeholder="30"
              class="w-full rounded-[var(--radius-md)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] px-3 py-2 text-sm focus:border-[var(--color-border-focus)] focus:outline-none focus:ring-2 focus:ring-[var(--color-border-focus)]/20"
            />
          </div>
          <div>
            <label class="block text-sm font-medium text-[var(--color-text-primary)] mb-1">
              Notes
            </label>
            <textarea
              name="entry[notes]"
              rows="3"
              class="w-full rounded-[var(--radius-md)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] px-3 py-2 text-sm focus:border-[var(--color-border-focus)] focus:outline-none focus:ring-2 focus:ring-[var(--color-border-focus)]/20"
              placeholder="What did you talk about?"
            />
          </div>
        </div>
        <.modal_actions myself={@myself} entry_id={@entry_id} type={:call} />
      </.form>
    </div>
    """
  end

  defp entry_modal_content(%{type: :life_event} = assigns) do
    life_event_types = Kith.Repo.all(Kith.Contacts.LifeEventType)
    assigns = assign(assigns, :life_event_types, life_event_types)

    ~H"""
    <div>
      <h3 class="text-lg font-semibold mb-4">
        {if @entry_id, do: "Edit Life Event", else: "New Life Event"}
      </h3>
      <.entry_error error={@error} />
      <.form for={%{}} phx-submit="save-entry" phx-target={@myself}>
        <div class="space-y-3">
          <div>
            <label class="block text-sm font-medium text-[var(--color-text-primary)] mb-1">
              Type
            </label>
            <select
              name="entry[life_event_type_id]"
              class="w-full rounded-[var(--radius-md)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] px-3 py-2 text-sm focus:border-[var(--color-border-focus)] focus:outline-none focus:ring-2 focus:ring-[var(--color-border-focus)]/20"
            >
              <option value="">Select type...</option>
              <option :for={t <- @life_event_types} value={t.id}>{t.name}</option>
            </select>
          </div>
          <div>
            <label class="block text-sm font-medium text-[var(--color-text-primary)] mb-1">
              Date
            </label>
            <input
              type="date"
              name="entry[occurred_on]"
              value={Date.to_iso8601(Date.utc_today())}
              class="w-full rounded-[var(--radius-md)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] px-3 py-2 text-sm focus:border-[var(--color-border-focus)] focus:outline-none focus:ring-2 focus:ring-[var(--color-border-focus)]/20"
            />
          </div>
          <div>
            <label class="block text-sm font-medium text-[var(--color-text-primary)] mb-1">
              Notes
            </label>
            <textarea
              name="entry[note]"
              rows="3"
              class="w-full rounded-[var(--radius-md)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] px-3 py-2 text-sm focus:border-[var(--color-border-focus)] focus:outline-none focus:ring-2 focus:ring-[var(--color-border-focus)]/20"
              placeholder="Any details..."
            />
          </div>
        </div>
        <.modal_actions myself={@myself} entry_id={@entry_id} type={:life_event} />
      </.form>
    </div>
    """
  end

  defp entry_modal_content(%{type: :task} = assigns) do
    ~H"""
    <div>
      <h3 class="text-lg font-semibold mb-4">{if @entry_id, do: "Edit Task", else: "New Task"}</h3>
      <.entry_error error={@error} />
      <.form for={%{}} phx-submit="save-entry" phx-target={@myself}>
        <div class="space-y-3">
          <div>
            <label class="block text-sm font-medium text-[var(--color-text-primary)] mb-1">
              Title
            </label>
            <input
              type="text"
              name="entry[title]"
              class="w-full rounded-[var(--radius-md)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] px-3 py-2 text-sm focus:border-[var(--color-border-focus)] focus:outline-none focus:ring-2 focus:ring-[var(--color-border-focus)]/20"
              placeholder="What needs to be done?"
            />
          </div>
          <div>
            <label class="block text-sm font-medium text-[var(--color-text-primary)] mb-1">
              Description
            </label>
            <textarea
              name="entry[description]"
              rows="2"
              class="w-full rounded-[var(--radius-md)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] px-3 py-2 text-sm focus:border-[var(--color-border-focus)] focus:outline-none focus:ring-2 focus:ring-[var(--color-border-focus)]/20"
              placeholder="Optional details..."
            />
          </div>
          <div>
            <label class="block text-sm font-medium text-[var(--color-text-primary)] mb-1">
              Due date
            </label>
            <input
              type="date"
              name="entry[due_date]"
              class="w-full rounded-[var(--radius-md)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] px-3 py-2 text-sm focus:border-[var(--color-border-focus)] focus:outline-none focus:ring-2 focus:ring-[var(--color-border-focus)]/20"
            />
          </div>
        </div>
        <.modal_actions myself={@myself} entry_id={@entry_id} type={:task} />
      </.form>
    </div>
    """
  end

  defp entry_modal_content(%{type: :gift} = assigns) do
    ~H"""
    <div>
      <h3 class="text-lg font-semibold mb-4">{if @entry_id, do: "Edit Gift", else: "New Gift"}</h3>
      <.entry_error error={@error} />
      <.form for={%{}} phx-submit="save-entry" phx-target={@myself}>
        <div class="space-y-3">
          <div>
            <label class="block text-sm font-medium text-[var(--color-text-primary)] mb-1">
              Name
            </label>
            <input
              type="text"
              name="entry[name]"
              class="w-full rounded-[var(--radius-md)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] px-3 py-2 text-sm focus:border-[var(--color-border-focus)] focus:outline-none focus:ring-2 focus:ring-[var(--color-border-focus)]/20"
              placeholder="What was the gift?"
            />
          </div>
          <div>
            <label class="block text-sm font-medium text-[var(--color-text-primary)] mb-1">
              Direction
            </label>
            <select
              name="entry[direction]"
              class="w-full rounded-[var(--radius-md)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] px-3 py-2 text-sm focus:border-[var(--color-border-focus)] focus:outline-none focus:ring-2 focus:ring-[var(--color-border-focus)]/20"
            >
              <option value="given">Given</option>
              <option value="received">Received</option>
            </select>
          </div>
          <div>
            <label class="block text-sm font-medium text-[var(--color-text-primary)] mb-1">
              Description
            </label>
            <textarea
              name="entry[description]"
              rows="2"
              class="w-full rounded-[var(--radius-md)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] px-3 py-2 text-sm focus:border-[var(--color-border-focus)] focus:outline-none focus:ring-2 focus:ring-[var(--color-border-focus)]/20"
              placeholder="Optional details..."
            />
          </div>
        </div>
        <.modal_actions myself={@myself} entry_id={@entry_id} type={:gift} />
      </.form>
    </div>
    """
  end

  defp entry_modal_content(%{type: :conversation} = assigns) do
    ~H"""
    <div>
      <h3 class="text-lg font-semibold mb-4">
        {if @entry_id, do: "Edit Conversation", else: "New Conversation"}
      </h3>
      <.entry_error error={@error} />
      <.form for={%{}} phx-submit="save-entry" phx-target={@myself}>
        <div class="space-y-3">
          <div>
            <label class="block text-sm font-medium text-[var(--color-text-primary)] mb-1">
              Subject
            </label>
            <input
              type="text"
              name="entry[subject]"
              class="w-full rounded-[var(--radius-md)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] px-3 py-2 text-sm focus:border-[var(--color-border-focus)] focus:outline-none focus:ring-2 focus:ring-[var(--color-border-focus)]/20"
              placeholder="What was the conversation about?"
            />
          </div>
          <div>
            <label class="block text-sm font-medium text-[var(--color-text-primary)] mb-1">
              Platform
            </label>
            <select
              name="entry[platform]"
              class="w-full rounded-[var(--radius-md)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] px-3 py-2 text-sm focus:border-[var(--color-border-focus)] focus:outline-none focus:ring-2 focus:ring-[var(--color-border-focus)]/20"
            >
              <option value="sms">SMS</option>
              <option value="whatsapp">WhatsApp</option>
              <option value="telegram">Telegram</option>
              <option value="email">Email</option>
              <option value="instagram">Instagram</option>
              <option value="messenger">Messenger</option>
              <option value="signal">Signal</option>
              <option value="other">Other</option>
            </select>
          </div>
        </div>
        <.modal_actions myself={@myself} entry_id={@entry_id} type={:conversation} />
      </.form>
    </div>
    """
  end

  defp entry_modal_content(%{type: :activity} = assigns) do
    ~H"""
    <div>
      <h3 class="text-lg font-semibold mb-4">
        {if @entry_id, do: "Edit Activity", else: "New Activity"}
      </h3>
      <.entry_error error={@error} />
      <.form for={%{}} phx-submit="save-entry" phx-target={@myself}>
        <div class="space-y-3">
          <div>
            <label class="block text-sm font-medium text-[var(--color-text-primary)] mb-1">
              Title
            </label>
            <input
              type="text"
              name="entry[title]"
              class="w-full rounded-[var(--radius-md)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] px-3 py-2 text-sm focus:border-[var(--color-border-focus)] focus:outline-none focus:ring-2 focus:ring-[var(--color-border-focus)]/20"
              placeholder="What happened?"
            />
          </div>
          <div>
            <label class="block text-sm font-medium text-[var(--color-text-primary)] mb-1">
              When
            </label>
            <input
              type="datetime-local"
              name="entry[occurred_at]"
              value={Calendar.strftime(DateTime.utc_now(), "%Y-%m-%dT%H:%M")}
              class="w-full rounded-[var(--radius-md)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] px-3 py-2 text-sm focus:border-[var(--color-border-focus)] focus:outline-none focus:ring-2 focus:ring-[var(--color-border-focus)]/20"
            />
          </div>
          <div>
            <label class="block text-sm font-medium text-[var(--color-text-primary)] mb-1">
              Description
            </label>
            <textarea
              name="entry[description]"
              rows="3"
              class="w-full rounded-[var(--radius-md)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] px-3 py-2 text-sm focus:border-[var(--color-border-focus)] focus:outline-none focus:ring-2 focus:ring-[var(--color-border-focus)]/20"
              placeholder="Details..."
            />
          </div>
        </div>
        <.modal_actions myself={@myself} entry_id={@entry_id} type={:activity} />
      </.form>
    </div>
    """
  end

  defp entry_modal_content(%{type: :photo} = assigns) do
    ~H"""
    <div>
      <h3 class="text-lg font-semibold mb-4">Upload Photos</h3>
      <.form
        for={%{}}
        id="photo-upload-form"
        phx-submit="upload-photo"
        phx-change="validate-photo"
        phx-target={@myself}
        class="space-y-4"
      >
        <div class="rounded-[var(--radius-lg)] border-2 border-dashed border-[var(--color-border)] p-6 text-center hover:border-[var(--color-accent)]/50 transition-colors">
          <.icon name="hero-photo" class="size-8 text-[var(--color-text-disabled)] mx-auto mb-2" />
          <p class="text-sm text-[var(--color-text-secondary)] mb-2">
            Select up to 5 photos (max 10 MB each)
          </p>
          <.live_file_input
            upload={@uploads.photo}
            class="block w-full text-sm text-[var(--color-text-secondary)] file:mr-4 file:py-2 file:px-4 file:rounded-[var(--radius-md)] file:border-0 file:text-sm file:font-medium file:bg-[var(--color-accent)] file:text-[var(--color-accent-foreground)] file:cursor-pointer hover:file:bg-[var(--color-accent-hover)]"
          />
        </div>

        <%= for entry <- @uploads.photo.entries do %>
          <div class="flex items-center gap-3 text-sm">
            <div class="flex-1 min-w-0">
              <div class="flex items-center justify-between mb-1">
                <span class="truncate text-[var(--color-text-primary)]">{entry.client_name}</span>
                <button
                  type="button"
                  phx-click="cancel-photo-upload"
                  phx-value-ref={entry.ref}
                  phx-target={@myself}
                  class="text-[var(--color-text-tertiary)] hover:text-[var(--color-error)] cursor-pointer"
                >
                  <.icon name="hero-x-mark" class="size-4" />
                </button>
              </div>
              <div class="w-full bg-[var(--color-surface-sunken)] rounded-full h-1.5">
                <div
                  class="bg-[var(--color-accent)] h-1.5 rounded-full transition-all"
                  style={"width: #{entry.progress}%"}
                >
                </div>
              </div>
            </div>
          </div>
          <%= for err <- upload_errors(@uploads.photo, entry) do %>
            <p class="text-xs text-[var(--color-error)]">{photo_error_to_string(err)}</p>
          <% end %>
        <% end %>

        <%= for err <- upload_errors(@uploads.photo) do %>
          <p class="text-xs text-[var(--color-error)]">{photo_error_to_string(err)}</p>
        <% end %>

        <div class="flex gap-2">
          <button
            type="submit"
            disabled={@uploads.photo.entries == []}
            class="rounded-[var(--radius-md)] bg-[var(--color-accent)] text-[var(--color-accent-foreground)] px-4 py-2 text-sm font-medium hover:bg-[var(--color-accent-hover)] transition-colors inline-flex items-center gap-1.5 cursor-pointer disabled:opacity-50 disabled:cursor-not-allowed"
          >
            <.icon name="hero-arrow-up-tray" class="size-4" /> Upload
          </button>
          <button
            type="button"
            phx-click="close-modal"
            phx-target={@myself}
            class="rounded-[var(--radius-md)] border border-[var(--color-border)] px-4 py-2 text-sm font-medium text-[var(--color-text-secondary)] hover:bg-[var(--color-surface)] transition-colors cursor-pointer"
          >
            Cancel
          </button>
        </div>
      </.form>
    </div>
    """
  end

  defp entry_modal_content(assigns) do
    ~H"""
    <div>
      <h3 class="text-lg font-semibold mb-4">Unsupported type</h3>
      <p class="text-sm text-[var(--color-text-secondary)]">
        This entry type cannot be edited from here.
      </p>
    </div>
    """
  end

  defp entry_error(assigns) do
    ~H"""
    <div
      :if={@error}
      class="mb-3 p-2.5 rounded-lg bg-[var(--color-error-subtle)] border border-[var(--color-error)]/20 text-sm text-[var(--color-error)]"
    >
      {@error}
    </div>
    """
  end

  defp modal_actions(assigns) do
    ~H"""
    <div class="flex justify-between items-center mt-5 pt-4 border-t border-[var(--color-border-subtle)]">
      <button
        :if={@entry_id}
        type="button"
        phx-click="delete-entry"
        phx-value-type={@type}
        phx-value-id={@entry_id}
        phx-target={@myself}
        data-confirm="Delete this entry? This cannot be undone."
        class="text-sm text-[var(--color-error)] hover:underline cursor-pointer"
      >
        Delete
      </button>
      <div :if={!@entry_id} />
      <div class="flex gap-2">
        <button
          type="button"
          phx-click="close-modal"
          phx-target={@myself}
          class="rounded-[var(--radius-md)] border border-[var(--color-border)] px-4 py-2 text-sm font-medium text-[var(--color-text-secondary)] hover:bg-[var(--color-surface)] transition-colors cursor-pointer"
        >
          Cancel
        </button>
        <button
          type="submit"
          class="rounded-[var(--radius-md)] bg-[var(--color-accent)] text-[var(--color-accent-foreground)] px-4 py-2 text-sm font-medium hover:bg-[var(--color-accent-hover)] transition-colors cursor-pointer"
        >
          Save
        </button>
      </div>
    </div>
    """
  end

  # --- Helpers ---

  defp relative_time_or_date(assigns) do
    today = Date.utc_today()
    date = DateTime.to_date(assigns.datetime)
    diff = Date.diff(today, date)

    label =
      cond do
        diff == 0 -> "Today"
        diff == 1 -> "Yesterday"
        diff < 7 -> "#{diff} days ago"
        true -> Calendar.strftime(assigns.datetime, "%b %d, %Y")
      end

    assigns = assign(assigns, :label, label)

    ~H"""
    {@label}
    """
  end

  defp type_label(:note), do: "Note"
  defp type_label(:call), do: "Call"
  defp type_label(:life_event), do: "Life Event"
  defp type_label(:activity), do: "Activity"
  defp type_label(:task), do: "Task"
  defp type_label(:gift), do: "Gift"
  defp type_label(:photo), do: "Photo"
  defp type_label(:conversation), do: "Conversation"
  defp type_label(_), do: "Entry"

  defp duration_text(mins) when mins < 60, do: "#{mins} min"
  defp duration_text(mins), do: "#{div(mins, 60)}h #{rem(mins, 60)}m"

  defp strip_html(nil), do: ""

  defp strip_html(html) do
    html
    |> String.replace(~r/<[^>]+>/, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp photo_error_to_string(:too_large), do: "File too large (max 10 MB)"
  defp photo_error_to_string(:too_many_files), do: "Too many files (max 5)"
  defp photo_error_to_string(:not_accepted), do: "Invalid file type"
  defp photo_error_to_string(err), do: to_string(err)
end
