defmodule KithWeb.ContactLive.Merge do
  use KithWeb, :live_view

  alias Kith.Contacts
  alias Kith.DuplicateDetection
  alias Kith.Policy

  @mergeable_fields ~w(first_name last_name nickname birthdate description occupation company avatar)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Merge Contacts")
     |> assign(:contact_a, nil)
     |> assign(:contact_b, nil)
     |> assign(:step, 1)
     |> assign(:search_query, "")
     |> assign(:search_results, [])
     |> assign(:field_choices, default_field_choices())
     |> assign(:preview, nil)
     |> assign(:merging, false)
     |> assign(:candidate_id, nil)}
  end

  @impl true
  def handle_params(%{"id" => id} = params, _uri, socket) do
    scope = socket.assigns.current_scope
    user = scope.user
    account_id = scope.account.id

    if Policy.can?(user, :update, :contact) do
      contact_a = Contacts.get_contact(account_id, id, preload: [:tags, :gender])

      if is_nil(contact_a) do
        {:noreply,
         socket
         |> put_flash(:error, "Contact not found")
         |> push_navigate(to: ~p"/contacts")}
      else
        socket =
          socket
          |> assign(:page_title, "Merge #{contact_a.display_name || "Contact"}")
          |> assign(:contact_a, contact_a)
          |> assign(:contact_b, nil)
          |> assign(:step, 1)
          |> assign(:search_query, "")
          |> assign(:search_results, [])
          |> assign(:field_choices, default_field_choices())
          |> assign(:preview, nil)
          |> assign(:merging, false)
          |> assign(:candidate_id, nil)

        socket = maybe_preselect_contact(socket, params, account_id)

        {:noreply, socket}
      end
    else
      {:noreply,
       socket
       |> put_flash(:error, "You don't have permission to merge contacts")
       |> push_navigate(to: ~p"/contacts")}
    end
  end

  defp maybe_preselect_contact(
         socket,
         %{"with" => with_id, "candidate_id" => candidate_id},
         account_id
       ) do
    case Contacts.get_contact(account_id, String.to_integer(with_id), preload: [:tags, :gender]) do
      nil ->
        socket

      contact_b ->
        socket
        |> assign(:contact_b, contact_b)
        |> assign(:candidate_id, String.to_integer(candidate_id))
        |> assign(:step, 2)
    end
  end

  defp maybe_preselect_contact(socket, %{"with" => with_id}, account_id) do
    case Contacts.get_contact(account_id, String.to_integer(with_id), preload: [:tags, :gender]) do
      nil -> socket
      contact_b -> socket |> assign(:contact_b, contact_b) |> assign(:step, 2)
    end
  end

  defp maybe_preselect_contact(socket, _params, _account_id), do: socket

  # ── Step 1: Search ─────────────────────────────────────────────────────

  @impl true
  def handle_event("search", %{"query" => query}, socket) do
    scope = socket.assigns.current_scope
    contact_a = socket.assigns.contact_a

    results =
      if String.length(query) >= 2 do
        Contacts.search_contacts(scope.account.id, query)
        |> Enum.reject(&(&1.id == contact_a.id))
        |> Enum.take(10)
      else
        []
      end

    {:noreply,
     socket
     |> assign(:search_query, query)
     |> assign(:search_results, results)}
  end

  def handle_event("select-contact", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    contact_b =
      Contacts.get_contact(scope.account.id, String.to_integer(id), preload: [:tags, :gender])

    if contact_b do
      {:noreply,
       socket
       |> assign(:contact_b, contact_b)
       |> assign(:step, 2)}
    else
      {:noreply, put_flash(socket, :error, "Contact not found")}
    end
  end

  # ── Step 2: Field Choices ──────────────────────────────────────────────

  def handle_event("choose-field", %{"field" => field, "source" => source}, socket) do
    choices = Map.put(socket.assigns.field_choices, field, source)
    {:noreply, assign(socket, :field_choices, choices)}
  end

  def handle_event("go-to-preview", _params, socket) do
    contact_a = socket.assigns.contact_a
    contact_b = socket.assigns.contact_b

    case Contacts.merge_preview(contact_a.id, contact_b.id) do
      {:ok, preview} ->
        {:noreply,
         socket
         |> assign(:preview, preview)
         |> assign(:step, 3)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Preview failed: #{inspect(reason)}")}
    end
  end

  # ── Step 3: Preview & Execute ───────────────────────────────────────────

  def handle_event("execute-merge", _params, socket) do
    contact_a = socket.assigns.contact_a
    contact_b = socket.assigns.contact_b
    field_choices = socket.assigns.field_choices

    socket = assign(socket, :merging, true)

    case Contacts.merge_contacts(contact_a.id, contact_b.id, field_choices) do
      {:ok, _result} ->
        scope = socket.assigns.current_scope
        account_id = scope.account.id

        # Mark duplicate candidate as merged (if came from duplicates page)
        if candidate_id = socket.assigns[:candidate_id] do
          candidate = DuplicateDetection.get_candidate!(account_id, candidate_id)
          DuplicateDetection.mark_merged(candidate)
        end

        # Dismiss any other pending candidates involving either contact
        DuplicateDetection.dismiss_candidates_for_contact(account_id, contact_a.id)
        DuplicateDetection.dismiss_candidates_for_contact(account_id, contact_b.id)

        # Log the merge
        Kith.AuditLogs.log_event(account_id, scope.user, :contact_merged,
          contact_id: contact_a.id,
          contact_name: contact_a.display_name,
          metadata: %{
            survivor_id: contact_a.id,
            survivor_name: contact_a.display_name,
            non_survivor_id: contact_b.id,
            non_survivor_name: contact_b.display_name,
            field_choices: field_choices,
            sub_entities_moved: socket.assigns.preview
          }
        )

        {:noreply,
         socket
         |> put_flash(:info, "Contacts merged successfully")
         |> redirect(to: ~p"/contacts/#{contact_a.id}")}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:merging, false)
         |> put_flash(:error, "Merge failed: #{inspect(reason)}")}
    end
  end

  # ── Navigation ─────────────────────────────────────────────────────────

  def handle_event("back", _params, socket) do
    new_step = max(socket.assigns.step - 1, 1)
    {:noreply, assign(socket, :step, new_step)}
  end

  # ── Render ─────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :mergeable_fields, @mergeable_fields)

    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_path={@current_path}
      pending_duplicates_count={@pending_duplicates_count}
    >
      <div class="max-w-4xl mx-auto space-y-6">
        <div class="flex items-center justify-between">
          <h1 class="text-2xl font-semibold text-[var(--color-text-primary)] tracking-tight">
            Merge Contacts
          </h1>
          <span class="text-sm text-[var(--color-text-tertiary)]">
            Step {@step} of 3 — {step_label(@step)}
          </span>
        </div>

        <%!-- Step indicator (horizontal stepper) --%>
        <div class="flex gap-2">
          <div
            :for={s <- 1..3}
            class={[
              "h-1 flex-1 rounded-[var(--radius-full)] transition-colors duration-300",
              if(s <= @step, do: "bg-[var(--color-accent)]", else: "bg-[var(--color-border)]")
            ]}
          />
        </div>

        <%!-- Step 1: Search --%>
        <div :if={@step == 1 && @contact_a}>
          <UI.card>
            <div class="flex items-center gap-4 mb-4">
              <KithUI.avatar name={@contact_a.display_name} src={avatar_url(@contact_a)} size={:md} />
              <div>
                <p class="text-sm text-[var(--color-text-tertiary)]">Merging from:</p>
                <span class="font-semibold text-[var(--color-text-primary)]">
                  {@contact_a.display_name}
                </span>
              </div>
            </div>

            <p class="text-sm text-[var(--color-text-secondary)] mb-4">
              Search for the contact to merge with:
            </p>

            <form phx-change="search" phx-submit="search">
              <input
                type="text"
                name="query"
                value={@search_query}
                placeholder="Search by name, email, or phone..."
                phx-debounce="300"
                autofocus
                class="w-full rounded-[var(--radius-md)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] px-3 py-2 text-sm text-[var(--color-text-primary)] placeholder:text-[var(--color-text-disabled)] focus:border-[var(--color-border-focus)] focus:outline-none focus:ring-2 focus:ring-[var(--color-border-focus)]/20 transition-colors duration-150"
              />
            </form>

            <div
              :if={@search_results != []}
              class="mt-4 rounded-[var(--radius-lg)] border border-[var(--color-border)] divide-y divide-[var(--color-border-subtle)] overflow-hidden"
            >
              <button
                :for={contact <- @search_results}
                phx-click="select-contact"
                phx-value-id={contact.id}
                class="w-full text-start px-4 py-3 hover:bg-[var(--color-surface-sunken)] flex items-center justify-between transition-colors cursor-pointer"
              >
                <div>
                  <span class="font-medium text-[var(--color-text-primary)]">
                    {contact.display_name}
                  </span>
                  <span :if={contact.company} class="text-sm text-[var(--color-text-tertiary)] ms-2">
                    {contact.company}
                  </span>
                </div>
                <span class="text-xs text-[var(--color-accent)]">Select</span>
              </button>
            </div>

            <KithUI.empty_state
              :if={@search_query != "" && @search_results == []}
              icon="hero-magnifying-glass"
              title="No matches"
              message="No matching contacts found."
            />
          </UI.card>
        </div>

        <%!-- Step 2: Field Selection --%>
        <div :if={@step == 2 && @contact_b}>
          <UI.card>
            <div class="grid grid-cols-3 gap-4 mb-4 text-sm font-semibold text-[var(--color-text-secondary)]">
              <div>Field</div>
              <div class="flex items-center gap-2">
                <KithUI.avatar name={@contact_a.display_name} src={avatar_url(@contact_a)} size={:sm} />
                {@contact_a.display_name} (A)
              </div>
              <div class="flex items-center gap-2">
                <KithUI.avatar name={@contact_b.display_name} src={avatar_url(@contact_b)} size={:sm} />
                {@contact_b.display_name} (B)
              </div>
            </div>

            <div
              :for={field <- @mergeable_fields}
              class="grid grid-cols-3 gap-4 py-3 border-t border-[var(--color-border-subtle)] items-center"
            >
              <div class="text-sm font-medium text-[var(--color-text-secondary)]">
                {humanize(field)}
              </div>
              <button
                phx-click="choose-field"
                phx-value-field={field}
                phx-value-source="survivor"
                class={[
                  "text-start text-sm px-3 py-2 rounded-[var(--radius-md)] border transition-colors cursor-pointer",
                  if(Map.get(@field_choices, field) == "survivor",
                    do:
                      "border-[var(--color-accent)] bg-[var(--color-accent-subtle)] text-[var(--color-accent)]",
                    else: "border-[var(--color-border)] hover:border-[var(--color-border-focus)]/50"
                  )
                ]}
              >
                {field_value(@contact_a, field) || "-"}
              </button>
              <button
                phx-click="choose-field"
                phx-value-field={field}
                phx-value-source="non_survivor"
                class={[
                  "text-start text-sm px-3 py-2 rounded-[var(--radius-md)] border transition-colors cursor-pointer",
                  if(Map.get(@field_choices, field) == "non_survivor",
                    do:
                      "border-[var(--color-accent)] bg-[var(--color-accent-subtle)] text-[var(--color-accent)]",
                    else: "border-[var(--color-border)] hover:border-[var(--color-border-focus)]/50"
                  )
                ]}
              >
                {field_value(@contact_b, field) || "-"}
              </button>
            </div>

            <div class="mt-6 flex gap-3">
              <UI.button variant="secondary" phx-click="back">Back</UI.button>
              <UI.button phx-click="go-to-preview">Preview Merge</UI.button>
            </div>
          </UI.card>
        </div>

        <%!-- Step 3: Dry-run Preview --%>
        <div :if={@step == 3 && @preview}>
          <UI.card>
            <:header>Merge Preview</:header>
            <p class="text-sm text-[var(--color-text-secondary)] mb-4">
              This is what will happen when you merge
              <span class="font-semibold text-[var(--color-text-primary)]">
                {@contact_b.display_name}
              </span>
              into <span class="font-semibold text-[var(--color-text-primary)]">{@contact_a.display_name}</span>:
            </p>

            <ul class="space-y-2 text-sm">
              <li :if={@preview.notes > 0} class="flex items-center gap-2">
                <span class="w-2 h-2 bg-[var(--color-info)] rounded-full" />{@preview.notes} notes will be combined
              </li>
              <li :if={@preview.activities > 0} class="flex items-center gap-2">
                <span class="w-2 h-2 bg-[var(--color-info)] rounded-full" />{@preview.activities} activities will be combined
              </li>
              <li :if={@preview.calls > 0} class="flex items-center gap-2">
                <span class="w-2 h-2 bg-[var(--color-info)] rounded-full" />{@preview.calls} calls will be combined
              </li>
              <li :if={@preview.life_events > 0} class="flex items-center gap-2">
                <span class="w-2 h-2 bg-[var(--color-info)] rounded-full" />{@preview.life_events} life events will be combined
              </li>
              <li :if={@preview.addresses > 0} class="flex items-center gap-2">
                <span class="w-2 h-2 bg-[var(--color-info)] rounded-full" />{@preview.addresses} addresses will be combined
              </li>
              <li :if={@preview.contact_fields > 0} class="flex items-center gap-2">
                <span class="w-2 h-2 bg-[var(--color-info)] rounded-full" />{@preview.contact_fields} contact fields will be combined
              </li>
              <li :if={@preview.reminders > 0} class="flex items-center gap-2">
                <span class="w-2 h-2 bg-[var(--color-info)] rounded-full" />{@preview.reminders} reminders will be combined
              </li>
              <li :if={@preview.tags_to_merge > 0} class="flex items-center gap-2">
                <span class="w-2 h-2 bg-[var(--color-success)] rounded-full" />{@preview.tags_to_merge} new tags will be added
              </li>
              <li :if={@preview.tags_duplicate > 0} class="flex items-center gap-2">
                <span class="w-2 h-2 bg-[var(--color-text-disabled)] rounded-full" />{@preview.tags_duplicate} duplicate tags will be removed
              </li>
              <li :if={@preview.relationships_to_dedup > 0} class="flex items-center gap-2">
                <span class="w-2 h-2 bg-[var(--color-warning)] rounded-full" />{@preview.relationships_to_dedup} duplicate relationships will be removed
              </li>
              <li :if={@preview.relationships_to_remap > 0} class="flex items-center gap-2">
                <span class="w-2 h-2 bg-[var(--color-info)] rounded-full" />{@preview.relationships_to_remap} relationships will be transferred
              </li>
            </ul>

            <div class="mt-4 p-3 rounded-[var(--radius-md)] bg-[var(--color-warning-subtle)] border-s-4 border-[var(--color-warning)] text-sm text-[var(--color-text-primary)]">
              {@contact_b.display_name} will be moved to trash (recoverable for 30 days).
            </div>

            <div class="mt-6 flex gap-3">
              <UI.button variant="secondary" phx-click="back" disabled={@merging}>Back</UI.button>
              <UI.button variant="danger" phx-click="execute-merge" disabled={@merging}>
                {if @merging, do: "Merging...", else: "Merge Contacts"}
              </UI.button>
            </div>
          </UI.card>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # ── Helpers ────────────────────────────────────────────────────────────

  defp step_label(1), do: "Select contact"
  defp step_label(2), do: "Choose fields"
  defp step_label(3), do: "Review & merge"

  defp default_field_choices do
    @mergeable_fields
    |> Enum.map(&{&1, "survivor"})
    |> Map.new()
  end

  defp field_value(contact, field) do
    value = Map.get(contact, String.to_existing_atom(field))

    case value do
      %Date{} = d -> Date.to_iso8601(d)
      nil -> nil
      v -> to_string(v)
    end
  end

  defp humanize(field) do
    field
    |> String.replace("_", " ")
    |> String.capitalize()
  end
end
