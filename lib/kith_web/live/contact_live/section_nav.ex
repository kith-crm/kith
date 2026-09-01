defmodule KithWeb.ContactLive.SectionNav do
  @moduledoc """
  The Contacts section's secondary navigation (All / Archived / Duplicates /
  Trash), with the pending-duplicates badge.

  Extracted from `ContactLive.Index` so pages that live outside that LiveView
  (the cluster merge wizard) can render the same bar. `ContactLive.Index`
  navigates within itself, so it passes `link_mode={:patch}`; the wizard is a
  separate LiveView, so it passes `link_mode={:navigate}`.
  """

  use KithWeb, :html

  @doc """
  Renders the four-item section nav.

  * `active` — which tab is current (`:index | :archived | :duplicates | :trash`)
  * `pending_duplicates_count` — badge count on the Duplicates tab
  * `link_mode` — `:patch` (same LiveView) or `:navigate` (cross LiveView)
  """
  attr :active, :atom, required: true, values: [:index, :archived, :duplicates, :trash]
  attr :pending_duplicates_count, :integer, default: 0
  attr :link_mode, :atom, default: :patch, values: [:patch, :navigate]

  def section_nav(assigns) do
    ~H"""
    <nav class="flex items-center gap-1 border-b border-[var(--color-border)]">
      <.link
        :for={
          {label, icon, path, action} <- [
            {"All", "hero-user-group", ~p"/contacts", :index},
            {"Archived", "hero-archive-box", ~p"/contacts/archived", :archived},
            {"Duplicates", "hero-document-duplicate", ~p"/contacts/duplicates", :duplicates},
            {"Trash", "hero-trash", ~p"/contacts/trash", :trash}
          ]
        }
        patch={if @link_mode == :patch, do: path}
        navigate={if @link_mode == :navigate, do: path}
        class={[
          "inline-flex items-center gap-1.5 px-3 py-2 text-sm font-medium border-b-2 transition-colors",
          if(@active == action,
            do: "border-[var(--color-accent)] text-[var(--color-accent)]",
            else:
              "border-transparent text-[var(--color-text-secondary)] hover:text-[var(--color-text-primary)] hover:border-[var(--color-border)]"
          )
        ]}
      >
        <.icon name={icon} class="size-4" /> {label}
        <span
          :if={action == :duplicates && @pending_duplicates_count > 0}
          class="inline-flex items-center justify-center min-w-[1.25rem] h-5 px-1.5 rounded-[var(--radius-full)] bg-[var(--color-warning-subtle)] text-[var(--color-warning)] text-xs font-medium"
        >
          {@pending_duplicates_count}
        </span>
      </.link>
    </nav>
    """
  end
end
