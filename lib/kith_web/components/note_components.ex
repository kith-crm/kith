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
      <div id={@id <> "-island"} phx-update="ignore">
        <trix-toolbar id={@id <> "-toolbar"}></trix-toolbar>
        <trix-editor
          input={@id <> "-input"}
          toolbar={@id <> "-toolbar"}
          aria-label={if !@labelledby, do: "Note content"}
          aria-labelledby={@labelledby}
          class="trix-content min-h-[100px] rounded-[var(--radius-lg)] p-2 bg-[var(--color-surface-elevated)]"
        >
        </trix-editor>
      </div>
    </div>
    """
  end
end
