defmodule KithWeb.UI do
  @moduledoc """
  Core UI primitives for the Kith "Warm Precision" design system.

  These Level 3 function components replace the legacy `KithWeb.CoreComponents`
  module, using semantic OKLCH tokens from the design system.

  All components follow the variant pattern with string attrs for HEEx ergonomics.
  All spacing uses logical properties (ms/me/ps/pe) for RTL support.
  """

  use Phoenix.Component
  use Gettext, backend: KithWeb.Gettext

  alias Phoenix.HTML.Form
  alias Phoenix.LiveView.JS

  # ==========================================================================
  # Icon
  # ==========================================================================

  @doc """
  Renders a [Heroicon](https://heroicons.com).

  Heroicons come in three styles – outline, solid, and mini.
  By default, the outline style is used, but solid and mini may
  be applied by using the `-solid` and `-mini` suffix.

  ## Examples

      <.icon name="hero-x-mark" />
      <.icon name="hero-arrow-path" class="ms-1 size-3 motion-safe:animate-spin" />
  """
  attr :name, :string, required: true
  attr :class, :any, default: "size-4"

  def icon(%{name: "hero-" <> _} = assigns) do
    ~H"""
    <span class={[@name, @class]} />
    """
  end

  # ==========================================================================
  # Button
  # ==========================================================================

  @doc """
  Renders a button with variant styling and navigation support.

  ## Examples

      <.button>Save</.button>
      <.button variant="secondary">Cancel</.button>
      <.button variant="danger" size="sm">Delete</.button>
      <.button navigate={~p"/"}>Home</.button>
  """
  attr :variant, :string,
    default: "primary",
    values: ~w(primary secondary ghost danger outline)

  attr :size, :string, default: "md", values: ~w(sm md lg)
  attr :class, :any, default: nil

  attr :rest, :global,
    include: ~w(href navigate patch method download name value disabled form type)

  slot :inner_block, required: true

  def button(%{rest: rest} = assigns) do
    if rest[:href] || rest[:navigate] || rest[:patch] do
      ~H"""
      <.link
        class={[button_base(), button_variant(@variant), button_size(@size), @class]}
        {@rest}
      >
        {render_slot(@inner_block)}
      </.link>
      """
    else
      ~H"""
      <button
        class={[button_base(), button_variant(@variant), button_size(@size), @class]}
        {@rest}
      >
        {render_slot(@inner_block)}
      </button>
      """
    end
  end

  defp button_base do
    "inline-flex items-center justify-center gap-2 font-medium rounded-[var(--radius-md)] transition-all duration-200 ease-out cursor-pointer select-none active:scale-[0.98] disabled:opacity-50 disabled:pointer-events-none focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-[var(--color-border-focus)]"
  end

  defp button_variant("primary"),
    do:
      "bg-[var(--color-accent)] text-[var(--color-accent-foreground)] hover:bg-[var(--color-accent-hover)] shadow-sm"

  defp button_variant("secondary"),
    do:
      "bg-[var(--color-surface-elevated)] text-[var(--color-text-primary)] border border-[var(--color-border)] hover:bg-[var(--color-surface-sunken)]"

  defp button_variant("ghost"),
    do:
      "text-[var(--color-text-secondary)] hover:bg-[var(--color-surface-sunken)] hover:text-[var(--color-text-primary)]"

  defp button_variant("danger"),
    do:
      "bg-[var(--color-error)] text-[var(--color-error-foreground)] hover:bg-[var(--color-error)]/90 shadow-sm"

  defp button_variant("outline"),
    do:
      "border border-[var(--color-accent)] text-[var(--color-accent)] hover:bg-[var(--color-accent-subtle)]"

  defp button_size("sm"), do: "text-xs px-3 py-1.5 h-8"
  defp button_size("md"), do: "text-sm px-4 py-2 h-9"
  defp button_size("lg"), do: "text-base px-6 py-2.5 h-11"

  # ==========================================================================
  # Input
  # ==========================================================================

  @doc """
  Renders an input with label and error messages.

  A `Phoenix.HTML.FormField` may be passed as argument,
  which is used to retrieve the input name, id, and values.
  Otherwise all attributes may be passed explicitly.

  ## Types

  This function accepts all HTML input types, considering that:

    * You may also set `type="select"` to render a `<select>` tag

    * `type="checkbox"` is used exclusively to render boolean values

    * For live file uploads, see `Phoenix.Component.live_file_input/1`

  ## Examples

      <.input field={@form[:email]} type="email" />
      <.input name="my-input" errors={["oh no!"]} />
  """
  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :value, :any

  attr :type, :string,
    default: "text",
    values: ~w(checkbox color date datetime-local email file month number password
         search select tel text textarea time url week hidden)

  attr :field, Phoenix.HTML.FormField,
    doc: "a form field struct retrieved from the form, for example: @form[:email]"

  attr :errors, :list, default: []
  attr :checked, :boolean, doc: "the checked flag for checkbox inputs"
  attr :prompt, :string, default: nil, doc: "the prompt for select inputs"
  attr :options, :list, doc: "the options to pass to Phoenix.HTML.Form.options_for_select/2"
  attr :multiple, :boolean, default: false, doc: "the multiple flag for select inputs"
  attr :class, :any, default: nil
  attr :error_class, :any, default: nil

  attr :rest, :global,
    include:
      ~w(accept autocomplete autofocus capture cols disabled form list max maxlength min minlength
         multiple pattern placeholder readonly required rows size step)

  slot :inner_block

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(errors, &translate_error(&1)))
    |> assign_new(:name, fn ->
      if assigns.multiple, do: field.name <> "[]", else: field.name
    end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  def input(%{type: "hidden"} = assigns) do
    ~H"""
    <input type="hidden" id={@id} name={@name} value={@value} {@rest} />
    """
  end

  def input(%{type: "checkbox"} = assigns) do
    assigns =
      assign_new(assigns, :checked, fn ->
        Form.normalize_value("checkbox", assigns[:value])
      end)

    ~H"""
    <div class="flex items-start gap-3 mb-3">
      <input
        type="hidden"
        name={@name}
        value="false"
        disabled={@rest[:disabled]}
        form={@rest[:form]}
      />
      <input
        type="checkbox"
        id={@id}
        name={@name}
        value="true"
        checked={@checked}
        class={
          @class ||
            "mt-0.5 size-4 rounded-[var(--radius-sm)] border border-[var(--color-border)] text-[var(--color-accent)] focus:ring-2 focus:ring-[var(--color-border-focus)] focus:ring-offset-0 cursor-pointer accent-[var(--color-accent)]"
        }
        {@rest}
      />
      <label
        :if={@label}
        for={@id}
        class="text-sm font-medium text-[var(--color-text-primary)] cursor-pointer select-none"
      >
        {@label}
      </label>
      <.field_error :for={msg <- @errors}>{msg}</.field_error>
    </div>
    """
  end

  def input(%{type: "select"} = assigns) do
    ~H"""
    <div class="mb-3">
      <label
        :if={@label}
        for={@id}
        class="block text-sm font-medium text-[var(--color-text-primary)] mb-1.5"
      >
        {@label}
      </label>
      <select
        id={@id}
        name={@name}
        class={[
          @class || input_base(),
          @errors != [] && (@error_class || input_error())
        ]}
        multiple={@multiple}
        {@rest}
      >
        <option :if={@prompt} value="">{@prompt}</option>
        {Phoenix.HTML.Form.options_for_select(@options, @value)}
      </select>
      <.field_error :for={msg <- @errors}>{msg}</.field_error>
    </div>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <div class="mb-3">
      <label
        :if={@label}
        for={@id}
        class="block text-sm font-medium text-[var(--color-text-primary)] mb-1.5"
      >
        {@label}
      </label>
      <textarea
        id={@id}
        name={@name}
        class={[
          @class || "#{input_base()} min-h-[80px] py-2.5",
          @errors != [] && (@error_class || input_error())
        ]}
        {@rest}
      >{Form.normalize_value("textarea", @value)}</textarea>
      {render_slot(@inner_block)}
      <.field_error :for={msg <- @errors}>{msg}</.field_error>
    </div>
    """
  end

  # All other inputs: text, datetime-local, url, password, etc.
  def input(assigns) do
    ~H"""
    <div class="mb-3">
      <label
        :if={@label}
        for={@id}
        class="block text-sm font-medium text-[var(--color-text-primary)] mb-1.5"
      >
        {@label}
      </label>
      <input
        type={@type}
        name={@name}
        id={@id}
        value={Form.normalize_value(@type, @value)}
        class={[
          @class || input_base(),
          @errors != [] && (@error_class || input_error())
        ]}
        {@rest}
      />
      <.field_error :for={msg <- @errors}>{msg}</.field_error>
    </div>
    """
  end

  defp input_base do
    "w-full rounded-[var(--radius-md)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] px-3 py-2 text-sm text-[var(--color-text-primary)] placeholder:text-[var(--color-text-disabled)] focus:border-[var(--color-border-focus)] focus:outline-none focus:ring-2 focus:ring-[var(--color-border-focus)]/20 transition-colors duration-150"
  end

  defp input_error do
    "border-[var(--color-error)] focus:border-[var(--color-error)] focus:ring-[var(--color-error)]/20"
  end

  # ==========================================================================
  # Simple Form
  # ==========================================================================

  @doc """
  Renders a simple form wrapper with standard styling.
  """
  attr :for, :any, required: true, doc: "the form data structure"
  attr :as, :any, default: nil, doc: "the server side parameter to collect all input under"
  attr :rest, :global, include: ~w(autocomplete name rel action enctype method novalidate target)
  slot :inner_block, required: true
  slot :actions, doc: "the slot for form actions, such as a submit button"

  def simple_form(assigns) do
    ~H"""
    <.form :let={f} for={@for} as={@as} {@rest}>
      <div class="space-y-1">
        {render_slot(@inner_block, f)}
        <div :for={action <- @actions} class="mt-6 flex items-center justify-between gap-4">
          {render_slot(action, f)}
        </div>
      </div>
    </.form>
    """
  end

  # ==========================================================================
  # Badge
  # ==========================================================================

  @doc """
  Renders a badge/chip.

  ## Examples

      <.badge>Default</.badge>
      <.badge variant="success">Active</.badge>
      <.badge variant="warning" outlined>Pending</.badge>
  """
  attr :variant, :string,
    default: "default",
    values: ~w(default success warning error info)

  attr :outlined, :boolean, default: false
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def badge(assigns) do
    ~H"""
    <span
      class={[
        "inline-flex items-center rounded-[var(--radius-full)] px-2.5 py-0.5 text-xs font-medium",
        badge_variant(@variant, @outlined),
        @class
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </span>
    """
  end

  defp badge_variant("default", false),
    do: "bg-[var(--color-surface-sunken)] text-[var(--color-text-secondary)]"

  defp badge_variant("default", true),
    do: "border border-[var(--color-border)] text-[var(--color-text-secondary)] bg-transparent"

  defp badge_variant("success", false),
    do: "bg-[var(--color-success-subtle)] text-[var(--color-success)]"

  defp badge_variant("success", true),
    do: "border border-[var(--color-success)]/30 text-[var(--color-success)] bg-transparent"

  defp badge_variant("warning", false),
    do: "bg-[var(--color-warning-subtle)] text-[var(--color-warning)]"

  defp badge_variant("warning", true),
    do: "border border-[var(--color-warning)]/30 text-[var(--color-warning)] bg-transparent"

  defp badge_variant("error", false),
    do: "bg-[var(--color-error-subtle)] text-[var(--color-error)]"

  defp badge_variant("error", true),
    do: "border border-[var(--color-error)]/30 text-[var(--color-error)] bg-transparent"

  defp badge_variant("info", false),
    do: "bg-[var(--color-info-subtle)] text-[var(--color-info)]"

  defp badge_variant("info", true),
    do: "border border-[var(--color-info)]/30 text-[var(--color-info)] bg-transparent"

  # ==========================================================================
  # Flash
  # ==========================================================================

  @doc """
  Renders flash notices as slide-in toasts.

  ## Examples

      <.flash kind={:info} flash={@flash} />
      <.flash kind={:info} phx-mounted={show("#flash")}>Welcome Back!</.flash>
  """
  attr :id, :string, doc: "the optional id of flash container"
  attr :flash, :map, default: %{}, doc: "the map of flash messages"
  attr :title, :string, default: nil
  attr :kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup"
  attr :rest, :global
  slot :inner_block, doc: "the optional inner block that renders the flash message"

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
      role="alert"
      class={[
        "fixed top-4 end-4 z-50 w-80 sm:w-96 animate-in slide-in-from-top-2 fade-in duration-300",
        "rounded-[var(--radius-lg)] border p-4 shadow-[var(--shadow-dropdown)]",
        flash_classes(@kind)
      ]}
      {@rest}
    >
      <div class="flex items-start gap-3">
        <.icon :if={@kind == :info} name="hero-information-circle" class="size-5 shrink-0 mt-0.5" />
        <.icon :if={@kind == :error} name="hero-exclamation-circle" class="size-5 shrink-0 mt-0.5" />
        <div class="flex-1 min-w-0">
          <p :if={@title} class="text-sm font-semibold">{@title}</p>
          <p class="text-sm">{msg}</p>
        </div>
        <button
          type="button"
          class="shrink-0 cursor-pointer opacity-60 hover:opacity-100 transition-opacity"
          aria-label={gettext("close")}
        >
          <.icon name="hero-x-mark" class="size-4" />
        </button>
      </div>
    </div>
    """
  end

  defp flash_classes(:info),
    do: "bg-[var(--color-info-subtle)] border-[var(--color-info)]/20 text-[var(--color-info)]"

  defp flash_classes(:error),
    do: "bg-[var(--color-error-subtle)] border-[var(--color-error)]/20 text-[var(--color-error)]"

  # ==========================================================================
  # Header
  # ==========================================================================

  @doc """
  Renders a page header with title, optional subtitle, optional breadcrumb, and actions.

  ## Examples

      <.header>
        Page Title
        <:subtitle>Some description</:subtitle>
        <:actions><.button>Action</.button></:actions>
      </.header>
  """
  slot :inner_block, required: true
  slot :subtitle
  slot :breadcrumb
  slot :actions

  def header(assigns) do
    ~H"""
    <header class="pb-6">
      <nav :if={@breadcrumb != []} class="mb-3">
        {render_slot(@breadcrumb)}
      </nav>
      <div class={[@actions != [] && "flex items-center justify-between gap-6"]}>
        <div>
          <h1 class="text-xl font-semibold leading-snug text-[var(--color-text-primary)]">
            {render_slot(@inner_block)}
          </h1>
          <p
            :if={@subtitle != []}
            class="mt-1 text-sm text-[var(--color-text-secondary)] leading-relaxed"
          >
            {render_slot(@subtitle)}
          </p>
        </div>
        <div :if={@actions != []} class="flex-none flex items-center gap-3">
          {render_slot(@actions)}
        </div>
      </div>
    </header>
    """
  end

  # ==========================================================================
  # Table
  # ==========================================================================

  @doc """
  Renders a clean data table — no zebra stripes, subtle row hover.

  ## Examples

      <.table id="users" rows={@users}>
        <:col :let={user} label="Name">{user.name}</:col>
        <:col :let={user} label="Email">{user.email}</:col>
      </.table>
  """
  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :row_id, :any, default: nil
  attr :row_click, :any, default: nil

  attr :row_item, :any,
    default: &Function.identity/1,
    doc: "the function for mapping each row before calling the :col and :action slots"

  slot :col, required: true do
    attr :label, :string
    attr :class, :string
  end

  slot :action, doc: "the slot for showing user actions in the last table column"

  def table(assigns) do
    assigns =
      with %{rows: %Phoenix.LiveView.LiveStream{}} <- assigns do
        assign(assigns, row_id: assigns.row_id || fn {id, _item} -> id end)
      end

    ~H"""
    <div class="overflow-x-auto">
      <table class="w-full text-sm">
        <thead>
          <tr class="border-b border-[var(--color-border)]">
            <th
              :for={col <- @col}
              class="px-4 py-3 text-start text-xs font-medium uppercase tracking-wider text-[var(--color-text-tertiary)]"
            >
              {col[:label]}
            </th>
            <th :if={@action != []} class="px-4 py-3">
              <span class="sr-only">{gettext("Actions")}</span>
            </th>
          </tr>
        </thead>
        <tbody id={@id} phx-update={is_struct(@rows, Phoenix.LiveView.LiveStream) && "stream"}>
          <tr
            :for={row <- @rows}
            id={@row_id && @row_id.(row)}
            class="border-b border-[var(--color-border-subtle)] hover:bg-[var(--color-surface-sunken)] transition-colors duration-150"
          >
            <td
              :for={col <- @col}
              phx-click={@row_click && @row_click.(row)}
              class={[
                "px-4 py-3 text-[var(--color-text-primary)]",
                @row_click && "cursor-pointer",
                col[:class]
              ]}
            >
              {render_slot(col, @row_item.(row))}
            </td>
            <td :if={@action != []} class="px-4 py-3 w-0">
              <div class="flex items-center justify-end gap-3">
                <%= for action <- @action do %>
                  {render_slot(action, @row_item.(row))}
                <% end %>
              </div>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  # ==========================================================================
  # Modal
  # ==========================================================================

  @doc """
  Renders a modal with backdrop blur, scale+fade animation, and focus trap.

  ## Examples

      <.modal id="confirm-modal">
        Are you sure?
      </.modal>

  JS command to show: `show_modal("confirm-modal")`
  JS command to hide: `hide_modal("confirm-modal")`
  """
  attr :id, :string, required: true
  attr :show, :boolean, default: false
  attr :on_cancel, JS, default: %JS{}
  slot :inner_block, required: true

  def modal(assigns) do
    ~H"""
    <div
      id={@id}
      phx-mounted={@show && show_modal(@id)}
      phx-remove={hide_modal(@id)}
      data-cancel={JS.exec(@on_cancel, "phx-remove")}
      class="relative z-50 hidden"
    >
      <%!-- Backdrop --%>
      <div
        id={"#{@id}-bg"}
        class="fixed inset-0 bg-black/40 backdrop-blur-sm transition-opacity"
        aria-hidden="true"
      />
      <%!-- Container --%>
      <div
        class="fixed inset-0 overflow-y-auto"
        aria-labelledby={"#{@id}-title"}
        aria-describedby={"#{@id}-description"}
        role="dialog"
        aria-modal="true"
        tabindex="0"
      >
        <div class="flex min-h-full items-center justify-center p-4">
          <div
            id={"#{@id}-container"}
            phx-window-keydown={JS.exec("data-cancel", to: "##{@id}")}
            phx-key="escape"
            phx-click-away={JS.exec("data-cancel", to: "##{@id}")}
            class={[
              "w-full max-w-lg rounded-[var(--radius-lg)] bg-[var(--color-surface-overlay)] border border-[var(--color-border-subtle)] shadow-[var(--shadow-modal)] p-6",
              "transition-all duration-300"
            ]}
          >
            <div class="flex items-center justify-between mb-4">
              <h2 id={"#{@id}-title"} class="text-lg font-semibold text-[var(--color-text-primary)]">
              </h2>
              <button
                phx-click={JS.exec("data-cancel", to: "##{@id}")}
                type="button"
                class="rounded-[var(--radius-md)] p-1.5 text-[var(--color-text-tertiary)] hover:text-[var(--color-text-primary)] hover:bg-[var(--color-surface-sunken)] transition-colors cursor-pointer"
                aria-label={gettext("close")}
              >
                <.icon name="hero-x-mark" class="size-5" />
              </button>
            </div>
            <div id={"#{@id}-description"}>
              {render_slot(@inner_block)}
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  def show_modal(js \\ %JS{}, id) when is_binary(id) do
    js
    |> JS.show(to: "##{id}")
    |> JS.show(
      to: "##{id}-bg",
      time: 300,
      transition: {"ease-out duration-300", "opacity-0", "opacity-100"}
    )
    |> JS.show(
      to: "##{id}-container",
      time: 300,
      transition: {"ease-out duration-300", "opacity-0 scale-95", "opacity-100 scale-100"}
    )
    |> JS.add_class("overflow-hidden", to: "body")
    |> JS.focus_first(to: "##{id}-container")
  end

  def hide_modal(js \\ %JS{}, id) when is_binary(id) do
    js
    |> JS.hide(
      to: "##{id}-bg",
      time: 200,
      transition: {"ease-in duration-200", "opacity-100", "opacity-0"}
    )
    |> JS.hide(
      to: "##{id}-container",
      time: 200,
      transition: {"ease-in duration-200", "opacity-100 scale-100", "opacity-0 scale-95"}
    )
    |> JS.hide(to: "##{id}", transition: {"block", "block", "hidden"})
    |> JS.remove_class("overflow-hidden", to: "body")
    |> JS.pop_focus()
  end

  # ==========================================================================
  # Dropdown
  # ==========================================================================

  @doc """
  Renders a dropdown menu wrapper. Uses Alpine.js for open/close state.

  ## Examples

      <.dropdown id="user-menu">
        <:trigger>
          <.button variant="ghost" size="sm">Options</.button>
        </:trigger>
        <:item>Edit</:item>
        <:item>Delete</:item>
      </.dropdown>
  """
  attr :id, :string, required: true
  attr :class, :any, default: nil
  slot :trigger, required: true

  slot :item do
    attr :class, :string
  end

  def dropdown(assigns) do
    ~H"""
    <div id={@id} class={["relative inline-block", @class]} x-data="{ open: false }">
      <div x-on:click="open = !open">
        {render_slot(@trigger)}
      </div>
      <div
        x-show="open"
        x-on:click.outside="open = false"
        x-on:keydown.escape.window="open = false"
        x-transition:enter="transition ease-out duration-200"
        x-transition:enter-start="opacity-0 scale-95"
        x-transition:enter-end="opacity-100 scale-100"
        x-transition:leave="transition ease-in duration-150"
        x-transition:leave-start="opacity-100 scale-100"
        x-transition:leave-end="opacity-0 scale-95"
        class="absolute end-0 z-40 mt-2 min-w-[12rem] rounded-[var(--radius-lg)] border border-[var(--color-border)] bg-[var(--color-surface-overlay)] shadow-[var(--shadow-dropdown)] py-1"
        role="menu"
        style="display: none;"
      >
        <div
          :for={item <- @item}
          class={[
            "px-3 py-2 text-sm text-[var(--color-text-primary)] hover:bg-[var(--color-surface-sunken)] cursor-pointer transition-colors duration-150",
            item[:class]
          ]}
          role="menuitem"
          x-on:click="open = false"
        >
          {render_slot(item)}
        </div>
      </div>
    </div>
    """
  end

  # ==========================================================================
  # Tooltip
  # ==========================================================================

  @doc """
  Renders a CSS-only tooltip.

  ## Examples

      <.tooltip text="Copy to clipboard">
        <button>Copy</button>
      </.tooltip>
  """
  attr :text, :string, required: true
  attr :position, :string, default: "top", values: ~w(top bottom start end)
  slot :inner_block, required: true

  def tooltip(assigns) do
    ~H"""
    <span class="relative group/tooltip inline-flex">
      {render_slot(@inner_block)}
      <span class={[
        "pointer-events-none absolute z-50 whitespace-nowrap rounded-[var(--radius-md)] bg-[var(--color-text-primary)] px-2.5 py-1 text-xs text-[var(--color-surface)] opacity-0 group-hover/tooltip:opacity-100 transition-opacity duration-200",
        tooltip_position(@position)
      ]}>
        {@text}
      </span>
    </span>
    """
  end

  defp tooltip_position("top"), do: "bottom-full mb-2 start-1/2 -translate-x-1/2"
  defp tooltip_position("bottom"), do: "top-full mt-2 start-1/2 -translate-x-1/2"
  defp tooltip_position("start"), do: "end-full me-2 top-1/2 -translate-y-1/2"
  defp tooltip_position("end"), do: "start-full ms-2 top-1/2 -translate-y-1/2"

  # ==========================================================================
  # Skeleton
  # ==========================================================================

  @doc """
  Renders a loading placeholder with pulse animation.

  ## Examples

      <.skeleton class="h-4 w-48" />
      <.skeleton class="h-10 w-10 rounded-full" />
  """
  attr :class, :any, default: "h-4 w-full"
  attr :rest, :global

  def skeleton(assigns) do
    ~H"""
    <div
      class={["motion-safe:animate-pulse rounded-[var(--radius-md)] bg-[var(--color-border)]", @class]}
      {@rest}
    />
    """
  end

  # ==========================================================================
  # Kbd (Keyboard shortcut)
  # ==========================================================================

  @doc """
  Renders a keyboard shortcut display.

  ## Examples

      <.kbd>Cmd+K</.kbd>
      <.kbd>Esc</.kbd>
  """
  attr :class, :any, default: nil
  slot :inner_block, required: true

  def kbd(assigns) do
    ~H"""
    <kbd class={[
      "inline-flex items-center justify-center rounded-[var(--radius-sm)] border border-[var(--color-border)] bg-[var(--color-surface-sunken)] px-1.5 py-0.5 text-[10px] font-mono font-medium text-[var(--color-text-tertiary)] leading-none",
      @class
    ]}>
      {render_slot(@inner_block)}
    </kbd>
    """
  end

  # ==========================================================================
  # Separator
  # ==========================================================================

  @doc """
  Renders a horizontal rule with optional label.

  ## Examples

      <.separator />
      <.separator label="or" />
  """
  attr :label, :string, default: nil
  attr :class, :any, default: nil

  def separator(assigns) do
    ~H"""
    <div class={["relative", @class]}>
      <div class="absolute inset-0 flex items-center">
        <div class="w-full border-t border-[var(--color-border)]" />
      </div>
      <div :if={@label} class="relative flex justify-center">
        <span class="px-3 text-xs text-[var(--color-text-tertiary)] bg-[var(--color-surface)]">
          {@label}
        </span>
      </div>
    </div>
    """
  end

  # ==========================================================================
  # Tabs
  # ==========================================================================

  @doc """
  Renders underline-style tab navigation with amber active indicator.

  ## Examples

      <.tabs active="notes">
        <:tab id="notes" label="Notes" />
        <:tab id="activities" label="Activities" />
        <:tab id="photos" label="Photos" />
      </.tabs>
  """
  attr :active, :string, required: true
  attr :class, :any, default: nil
  attr :rest, :global

  slot :tab, required: true do
    attr :id, :string, required: true
    attr :label, :string, required: true
    attr :icon, :string
    attr :count, :integer
  end

  def tabs(assigns) do
    ~H"""
    <div class={["border-b border-[var(--color-border)]", @class]} role="tablist" {@rest}>
      <nav class="flex gap-6 -mb-px">
        <button
          :for={tab <- @tab}
          role="tab"
          aria-selected={to_string(tab.id == @active)}
          phx-click="switch_tab"
          phx-value-tab={tab.id}
          class={[
            "inline-flex items-center gap-2 py-3 text-sm font-medium border-b-2 transition-colors duration-200 cursor-pointer",
            tab.id == @active &&
              "border-[var(--color-accent)] text-[var(--color-accent)]",
            tab.id != @active &&
              "border-transparent text-[var(--color-text-tertiary)] hover:text-[var(--color-text-primary)] hover:border-[var(--color-border)]"
          ]}
        >
          <.icon :if={tab[:icon]} name={tab[:icon]} class="size-4" />
          {tab.label}
          <span
            :if={tab[:count]}
            class={[
              "rounded-[var(--radius-full)] px-1.5 py-0.5 text-[10px] leading-none font-medium",
              tab.id == @active && "bg-[var(--color-accent-subtle)] text-[var(--color-accent)]",
              tab.id != @active &&
                "bg-[var(--color-surface-sunken)] text-[var(--color-text-tertiary)]"
            ]}
          >
            {tab.count}
          </span>
        </button>
      </nav>
    </div>
    """
  end

  # ==========================================================================
  # Card
  # ==========================================================================

  @doc """
  Renders an elevated card surface.

  ## Examples

      <.card>
        <:header>Card Title</:header>
        Content here.
        <:footer>Footer</:footer>
      </.card>
  """
  attr :id, :string, default: nil
  attr :class, :any, default: nil
  attr :rest, :global
  slot :header
  slot :inner_block, required: true
  slot :footer

  def card(assigns) do
    ~H"""
    <div
      id={@id}
      class={[
        "rounded-[var(--radius-lg)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] shadow-[var(--shadow-card)]",
        @class
      ]}
      {@rest}
    >
      <div :if={@header != []} class="px-5 py-4 border-b border-[var(--color-border-subtle)]">
        <div class="font-semibold text-[var(--color-text-primary)]">
          {render_slot(@header)}
        </div>
      </div>
      <div class="px-5 py-4">
        {render_slot(@inner_block)}
      </div>
      <div :if={@footer != []} class="px-5 py-4 border-t border-[var(--color-border-subtle)]">
        {render_slot(@footer)}
      </div>
    </div>
    """
  end

  # ==========================================================================
  # List (data display)
  # ==========================================================================

  @doc """
  Renders a data list.

  ## Examples

      <.list>
        <:item title="Title">{@post.title}</:item>
        <:item title="Views">{@post.views}</:item>
      </.list>
  """
  slot :item, required: true do
    attr :title, :string, required: true
  end

  def list(assigns) do
    ~H"""
    <dl class="divide-y divide-[var(--color-border-subtle)]">
      <div :for={item <- @item} class="flex gap-4 py-3">
        <dt class="w-1/4 shrink-0 text-sm font-medium text-[var(--color-text-tertiary)]">
          {item.title}
        </dt>
        <dd class="text-sm text-[var(--color-text-primary)]">
          {render_slot(item)}
        </dd>
      </div>
    </dl>
    """
  end

  # ==========================================================================
  # JS Helpers
  # ==========================================================================

  def show(js \\ %JS{}, selector) do
    JS.show(js,
      to: selector,
      time: 300,
      transition:
        {"transition-all ease-out duration-300",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95",
         "opacity-100 translate-y-0 sm:scale-100"}
    )
  end

  def hide(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      time: 200,
      transition:
        {"transition-all ease-in duration-200", "opacity-100 translate-y-0 sm:scale-100",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95"}
    )
  end

  # ==========================================================================
  # Error helpers
  # ==========================================================================

  @doc false
  defp field_error(assigns) do
    ~H"""
    <p class="mt-1.5 flex items-center gap-1.5 text-xs text-[var(--color-error)]">
      <.icon name="hero-exclamation-circle-mini" class="size-4 shrink-0" />
      {render_slot(@inner_block)}
    </p>
    """
  end

  @doc """
  Translates an error message using gettext.
  """
  def translate_error({msg, opts}) do
    if count = opts[:count] do
      Gettext.dngettext(KithWeb.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(KithWeb.Gettext, "errors", msg, opts)
    end
  end

  @doc """
  Translates the errors for a field from a keyword list of errors.
  """
  def translate_errors(errors, field) when is_list(errors) do
    for {^field, {msg, opts}} <- errors, do: translate_error({msg, opts})
  end

  # ==========================================================================
  # Timeline Components
  # ==========================================================================

  @type_colors %{
    note: %{dot: "bg-amber-600", badge_bg: "bg-amber-50", badge_text: "text-amber-800"},
    call: %{dot: "bg-blue-500", badge_bg: "bg-blue-50", badge_text: "text-blue-800"},
    life_event: %{
      dot: "bg-emerald-500",
      badge_bg: "bg-emerald-50",
      badge_text: "text-emerald-800"
    },
    activity: %{dot: "bg-teal-500", badge_bg: "bg-teal-50", badge_text: "text-teal-800"},
    task: %{dot: "bg-violet-500", badge_bg: "bg-violet-50", badge_text: "text-violet-800"},
    gift: %{dot: "bg-rose-500", badge_bg: "bg-rose-50", badge_text: "text-rose-800"},
    photo: %{dot: "bg-indigo-500", badge_bg: "bg-indigo-50", badge_text: "text-indigo-800"},
    conversation: %{dot: "bg-pink-500", badge_bg: "bg-pink-50", badge_text: "text-pink-800"}
  }

  @doc """
  Renders a colored dot for the activity timeline.

  ## Attributes

    * `:type` - atom, the entry type (e.g. `:note`, `:call`)
  """
  attr :type, :atom, required: true

  def timeline_dot(assigns) do
    colors = Map.get(@type_colors, assigns.type, %{dot: "bg-stone-400"})
    assigns = assign(assigns, :dot_class, colors.dot)

    ~H"""
    <div class={[
      "absolute -start-[21px] top-[16px] size-3.5 rounded-full",
      "border-[2.5px] border-[var(--color-surface)]",
      "shadow-[0_0_0_1px_var(--color-border-subtle)]",
      @dot_class
    ]} />
    """
  end

  @doc """
  Renders a colored badge for an activity entry type.

  ## Attributes

    * `:type` - atom, the entry type (e.g. `:note`, `:call`)
  """
  attr :type, :atom, required: true

  def type_badge(assigns) do
    colors =
      Map.get(@type_colors, assigns.type, %{
        badge_bg: "bg-stone-100",
        badge_text: "text-stone-600"
      })

    label = type_label(assigns.type)

    assigns =
      assign(assigns, badge_bg: colors.badge_bg, badge_text: colors.badge_text, label: label)

    ~H"""
    <span class={[
      "inline-flex items-center px-2 py-0.5 rounded text-[10px] font-medium",
      @badge_bg,
      @badge_text
    ]}>
      {@label}
    </span>
    """
  end

  defp type_label(:note), do: "Note"
  defp type_label(:call), do: "Call"
  defp type_label(:life_event), do: "Life Event"
  defp type_label(:activity), do: "Activity"
  defp type_label(:task), do: "Task"
  defp type_label(:gift), do: "Gift"
  defp type_label(:photo), do: "Photo"
  defp type_label(:conversation), do: "Conversation"
  defp type_label(_), do: "Entry"

  @doc """
  Renders a multi-select filter dropdown for the activity stream.

  Uses Alpine.js for open/close state and selection management.

  ## Attributes

    * `:active_filters` - MapSet of active filter type atoms
    * `:all_types` - list of all available type atoms
  """
  attr :active_filters, :any, required: true
  attr :all_types, :list, required: true
  attr :target, :any, default: nil

  def filter_dropdown(assigns) do
    assigns = assign(assigns, :type_colors, @type_colors)

    ~H"""
    <div x-data="{ open: false }" class="relative">
      <button
        @click="open = !open"
        class={[
          "inline-flex items-center gap-1.5 rounded-lg border px-3 py-1.5 text-xs",
          "border-[var(--color-border)] text-[var(--color-text-secondary)]",
          "hover:bg-[var(--color-surface-elevated)] transition-colors duration-200"
        ]}
      >
        <.icon name="hero-funnel-mini" class="size-3 opacity-50" /> Filter
        <span
          :if={MapSet.size(@active_filters) > 0}
          class="bg-[var(--color-accent)] text-white text-[10px] rounded-full size-4 inline-flex items-center justify-center"
        >
          {MapSet.size(@active_filters)}
        </span>
      </button>

      <%!-- Dropdown panel --%>
      <div
        x-show="open"
        x-transition
        @click.outside="open = false"
        class={[
          "absolute start-0 top-full mt-1 z-10 w-52 rounded-lg",
          "bg-[var(--color-surface-elevated)] border border-[var(--color-border)]",
          "shadow-[var(--shadow-dropdown)]"
        ]}
      >
        <div class="p-1">
          <button
            :for={type <- @all_types}
            phx-click="filter-toggle"
            phx-value-type={type}
            phx-target={@target}
            class={[
              "flex w-full items-center gap-2 rounded-md px-2.5 py-1.5 text-xs",
              "hover:bg-[var(--color-surface)] transition-colors duration-150",
              if(MapSet.member?(@active_filters, type), do: "bg-[var(--color-surface)]", else: "")
            ]}
          >
            <span class={[
              "size-3.5 rounded border flex items-center justify-center text-[9px]",
              if(MapSet.member?(@active_filters, type),
                do: "border-[var(--color-accent)] bg-[var(--color-accent)] text-white",
                else: "border-[var(--color-border)]"
              )
            ]}>
              <span :if={MapSet.member?(@active_filters, type)}>&#10003;</span>
            </span>
            <.type_badge type={type} />
          </button>
        </div>
        <div
          :if={MapSet.size(@active_filters) > 0}
          class="border-t border-[var(--color-border-subtle)] p-1"
        >
          <button
            phx-click="filter-clear"
            phx-target={@target}
            class="w-full rounded-md px-2.5 py-1.5 text-xs text-[var(--color-text-tertiary)] hover:text-[var(--color-text-secondary)] text-start"
          >
            Clear all
          </button>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Renders removable filter chips for active filters.

  ## Attributes

    * `:active_filters` - MapSet of active filter type atoms
  """
  attr :active_filters, :any, required: true
  attr :target, :any, default: nil

  def filter_chips(assigns) do
    ~H"""
    <div :if={MapSet.size(@active_filters) > 0} class="flex flex-wrap items-center gap-1.5">
      <span
        :for={type <- MapSet.to_list(@active_filters)}
        class="inline-flex items-center gap-1 rounded-md bg-[var(--color-surface)] px-2 py-1 text-[10px] font-medium text-[var(--color-text-secondary)]"
      >
        <.type_badge type={type} />
        <button
          phx-click="filter-toggle"
          phx-value-type={type}
          phx-target={@target}
          class="opacity-50 hover:opacity-100"
        >
          &times;
        </button>
      </span>
      <button
        phx-click="filter-clear"
        phx-target={@target}
        class="text-[10px] text-[var(--color-text-tertiary)] hover:text-[var(--color-text-secondary)]"
      >
        Clear all
      </button>
    </div>
    """
  end
end
