defmodule KithWeb.AvatarComponents do
  @moduledoc "Presentation components for selecting and cropping contact avatars."
  use KithWeb, :html

  attr :source, :string, default: nil
  attr :file_input, :string, required: true
  attr :entries, :list, required: true
  attr :upload, :boolean, required: true

  def crop_dialog(assigns) do
    upload_complete = not Enum.any?(assigns.entries, &(&1.progress < 100))

    assigns =
      assigns
      |> assign(:upload_complete, upload_complete)
      |> assign(:uploading, assigns.upload and not upload_complete)
      |> assign(:progress, Enum.map_join(assigns.entries, ", ", &"#{&1.progress}%"))

    ~H"""
    <div
      id="avatar-crop-dialog"
      role="dialog"
      aria-modal="true"
      aria-labelledby="avatar-crop-title"
      phx-window-keydown="cancel-avatar-crop"
      phx-key="Escape"
      class="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-4"
    >
      <form
        id="avatar-crop-form"
        phx-submit="upload-avatar"
        class="w-full max-w-lg rounded-[var(--radius-lg)] bg-[var(--color-surface)] p-5 shadow-xl"
      >
        <h2 id="avatar-crop-title" class="text-lg font-semibold">Crop contact avatar</h2>
        <p class="text-sm text-[var(--color-text-secondary)] my-2">
          Drag to position your photo. Use the zoom controls or arrow keys to adjust it.
        </p>
        <div
          id="avatar-crop-editor"
          phx-hook="AvatarCropper"
          data-source={@source}
          data-file-input={@file_input}
          data-upload-complete={to_string(@upload_complete)}
        >
          <div
            id="avatar-crop-canvas"
            phx-update="ignore"
            class="h-72 overflow-hidden bg-black/10"
          >
            <img id="avatar-crop-image" alt="Avatar crop preview" class="block max-w-full" />
          </div>
          <input
            :for={field <- ~w(x y width height)}
            type="hidden"
            name={"crop[#{field}]"}
            data-crop-field={field}
          />
          <div class="flex items-center gap-2 mt-3">
            <button
              type="button"
              data-crop-zoom="-0.1"
              aria-label="Zoom out"
              class="rounded border px-3 py-2"
            >
              −
            </button>
            <button
              type="button"
              data-crop-zoom="0.1"
              aria-label="Zoom in"
              class="rounded border px-3 py-2"
            >
              +
            </button>
            <button type="button" data-crop-reset class="rounded border px-3 py-2">
              Reset crop
            </button>
          </div>
          <p data-crop-error role="alert" class="text-sm text-red-600 mt-2"></p>
        </div>
        <p
          :if={@uploading}
          role="status"
          class="text-sm text-[var(--color-text-secondary)] mt-2"
        >
          Uploading image… {@progress}
        </p>
        <div class="flex justify-end gap-2 mt-4">
          <button type="button" phx-click="cancel-avatar-crop" class="rounded border px-4 py-2">
            Cancel
          </button>
          <button
            id="save-avatar-crop"
            type="submit"
            disabled={@uploading}
            phx-disable-with="Saving…"
            class="rounded bg-[var(--color-accent)] text-[var(--color-accent-foreground)] px-4 py-2 disabled:opacity-50"
          >
            Save avatar
          </button>
        </div>
      </form>
    </div>
    """
  end
end
