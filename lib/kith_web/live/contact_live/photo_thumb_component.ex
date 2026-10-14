defmodule KithWeb.ContactLive.PhotoThumbComponent do
  @moduledoc """
  Renders a single contact photo thumbnail in the activity stream.

  This is a **stateful** LiveComponent on purpose. Each thumbnail gets its own
  change-tracking scope keyed by `id`, so when the parent activity stream
  re-renders (a note is added, a filter is toggled, ...) an unchanged photo's
  `<img>` is never re-diffed and the browser never re-fetches it. The
  (potentially presigned, expiring) storage URL is resolved once in `update/2`
  and only recomputed when `storage_key` actually changes.

  Three visual states:

    * `:syncing`     — external photo still importing (neutral grey placeholder)
    * `:loaded`      — the `<img>` itself
    * `:unavailable` — the image 404'd / failed to load; a distinct amber
      "Image unavailable" badge swapped in by the `ImgFallback` JS hook, so the
      user can tell a missing file apart from a transient render glitch.
  """
  use KithWeb, :live_component

  alias Kith.Storage

  @impl true
  def update(assigns, socket) do
    prev_key = socket.assigns[:storage_key]
    socket = assign(socket, assigns)

    socket =
      cond do
        socket.assigns.pending_sync ->
          assign(socket, :url, nil)

        is_nil(socket.assigns[:url]) or socket.assigns.storage_key != prev_key ->
          assign(socket, :url, Storage.url(socket.assigns.storage_key))

        true ->
          socket
      end

    {:ok, socket}
  end

  @impl true
  def render(%{variant: :tile} = assigns) do
    ~H"""
    <div id={@id} phx-hook="ImgFallback" class="group w-full h-full">
      <div
        :if={@pending_sync}
        class="w-full h-full bg-gradient-to-br from-stone-100 to-stone-200 flex flex-col items-center justify-center gap-1 text-[var(--color-text-tertiary)]"
      >
        <.icon name="hero-photo" class="size-6" />
        <span class="text-[10px]">Syncing…</span>
      </div>
      <img
        :if={!@pending_sync}
        data-fallback-img
        src={@url}
        alt={@alt}
        loading="lazy"
        class="w-full h-full object-cover group-data-[img-failed]:hidden"
      />
      <div
        :if={!@pending_sync}
        class="hidden group-data-[img-failed]:flex w-full h-full bg-amber-50 border border-amber-200 flex-col items-center justify-center gap-1 text-amber-600"
      >
        <.icon name="hero-exclamation-triangle" class="size-6" />
        <span class="text-[10px] font-medium">Image unavailable</span>
      </div>
    </div>
    """
  end

  def render(%{variant: :timeline} = assigns) do
    ~H"""
    <div id={@id} phx-hook="ImgFallback" class="group mt-2 inline-block">
      <div
        :if={@pending_sync}
        class="size-[72px] rounded-lg bg-gradient-to-br from-stone-100 to-stone-200 inline-flex flex-col items-center justify-center gap-0.5 text-[var(--color-text-tertiary)]"
      >
        <.icon name="hero-photo" class="size-5" />
        <span class="text-[10px]">Syncing…</span>
      </div>
      <img
        :if={!@pending_sync}
        data-fallback-img
        src={@url}
        alt={@alt}
        loading="lazy"
        class="size-[72px] rounded-lg object-cover group-data-[img-failed]:hidden"
      />
      <div
        :if={!@pending_sync}
        class="hidden group-data-[img-failed]:flex size-[72px] rounded-lg bg-amber-50 border border-amber-200 flex-col items-center justify-center gap-0.5 text-amber-600"
      >
        <.icon name="hero-exclamation-triangle" class="size-5" />
        <span class="text-[9px] font-medium leading-tight text-center">Image unavailable</span>
      </div>
    </div>
    """
  end
end
