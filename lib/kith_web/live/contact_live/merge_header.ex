defmodule KithWeb.ContactLive.MergeHeader do
  @moduledoc """
  Header and Contacts navigation for the cluster merge screen.
  Manual merges link back to Contacts; detected clusters link to Duplicates.
  """

  use KithWeb, :html

  alias KithWeb.ContactLive.SectionNav

  attr :synthetic?, :boolean, required: true
  attr :pending_duplicates_count, :integer, required: true

  def merge_header(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto space-y-4 mb-4">
      <.link
        navigate={if @synthetic?, do: ~p"/contacts", else: ~p"/contacts/duplicates"}
        class="inline-flex items-center gap-1.5 text-sm text-[var(--color-text-secondary)] hover:text-[var(--color-text-primary)]"
      >
        <.icon name="hero-arrow-left" class="size-4" />
        {if @synthetic?, do: "Back to contacts", else: "Back to duplicates"}
      </.link>
      <h1 class="text-2xl font-semibold text-[var(--color-text-primary)] tracking-tight">
        Merge duplicates
      </h1>
      <SectionNav.section_nav
        active={if @synthetic?, do: :index, else: :duplicates}
        pending_duplicates_count={@pending_duplicates_count}
        link_mode={:navigate}
      />
    </div>
    """
  end
end
