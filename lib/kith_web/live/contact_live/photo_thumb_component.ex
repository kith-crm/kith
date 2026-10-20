defmodule KithWeb.ContactLive.PhotoThumbComponent do
  @moduledoc """
  Renders a single contact photo thumbnail in the activity stream.

  This is a **stateful** LiveComponent on purpose. Each thumbnail gets its own
  change-tracking scope keyed by `id`, so when the parent activity stream
  re-renders (a note is added, a filter is toggled, ...) an unchanged photo's
  `<img>` is never re-diffed and the browser never re-fetches it. The
  (potentially presigned, expiring) storage URL is resolved once in `update/2`
  and only recomputed when `storage_key` actually changes.

  Four visual states:

    * `:syncing`     — external photo still importing (neutral grey placeholder)
    * `:loaded`      — the `<img>` itself
    * `:retrying`    — the first load failed; a fresh URL was requested once
      (neutral placeholder, the broken `<img>` hidden)
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
  def render(assigns) do
    assigns = assign(assigns, :c, variant_classes(assigns.variant))

    ~H"""
    <div id={@id} phx-hook="ImgFallback" data-refreshable="true" class={["group relative", @c.root]}>
      <div
        :if={@pending_sync}
        class={[
          @c.box,
          "bg-gradient-to-br from-stone-100 to-stone-200 flex-col items-center justify-center text-[var(--color-text-tertiary)]",
          @c.syncing,
          @c.gap
        ]}
      >
        <.icon name="hero-photo" class={@c.icon} />
        <span class="text-[10px]">Syncing…</span>
      </div>
      <img
        :if={!@pending_sync}
        data-fallback-img
        src={@url}
        alt={@alt}
        loading="lazy"
        class={[
          @c.box,
          "object-cover group-data-[img-failed]:hidden group-data-[img-retrying]:invisible"
        ]}
      />
      <div
        :if={!@pending_sync}
        class={[
          "hidden group-data-[img-retrying]:flex absolute inset-0",
          @c.box,
          "bg-gradient-to-br from-stone-100 to-stone-200"
        ]}
      />
      <div
        :if={!@pending_sync}
        class={[
          "hidden group-data-[img-failed]:flex",
          @c.box,
          "bg-amber-50 border border-amber-200 flex-col items-center justify-center text-amber-600",
          @c.gap
        ]}
      >
        <.icon name="hero-exclamation-triangle" class={@c.icon} />
        <span class={@c.badge_text}>Image unavailable</span>
      </div>
    </div>
    """
  end

  # One-shot refresh from ImgFallback after a load error (design B2). The reply
  # tells the hook whether a new URL is coming; with hourly-stable signing an
  # unchanged URL means retrying is pointless, so the hook shows "unavailable".
  @impl true
  def handle_event("refresh_url", _params, socket) do
    url = Storage.url(socket.assigns.storage_key)
    {:reply, %{changed: url != socket.assigns.url}, assign(socket, :url, url)}
  end

  defp variant_classes(:tile),
    do: %{
      root: "w-full h-full",
      box: "w-full h-full",
      syncing: "flex",
      gap: "gap-1",
      icon: "size-6",
      badge_text: "text-[10px] font-medium"
    }

  defp variant_classes(:timeline),
    do: %{
      root: "mt-2 inline-block",
      box: "size-[72px] rounded-lg",
      syncing: "inline-flex",
      gap: "gap-0.5",
      icon: "size-5",
      badge_text: "text-[9px] font-medium leading-tight text-center"
    }
end
