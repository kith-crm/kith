defmodule KithWeb.JournalLive.Index do
  @moduledoc """
  LiveView for the Journal index page.

  Displays a timeline of journal entries in reverse chronological order with
  mood indicators. Supports creating, editing, deleting, and filtering entries
  by mood. Journal entries are account-level (not contact-scoped) and private
  entries are visible only to their author.
  """

  use KithWeb, :live_view

  alias Kith.Journal

  @moods ~w(great good neutral bad awful)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Journal")
     |> assign(:entries, [])
     |> assign(:show_form, false)
     |> assign(:editing_entry_id, nil)
     |> assign(:mood_filter, nil)
     |> assign(:form_errors, %{})}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    account_id = socket.assigns.current_scope.account.id
    user_id = socket.assigns.current_scope.user.id

    mood_filter =
      case params do
        %{"mood" => mood} when mood in @moods -> mood
        _ -> nil
      end

    entries =
      Journal.list_entries(account_id, author_id: user_id, mood: mood_filter)

    {:noreply,
     socket
     |> assign(:account_id, account_id)
     |> assign(:current_user_id, user_id)
     |> assign(:mood_filter, mood_filter)
     |> assign(:entries, entries)}
  end

  # ── Events ──────────────────────────────────────────────────────────

  @impl true
  def handle_event("show-form", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_form, true)
     |> assign(:editing_entry_id, nil)
     |> assign(:form_errors, %{})}
  end

  def handle_event("cancel-form", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_form, false)
     |> assign(:editing_entry_id, nil)
     |> assign(:form_errors, %{})}
  end

  def handle_event("save-entry", %{"entry" => entry_params}, socket) do
    attrs =
      entry_params
      |> maybe_set_occurred_at()

    case Journal.create_entry(socket.assigns.account_id, socket.assigns.current_user_id, attrs) do
      {:ok, _entry} ->
        entries =
          Journal.list_entries(socket.assigns.account_id,
            author_id: socket.assigns.current_user_id,
            mood: socket.assigns.mood_filter
          )

        {:noreply,
         socket
         |> assign(:entries, entries)
         |> assign(:show_form, false)
         |> assign(:form_errors, %{})
         |> put_flash(:info, "Journal entry created.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form_errors, changeset_errors(changeset))}
    end
  end

  def handle_event("edit-entry", %{"id" => id}, socket) do
    entry = Journal.get_entry!(socket.assigns.account_id, String.to_integer(id))

    {:noreply,
     socket
     |> assign(:editing_entry_id, entry.id)
     |> assign(:show_form, false)
     |> assign(:form_errors, %{})}
  end

  def handle_event("update-entry", %{"entry" => entry_params}, socket) do
    entry = Journal.get_entry!(socket.assigns.account_id, socket.assigns.editing_entry_id)

    case Journal.update_entry(entry, entry_params) do
      {:ok, _entry} ->
        entries =
          Journal.list_entries(socket.assigns.account_id,
            author_id: socket.assigns.current_user_id,
            mood: socket.assigns.mood_filter
          )

        {:noreply,
         socket
         |> assign(:entries, entries)
         |> assign(:editing_entry_id, nil)
         |> assign(:form_errors, %{})
         |> put_flash(:info, "Journal entry updated.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form_errors, changeset_errors(changeset))}
    end
  end

  def handle_event("delete-entry", %{"id" => id}, socket) do
    entry = Journal.get_entry!(socket.assigns.account_id, String.to_integer(id))
    {:ok, _} = Journal.delete_entry(entry)

    entries =
      Journal.list_entries(socket.assigns.account_id,
        author_id: socket.assigns.current_user_id,
        mood: socket.assigns.mood_filter
      )

    {:noreply,
     socket
     |> assign(:entries, entries)
     |> put_flash(:info, "Journal entry deleted.")}
  end

  def handle_event("filter-mood", %{"mood" => ""}, socket) do
    {:noreply, push_patch(socket, to: ~p"/journal")}
  end

  def handle_event("filter-mood", %{"mood" => mood}, socket) do
    {:noreply, push_patch(socket, to: ~p"/journal?mood=#{mood}")}
  end

  # ── Render ──────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :moods, @moods)

    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_path={@current_path}
      pending_duplicates_count={@pending_duplicates_count}
    >
      <div class="max-w-3xl mx-auto">
        <%!-- Header --%>
        <div class="flex items-center justify-between mb-6">
          <h1 class="text-2xl font-bold text-[var(--color-text-primary)]">Journal</h1>
          <button
            phx-click="show-form"
            class="inline-flex items-center gap-1.5 rounded-[var(--radius-md)] bg-[var(--color-accent)] text-[var(--color-accent-foreground)] px-4 py-2 text-sm font-medium hover:bg-[var(--color-accent-hover)] transition-colors cursor-pointer"
          >
            <.icon name="hero-plus" class="size-4" /> New Entry
          </button>
        </div>

        <%!-- Mood filter bar --%>
        <div class="mb-6">
          <div class="inline-flex max-w-full flex-wrap gap-1 rounded-[var(--radius-lg)] border border-[var(--color-border)] p-0.5 bg-[var(--color-surface-sunken)] sm:gap-0 sm:rounded-[var(--radius-full)]">
            <button
              phx-click="filter-mood"
              phx-value-mood=""
              class={[
                "min-h-11 whitespace-nowrap px-3.5 py-1 rounded-[var(--radius-full)] text-sm font-medium transition-all duration-200 cursor-pointer sm:min-h-0",
                if(@mood_filter == nil,
                  do: "bg-[var(--color-accent)] text-[var(--color-accent-foreground)] shadow-sm",
                  else: "text-[var(--color-text-secondary)] hover:text-[var(--color-text-primary)]"
                )
              ]}
            >
              All
            </button>
            <button
              :for={mood <- @moods}
              phx-click="filter-mood"
              phx-value-mood={mood}
              class={[
                "min-h-11 whitespace-nowrap px-3.5 py-1 rounded-[var(--radius-full)] text-sm font-medium transition-all duration-200 cursor-pointer sm:min-h-0",
                if(@mood_filter == mood,
                  do: "bg-[var(--color-accent)] text-[var(--color-accent-foreground)] shadow-sm",
                  else: "text-[var(--color-text-secondary)] hover:text-[var(--color-text-primary)]"
                )
              ]}
            >
              {mood_emoji(mood)} {mood_label(mood)}
            </button>
          </div>
        </div>

        <%!-- New entry form --%>
        <%= if @show_form do %>
          <div class="rounded-[var(--radius-lg)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] shadow-sm mb-6">
            <div class="p-5">
              <h2 class="text-base font-semibold text-[var(--color-text-primary)] mb-4">
                New Journal Entry
              </h2>
              <.form for={%{}} phx-submit="save-entry">
                <div class="space-y-4">
                  <%!-- Title --%>
                  <div>
                    <label class="block text-sm font-medium text-[var(--color-text-secondary)] mb-1">
                      Title <span class="text-[var(--color-text-tertiary)]">(optional)</span>
                    </label>
                    <input
                      type="text"
                      name="entry[title]"
                      placeholder="Give this entry a title..."
                      class="w-full rounded-[var(--radius-md)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] px-3 py-2 text-sm text-[var(--color-text-primary)] placeholder:text-[var(--color-text-disabled)] focus:border-[var(--color-accent)] focus:ring-1 focus:ring-[var(--color-accent)] outline-none transition-colors"
                    />
                  </div>

                  <%!-- Content --%>
                  <div>
                    <label class="block text-sm font-medium text-[var(--color-text-secondary)] mb-1">
                      Content <span class="text-[var(--color-error)]">*</span>
                    </label>
                    <textarea
                      name="entry[content]"
                      rows="5"
                      placeholder="What's on your mind?"
                      class="w-full rounded-[var(--radius-md)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] px-3 py-2 text-sm text-[var(--color-text-primary)] placeholder:text-[var(--color-text-disabled)] focus:border-[var(--color-accent)] focus:ring-1 focus:ring-[var(--color-accent)] outline-none transition-colors resize-y"
                    />
                    <p :if={@form_errors[:content]} class="mt-1 text-xs text-[var(--color-error)]">
                      {Enum.join(@form_errors[:content], ", ")}
                    </p>
                  </div>

                  <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
                    <%!-- Mood --%>
                    <div>
                      <label class="block text-sm font-medium text-[var(--color-text-secondary)] mb-1">
                        Mood
                      </label>
                      <select
                        name="entry[mood]"
                        class="w-full rounded-[var(--radius-md)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] px-3 py-2 text-sm text-[var(--color-text-primary)] focus:border-[var(--color-accent)] focus:ring-1 focus:ring-[var(--color-accent)] outline-none transition-colors cursor-pointer"
                      >
                        <option value="">No mood</option>
                        <option :for={mood <- @moods} value={mood}>
                          {mood_emoji(mood)} {mood_label(mood)}
                        </option>
                      </select>
                    </div>

                    <%!-- Date --%>
                    <div>
                      <label class="block text-sm font-medium text-[var(--color-text-secondary)] mb-1">
                        Date
                      </label>
                      <input
                        type="datetime-local"
                        name="entry[occurred_at]"
                        value={default_datetime()}
                        class="w-full rounded-[var(--radius-md)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] px-3 py-2 text-sm text-[var(--color-text-primary)] focus:border-[var(--color-accent)] focus:ring-1 focus:ring-[var(--color-accent)] outline-none transition-colors"
                      />
                      <p
                        :if={@form_errors[:occurred_at]}
                        class="mt-1 text-xs text-[var(--color-error)]"
                      >
                        {Enum.join(@form_errors[:occurred_at], ", ")}
                      </p>
                    </div>
                  </div>

                  <%!-- Privacy --%>
                  <div>
                    <label class="flex cursor-pointer justify-start gap-2">
                      <input
                        type="checkbox"
                        name="entry[is_private]"
                        value="true"
                        checked
                        class="size-4 rounded-[var(--radius-sm)] border border-[var(--color-border)] accent-[var(--color-accent)] cursor-pointer"
                      />
                      <span class="text-sm font-medium text-[var(--color-text-primary)] flex items-center gap-1">
                        <.icon name="hero-lock-closed" class="size-4" /> Private (only visible to you)
                      </span>
                    </label>
                  </div>
                </div>

                <div class="flex gap-2 mt-4">
                  <button
                    type="submit"
                    class="inline-flex items-center gap-1.5 rounded-[var(--radius-md)] bg-[var(--color-accent)] text-[var(--color-accent-foreground)] px-4 py-2 text-sm font-medium hover:bg-[var(--color-accent-hover)] transition-colors cursor-pointer"
                  >
                    Save Entry
                  </button>
                  <button
                    type="button"
                    phx-click="cancel-form"
                    class="inline-flex items-center gap-1.5 rounded-[var(--radius-md)] px-3 py-2 text-sm font-medium text-[var(--color-text-secondary)] hover:bg-[var(--color-surface-sunken)] hover:text-[var(--color-text-primary)] transition-colors cursor-pointer"
                  >
                    Cancel
                  </button>
                </div>
              </.form>
            </div>
          </div>
        <% end %>

        <%!-- Empty state --%>
        <%= if @entries == [] and not @show_form do %>
          <KithUI.empty_state
            icon="hero-book-open"
            title={
              if @mood_filter,
                do: "No #{mood_label(@mood_filter)} entries",
                else: "No journal entries yet"
            }
            message={
              if @mood_filter,
                do: "Try a different mood filter or write a new entry.",
                else: "Start journaling to capture your thoughts, reflections, and moods."
            }
          >
            <:actions>
              <button
                phx-click="show-form"
                class="inline-flex items-center gap-1.5 rounded-[var(--radius-md)] bg-[var(--color-accent)] text-[var(--color-accent-foreground)] px-4 py-2 text-sm font-medium hover:bg-[var(--color-accent-hover)] transition-colors cursor-pointer"
              >
                Write Your First Entry
              </button>
            </:actions>
          </KithUI.empty_state>
        <% end %>

        <%!-- Entries timeline --%>
        <%= if @entries != [] do %>
          <div class="space-y-4">
            <%= for entry <- @entries do %>
              <div
                id={"entry-#{entry.id}"}
                class="rounded-[var(--radius-lg)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] shadow-sm hover:border-[var(--color-border-focus)]/30 transition-colors duration-150"
              >
                <div class="p-5">
                  <%= if @editing_entry_id == entry.id do %>
                    <%!-- Inline edit form --%>
                    <.form for={%{}} phx-submit="update-entry">
                      <div class="space-y-4">
                        <div>
                          <label class="block text-sm font-medium text-[var(--color-text-secondary)] mb-1">
                            Title
                          </label>
                          <input
                            type="text"
                            name="entry[title]"
                            value={entry.title}
                            placeholder="Give this entry a title..."
                            class="w-full rounded-[var(--radius-md)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] px-3 py-2 text-sm text-[var(--color-text-primary)] placeholder:text-[var(--color-text-disabled)] focus:border-[var(--color-accent)] focus:ring-1 focus:ring-[var(--color-accent)] outline-none transition-colors"
                          />
                        </div>
                        <div>
                          <label class="block text-sm font-medium text-[var(--color-text-secondary)] mb-1">
                            Content
                          </label>
                          <textarea
                            name="entry[content]"
                            rows="5"
                            class="w-full rounded-[var(--radius-md)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] px-3 py-2 text-sm text-[var(--color-text-primary)] placeholder:text-[var(--color-text-disabled)] focus:border-[var(--color-accent)] focus:ring-1 focus:ring-[var(--color-accent)] outline-none transition-colors resize-y"
                          >{entry.content}</textarea>
                          <p
                            :if={@form_errors[:content]}
                            class="mt-1 text-xs text-[var(--color-error)]"
                          >
                            {Enum.join(@form_errors[:content], ", ")}
                          </p>
                        </div>
                        <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
                          <div>
                            <label class="block text-sm font-medium text-[var(--color-text-secondary)] mb-1">
                              Mood
                            </label>
                            <select
                              name="entry[mood]"
                              class="w-full rounded-[var(--radius-md)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] px-3 py-2 text-sm text-[var(--color-text-primary)] focus:border-[var(--color-accent)] focus:ring-1 focus:ring-[var(--color-accent)] outline-none transition-colors cursor-pointer"
                            >
                              <option value="">No mood</option>
                              <option :for={mood <- @moods} value={mood} selected={entry.mood == mood}>
                                {mood_emoji(mood)} {mood_label(mood)}
                              </option>
                            </select>
                          </div>
                          <div>
                            <label class="block text-sm font-medium text-[var(--color-text-secondary)] mb-1">
                              Date
                            </label>
                            <input
                              type="datetime-local"
                              name="entry[occurred_at]"
                              value={format_datetime_local(entry.occurred_at)}
                              class="w-full rounded-[var(--radius-md)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] px-3 py-2 text-sm text-[var(--color-text-primary)] focus:border-[var(--color-accent)] focus:ring-1 focus:ring-[var(--color-accent)] outline-none transition-colors"
                            />
                          </div>
                        </div>
                        <div>
                          <label class="flex cursor-pointer justify-start gap-2">
                            <input
                              type="checkbox"
                              name="entry[is_private]"
                              value="true"
                              checked={entry.is_private}
                              class="size-4 rounded-[var(--radius-sm)] border border-[var(--color-border)] accent-[var(--color-accent)] cursor-pointer"
                            />
                            <span class="text-sm font-medium text-[var(--color-text-primary)] flex items-center gap-1">
                              <.icon name="hero-lock-closed" class="size-4" /> Private
                            </span>
                          </label>
                        </div>
                      </div>
                      <div class="flex gap-2 mt-4">
                        <button
                          type="submit"
                          class="inline-flex items-center gap-1.5 rounded-[var(--radius-md)] bg-[var(--color-accent)] text-[var(--color-accent-foreground)] px-3 py-1.5 text-xs font-medium hover:bg-[var(--color-accent-hover)] transition-colors cursor-pointer"
                        >
                          Save
                        </button>
                        <button
                          type="button"
                          phx-click="cancel-form"
                          class="inline-flex items-center gap-1.5 rounded-[var(--radius-md)] px-2.5 py-1.5 text-xs font-medium text-[var(--color-text-secondary)] hover:bg-[var(--color-surface-sunken)] hover:text-[var(--color-text-primary)] transition-colors cursor-pointer"
                        >
                          Cancel
                        </button>
                      </div>
                    </.form>
                  <% else %>
                    <%!-- Entry display --%>
                    <div class="flex items-start gap-4">
                      <%!-- Mood emoji --%>
                      <div class="flex items-center justify-center size-12 rounded-[var(--radius-lg)] bg-[var(--color-surface-sunken)] shrink-0 text-2xl">
                        {mood_emoji(entry.mood)}
                      </div>

                      <div class="flex-1 min-w-0">
                        <%!-- Title + private badge --%>
                        <div class="flex items-center gap-2">
                          <h3
                            :if={entry.title}
                            class="text-base font-semibold text-[var(--color-text-primary)] truncate"
                          >
                            {entry.title}
                          </h3>
                          <span
                            :if={entry.mood}
                            class="inline-flex items-center rounded-[var(--radius-full)] px-2 py-0.5 text-xs font-medium bg-[var(--color-surface-sunken)] text-[var(--color-text-secondary)]"
                          >
                            {mood_label(entry.mood)}
                          </span>
                          <.icon
                            :if={entry.is_private}
                            name="hero-lock-closed"
                            class="size-4 text-[var(--color-warning)] shrink-0"
                          />
                        </div>

                        <%!-- Content --%>
                        <div class="mt-2 prose prose-sm max-w-none text-[var(--color-text-secondary)]">
                          {Kith.RichText.render(entry.content)}
                        </div>

                        <%!-- Footer: date + actions --%>
                        <div class="flex items-center justify-between mt-3 text-xs text-[var(--color-text-tertiary)]">
                          <span>{format_entry_date(entry.occurred_at)}</span>
                          <div class="flex gap-2">
                            <button
                              phx-click="edit-entry"
                              phx-value-id={entry.id}
                              class="text-[var(--color-accent)] hover:text-[var(--color-accent-hover)] transition-colors cursor-pointer"
                            >
                              Edit
                            </button>
                            <button
                              phx-click="delete-entry"
                              phx-value-id={entry.id}
                              data-confirm="Delete this journal entry? This cannot be undone."
                              class="text-[var(--color-error)] hover:text-[var(--color-error)] transition-colors cursor-pointer"
                            >
                              Delete
                            </button>
                          </div>
                        </div>
                      </div>
                    </div>
                  <% end %>
                </div>
              </div>
            <% end %>
          </div>
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  # ── Private helpers ─────────────────────────────────────────────────

  defp mood_emoji("great"), do: "\u{1F604}"
  defp mood_emoji("good"), do: "\u{1F642}"
  defp mood_emoji("neutral"), do: "\u{1F610}"
  defp mood_emoji("bad"), do: "\u{1F614}"
  defp mood_emoji("awful"), do: "\u{1F622}"
  defp mood_emoji(_), do: ""

  defp mood_label("great"), do: "Great"
  defp mood_label("good"), do: "Good"
  defp mood_label("neutral"), do: "Neutral"
  defp mood_label("bad"), do: "Bad"
  defp mood_label("awful"), do: "Awful"
  defp mood_label(_), do: ""

  defp default_datetime do
    DateTime.utc_now()
    |> Calendar.strftime("%Y-%m-%dT%H:%M")
  end

  defp format_datetime_local(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%dT%H:%M")
  end

  defp format_datetime_local(_), do: default_datetime()

  defp format_entry_date(%DateTime{} = dt) do
    case Kith.Cldr.DateTime.to_string(dt, format: :medium) do
      {:ok, str} -> str
      _ -> to_string(dt)
    end
  end

  defp format_entry_date(_), do: ""

  defp maybe_set_occurred_at(%{"occurred_at" => ""} = params) do
    Map.put(params, "occurred_at", DateTime.utc_now() |> DateTime.to_iso8601())
  end

  defp maybe_set_occurred_at(%{"occurred_at" => nil} = params) do
    Map.put(params, "occurred_at", DateTime.utc_now() |> DateTime.to_iso8601())
  end

  defp maybe_set_occurred_at(params) when not is_map_key(params, "occurred_at") do
    Map.put(params, "occurred_at", DateTime.utc_now() |> DateTime.to_iso8601())
  end

  defp maybe_set_occurred_at(params), do: params

  defp changeset_errors(%Ecto.Changeset{} = changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
