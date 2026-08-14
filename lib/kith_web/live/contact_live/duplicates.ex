defmodule KithWeb.ContactLive.Duplicates do
  @moduledoc "Page showing potential duplicate contacts for review."

  use KithWeb, :live_view

  alias Kith.DuplicateDetection
  alias Kith.Policy
  alias Kith.Workers.DuplicateDetectionWorker

  @page_size 20

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Duplicate Contacts")
     |> assign(:candidates, [])
     |> assign(:has_more, false)
     |> assign(:total_count, 0)}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    scope = socket.assigns.current_scope
    account_id = scope.account.id

    candidates = DuplicateDetection.list_candidates(account_id, limit: @page_size)
    total_count = DuplicateDetection.pending_count(account_id)

    {:noreply,
     socket
     |> assign(:account_id, account_id)
     |> assign(:candidates, candidates)
     |> assign(:total_count, total_count)
     |> assign(:has_more, length(candidates) >= @page_size)}
  end

  @impl true
  def handle_event("dismiss", %{"id" => id}, socket) do
    candidate =
      DuplicateDetection.get_candidate!(socket.assigns.account_id, String.to_integer(id))

    {:ok, _} = DuplicateDetection.dismiss_candidate(candidate)

    candidates = Enum.reject(socket.assigns.candidates, &(&1.id == candidate.id))
    total_count = socket.assigns.total_count - 1

    {:noreply,
     socket
     |> assign(:candidates, candidates)
     |> assign(:total_count, total_count)
     |> assign(:pending_duplicates_count, total_count)
     |> put_flash(:info, "Duplicate dismissed.")}
  end

  def handle_event("load_more", _params, socket) do
    offset = length(socket.assigns.candidates)

    more =
      DuplicateDetection.list_candidates(socket.assigns.account_id,
        limit: @page_size,
        offset: offset
      )

    {:noreply,
     socket
     |> assign(:candidates, socket.assigns.candidates ++ more)
     |> assign(:has_more, length(more) >= @page_size)}
  end

  def handle_event("scan", _params, socket) do
    user = socket.assigns.current_scope.user

    if Policy.can?(user, :manage, :account) do
      Oban.insert(DuplicateDetectionWorker.new(%{account_id: socket.assigns.account_id}))

      {:noreply, put_flash(socket, :info, "Duplicate scan started. Results will appear shortly.")}
    else
      {:noreply, put_flash(socket, :error, "Not authorized.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_path={@current_path}
      pending_duplicates_count={@pending_duplicates_count}
    >
      <div class="max-w-4xl mx-auto">
        <div class="mb-4">
          <.link
            navigate={~p"/contacts"}
            class="inline-flex items-center gap-1.5 text-sm text-[var(--color-text-secondary)] hover:text-[var(--color-accent)] transition-colors"
          >
            <.icon name="hero-arrow-left" class="size-4 rtl:rotate-180" /> Back to Contacts
          </.link>
        </div>

        <div class="flex items-center justify-between mb-6">
          <div>
            <h1 class="text-2xl font-bold text-[var(--color-text-primary)]">Duplicate Contacts</h1>
            <p class="text-sm text-[var(--color-text-secondary)] mt-1">
              {@total_count} potential duplicate{if @total_count != 1, do: "s"} found
            </p>
          </div>
          <button
            phx-click="scan"
            class="inline-flex items-center gap-1.5 rounded-[var(--radius-md)] bg-[var(--color-accent)] text-[var(--color-accent-foreground)] px-4 py-2 text-sm font-medium hover:bg-[var(--color-accent-hover)] transition-colors cursor-pointer"
          >
            <.icon name="hero-magnifying-glass" class="size-4" /> Scan Now
          </button>
        </div>

        <%= if @candidates == [] do %>
          <KithUI.empty_state
            icon="hero-check-circle"
            title="No duplicates found"
            message="Your contacts look clean! Run a scan to check for potential duplicates."
          />
        <% else %>
          <div class="space-y-4">
            <div
              :for={candidate <- @candidates}
              class="rounded-[var(--radius-lg)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] shadow-sm p-4"
            >
              <div class="flex items-center justify-between mb-3">
                <div class="flex items-center gap-2">
                  <span class={[
                    "inline-flex items-center rounded-full px-2 py-0.5 text-xs font-medium",
                    candidate.score >= 0.8 &&
                      "bg-red-100 text-red-700 dark:bg-red-900/30 dark:text-red-400",
                    candidate.score >= 0.5 && candidate.score < 0.8 &&
                      "bg-yellow-100 text-yellow-700 dark:bg-yellow-900/30 dark:text-yellow-400",
                    candidate.score < 0.5 &&
                      "bg-blue-100 text-blue-700 dark:bg-blue-900/30 dark:text-blue-400"
                  ]}>
                    {Float.round(candidate.score * 100, 0)}% match
                  </span>
                  <span class="text-xs text-[var(--color-text-tertiary)]">
                    {Enum.join(candidate.reasons, ", ")}
                  </span>
                </div>
                <span class="text-xs text-[var(--color-text-tertiary)]">
                  Detected <.date_display date={candidate.detected_at} />
                </span>
              </div>

              <div class="grid grid-cols-2 gap-4">
                <div class="rounded-[var(--radius-md)] border border-[var(--color-border-subtle)] p-3">
                  <.link
                    navigate={~p"/contacts/#{candidate.contact.id}"}
                    class="text-sm font-semibold text-[var(--color-accent)] hover:underline"
                  >
                    {candidate.contact.display_name}
                  </.link>
                </div>
                <div class="rounded-[var(--radius-md)] border border-[var(--color-border-subtle)] p-3">
                  <.link
                    navigate={~p"/contacts/#{candidate.duplicate_contact.id}"}
                    class="text-sm font-semibold text-[var(--color-accent)] hover:underline"
                  >
                    {candidate.duplicate_contact.display_name}
                  </.link>
                </div>
              </div>

              <div class="flex gap-2 mt-3">
                <.link
                  navigate={
                    ~p"/contacts/#{candidate.contact.id}/merge?with=#{candidate.duplicate_contact.id}&candidate_id=#{candidate.id}"
                  }
                  class="inline-flex items-center gap-1.5 rounded-[var(--radius-md)] bg-[var(--color-accent)] text-[var(--color-accent-foreground)] px-3 py-1.5 text-xs font-medium hover:bg-[var(--color-accent-hover)] transition-colors"
                >
                  <.icon name="hero-arrows-right-left" class="size-4" /> Merge
                </.link>
                <button
                  phx-click="dismiss"
                  phx-value-id={candidate.id}
                  class="inline-flex items-center gap-1.5 rounded-[var(--radius-md)] px-3 py-1.5 text-xs font-medium text-[var(--color-text-secondary)] hover:bg-[var(--color-surface-sunken)] hover:text-[var(--color-text-primary)] transition-colors cursor-pointer"
                >
                  <.icon name="hero-x-mark" class="size-4" /> Dismiss
                </button>
              </div>
            </div>

            <div :if={@has_more} class="flex justify-center pt-2 pb-4">
              <button
                phx-click="load_more"
                class="inline-flex items-center gap-1.5 rounded-[var(--radius-md)] px-4 py-2 text-sm font-medium text-[var(--color-text-secondary)] hover:bg-[var(--color-surface-sunken)] hover:text-[var(--color-text-primary)] border border-[var(--color-border)] transition-colors cursor-pointer"
              >
                Load more
              </button>
            </div>
          </div>
        <% end %>
      </div>
    </Layouts.app>
    """
  end
end
