defmodule KithWeb.BirthdatePicker do
  @moduledoc "A contact birthdate calendar with optional year precision."
  use Phoenix.Component

  alias KithWeb.UI

  attr :field, Phoenix.HTML.FormField, required: true
  attr :year_unknown, Phoenix.HTML.FormField, required: true

  def birthdate_picker(assigns) do
    assigns =
      assigns
      |> assign(:unknown?, assigns.year_unknown.value in [true, "true"])
      |> assign(:errors, Enum.map(assigns.field.errors, &UI.translate_error/1))

    ~H"""
    <div>
      <label
        for={@field.id <> "-trigger"}
        class="block text-sm font-medium text-[var(--color-text-primary)] mb-1.5"
      >
        Birthdate
      </label>
      <div
        id={@field.id <> "-picker"}
        phx-hook="BirthdatePicker"
        phx-update="ignore"
        data-date={to_string(@field.value || "")}
        data-year-unknown={to_string(@unknown?)}
        class="birthdate-picker"
      >
        <input type="hidden" name={@field.name} value={@field.value} data-birthdate />
        <input
          type="hidden"
          name={@year_unknown.name}
          value={to_string(@unknown?)}
          data-year-unknown-input
        />
        <button
          type="button"
          id={@field.id <> "-trigger"}
          data-trigger
          aria-expanded="false"
          aria-controls={@field.id <> "-calendar"}
          class="birthdate-trigger"
        >
          <span data-label>Choose a date</span>
          <UI.icon name="hero-calendar-days" class="size-4" />
        </button>
        <label class="flex items-center gap-2 mt-3 text-sm text-[var(--color-text-secondary)] cursor-pointer">
          <input
            type="checkbox"
            checked={@unknown?}
            data-unknown
            class="rounded border-[var(--color-border)] accent-[var(--color-accent)]"
          /> Year unknown
        </label>
        <p data-help class="text-xs text-[var(--color-text-tertiary)] mt-1"></p>
        <div
          id={@field.id <> "-calendar"}
          data-calendar
          role="group"
          aria-label="Choose birthdate"
          class="birthdate-calendar"
          hidden
        >
          <div class="flex items-center gap-2 mb-3">
            <button type="button" data-prev aria-label="Previous month" class="birthdate-nav">‹</button>
            <select data-month aria-label="Birth month" class="birthdate-month"></select>
            <input
              data-year
              aria-label="Birth year"
              type="number"
              min="1"
              max="9999"
              step="1"
              placeholder="YYYY"
              class="birthdate-year"
            />
            <button type="button" data-next aria-label="Next month" class="birthdate-nav">›</button>
          </div>
          <div data-weekdays class="birthdate-grid" aria-hidden="true"></div>
          <div data-days class="birthdate-grid"></div>
          <p
            data-choose-year
            class="text-sm text-[var(--color-text-tertiary)] text-center py-6"
            hidden
          >
            Choose a year to see its calendar.
          </p>
          <p
            data-calendar-help
            class="text-xs text-[var(--color-text-tertiary)] border-t border-[var(--color-border)] mt-3 pt-3"
          >
          </p>
        </div>
        <p data-error role="alert" class="text-sm text-[var(--color-error)] mt-2" hidden></p>
        <button
          type="button"
          data-clear
          class="text-xs text-[var(--color-text-tertiary)] hover:text-[var(--color-text-primary)] mt-2"
        >Clear birthdate</button>
        <noscript><p class="text-sm text-[var(--color-text-tertiary)] mt-2">
          Enable JavaScript to choose a birthdate.
        </p></noscript>
      </div>
      <p :for={error <- @errors} class="text-sm text-[var(--color-error)] mt-2">{error}</p>
    </div>
    """
  end
end
