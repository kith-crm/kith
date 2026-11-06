defmodule KithWeb.NoteComponents do
  @moduledoc "Shared sanitized note display and Trix editor."
  use KithWeb, :html

  attr :body, :string, required: true

  def note_body(assigns) do
    ~H"""
    <div class="trix-content note-body">
      {Kith.RichText.render(Kith.Contacts.Note.render_body(@body))}
    </div>
    """
  end

  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :value, :string, required: true

  attr :labelledby, :string, default: nil

  def note_editor(assigns) do
    ~H"""
    <div id={@id} phx-hook="TrixEditor" data-value={@value} data-input={@name}>
      <input id={@id <> "-input"} type="hidden" name={@name} value={@value} />
      <div id={@id <> "-island"} class="note-editor" phx-update="ignore">
        <.note_toolbar id={@id <> "-toolbar"} />
        <trix-editor
          input={@id <> "-input"}
          toolbar={@id <> "-toolbar"}
          aria-label={if !@labelledby, do: gettext("Note content")}
          aria-labelledby={@labelledby}
          class="trix-content min-h-[180px] rounded-[var(--radius-lg)] p-2 bg-[var(--color-surface-elevated)]"
        >
        </trix-editor>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true

  defp note_toolbar(assigns) do
    ~H"""
    <trix-toolbar id={@id}>
      <div class="note-toolbar-row" role="group" aria-label={gettext("Note formatting")}>
        <span class="note-toolbar-group">
          <button
            type="button"
            class="note-toolbar-button"
            data-trix-attribute="bold"
            aria-pressed="false"
            data-trix-key="b"
            title={gettext("Bold")}
            aria-label={gettext("Bold")}
          >
            <svg
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              stroke-width="1.7"
              stroke-linecap="round"
              stroke-linejoin="round"
              aria-hidden="true"
            ><path d="M7 4h6a4 4 0 0 1 0 8H7zm0 8h7a4 4 0 0 1 0 8H7z" /></svg>
          </button>
          <button
            type="button"
            class="note-toolbar-button"
            data-trix-attribute="italic"
            aria-pressed="false"
            data-trix-key="i"
            title={gettext("Italic")}
            aria-label={gettext("Italic")}
          >
            <svg
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              stroke-width="1.7"
              stroke-linecap="round"
              stroke-linejoin="round"
              aria-hidden="true"
            ><path d="M10 4h9M5 20h9M15 4 9 20" /></svg>
          </button>
          <button
            type="button"
            class="note-toolbar-button"
            data-trix-attribute="strike"
            aria-pressed="false"
            title={gettext("Strikethrough")}
            aria-label={gettext("Strikethrough")}
          >
            <svg
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              stroke-width="1.7"
              stroke-linecap="round"
              stroke-linejoin="round"
              aria-hidden="true"
            ><path d="M17 6c-1-2-8-3-9 1-.5 2 1 3 4 4M7 18c2 3 10 3 10-2M4 12h16" /></svg>
          </button>
          <button
            type="button"
            class="note-toolbar-button"
            data-trix-attribute="href"
            data-trix-action="link"
            aria-expanded="false"
            data-trix-key="k"
            title={gettext("Link")}
            aria-label={gettext("Link")}
          >
            <svg
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              stroke-width="1.7"
              stroke-linecap="round"
              stroke-linejoin="round"
              aria-hidden="true"
            ><path
              d="m10 13 4-4m-6 6-2 2a4 4 0 0 1-6-6l4-4m12 2 2-2a4 4 0 0 0-6-6l-4 4"
              transform="translate(2 2) scale(.85)"
            /></svg>
          </button>
        </span>
        <span class="note-toolbar-group">
          <button
            type="button"
            class="note-toolbar-button"
            data-trix-attribute="heading1"
            aria-pressed="false"
            title={gettext("Heading")}
            aria-label={gettext("Heading")}
          >
            <svg
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              stroke-width="1.7"
              stroke-linecap="round"
              stroke-linejoin="round"
              aria-hidden="true"
            ><path d="M5 5v14M17 5v14M5 12h12" /></svg>
          </button>
          <button
            type="button"
            class="note-toolbar-button"
            data-trix-attribute="quote"
            aria-pressed="false"
            title={gettext("Quote")}
            aria-label={gettext("Quote")}
          >
            <svg
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              stroke-width="1.7"
              stroke-linecap="round"
              stroke-linejoin="round"
              aria-hidden="true"
            ><path d="M5 7h5v7H5zm9 0h5v7h-5zM10 14c0 3-2 4-4 4m13-4c0 3-2 4-4 4" /></svg>
          </button>
          <button
            type="button"
            class="note-toolbar-button"
            data-trix-attribute="code"
            aria-pressed="false"
            title={gettext("Code block")}
            aria-label={gettext("Code block")}
          >
            <svg
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              stroke-width="1.7"
              stroke-linecap="round"
              stroke-linejoin="round"
              aria-hidden="true"
            ><path d="m8 7-5 5 5 5m8-10 5 5-5 5M14 4l-4 16" /></svg>
          </button>
        </span>
        <span class="note-toolbar-group">
          <button
            type="button"
            class="note-toolbar-button"
            data-trix-attribute="bullet"
            aria-pressed="false"
            title={gettext("Bulleted list")}
            aria-label={gettext("Bulleted list")}
          >
            <svg
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              stroke-width="1.7"
              stroke-linecap="round"
              stroke-linejoin="round"
              aria-hidden="true"
            ><path d="M10 6h10M10 12h10M10 18h10" /><circle cx="4" cy="6" r=".8" /><circle
              cx="4"
              cy="12"
              r=".8"
            /><circle cx="4" cy="18" r=".8" /></svg>
          </button>
          <button
            type="button"
            class="note-toolbar-button"
            data-trix-attribute="number"
            aria-pressed="false"
            title={gettext("Numbered list")}
            aria-label={gettext("Numbered list")}
          >
            <svg
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              stroke-width="1.7"
              stroke-linecap="round"
              stroke-linejoin="round"
              aria-hidden="true"
            ><path d="M10 6h10M10 12h10M10 18h10M3 4h1v4M2 12c2-3 4 0 1 2l-1 1h3M2 18h2l-1 2h2" /></svg>
          </button>
          <button
            type="button"
            class="note-toolbar-button"
            data-trix-action="decreaseNestingLevel"
            title={gettext("Decrease indent")}
            aria-label={gettext("Decrease indent")}
          >
            <svg
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              stroke-width="1.7"
              stroke-linecap="round"
              stroke-linejoin="round"
              aria-hidden="true"
            ><path d="M10 5h10M10 10h10M10 15h10M4 20h16M6 7l-4 4 4 4" /></svg>
          </button>
          <button
            type="button"
            class="note-toolbar-button"
            data-trix-action="increaseNestingLevel"
            title={gettext("Increase indent")}
            aria-label={gettext("Increase indent")}
          >
            <svg
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              stroke-width="1.7"
              stroke-linecap="round"
              stroke-linejoin="round"
              aria-hidden="true"
            ><path d="M10 5h10M10 10h10M10 15h10M4 20h16M2 7l4 4-4 4" /></svg>
          </button>
        </span>
        <span class="note-toolbar-group">
          <button
            type="button"
            class="note-toolbar-button"
            data-trix-action="undo"
            data-trix-key="z"
            title={gettext("Undo")}
            aria-label={gettext("Undo")}
          >
            <svg
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              stroke-width="1.7"
              stroke-linecap="round"
              stroke-linejoin="round"
              aria-hidden="true"
            ><path d="M4 10h10a6 6 0 0 1 0 12M4 10l5-5M4 10l5 5" transform="translate(0 -2)" /></svg>
          </button>
          <button
            type="button"
            class="note-toolbar-button"
            data-trix-action="redo"
            data-trix-key="shift+z"
            title={gettext("Redo")}
            aria-label={gettext("Redo")}
          >
            <svg
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              stroke-width="1.7"
              stroke-linecap="round"
              stroke-linejoin="round"
              aria-hidden="true"
            ><path d="M20 10H10a6 6 0 0 0 0 12m10-12-5-5m5 5-5 5" transform="translate(0 -2)" /></svg>
          </button>
        </span>
      </div>
      <div class="trix-dialogs" data-trix-dialogs>
        <div
          class="trix-dialog trix-dialog--link"
          data-trix-dialog="href"
          data-trix-dialog-attribute="href"
        >
          <label for={@id <> "-url"} class="note-link-label">{gettext("Link URL")}</label>
          <div class="trix-dialog__link-fields">
            <input
              id={@id <> "-url"}
              type="url"
              name="href"
              class="trix-input trix-input--dialog"
              placeholder="https://example.com"
              data-trix-validate-href
              required
              data-trix-input
            />
            <div class="note-link-actions">
              <input
                type="button"
                class="trix-button trix-button--dialog"
                value={gettext("Apply link")}
                data-trix-method="setAttribute"
              />
              <input
                type="button"
                class="trix-button trix-button--dialog"
                value={gettext("Remove link")}
                data-trix-method="removeAttribute"
              />
            </div>
          </div>
        </div>
      </div>
    </trix-toolbar>
    """
  end
end
