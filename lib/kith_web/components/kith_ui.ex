defmodule KithWeb.KithUI do
  @moduledoc """
  Domain-specific UI components for the Kith "Warm Precision" design system.

  These Level 3 function components replace the legacy `KithWeb.KithComponents`
  module, using semantic OKLCH tokens. They build on `KithWeb.UI` primitives
  and provide Kith-specific elements like avatars, contact badges, stat cards,
  and reminder rows.
  """

  use Phoenix.Component
  import KithWeb.UI

  alias Kith.Cldr.DateTime.Relative

  @doc "Resolves a contact's avatar storage key to a display URL. Returns nil if no avatar."
  def avatar_url(nil), do: nil
  def avatar_url(%{avatar: nil}), do: nil
  def avatar_url(%{avatar: key}), do: Kith.Storage.url(key)

  # ==========================================================================
  # Helpers
  # ==========================================================================

  @avatar_colors ~w(
    bg-red-500 bg-orange-500 bg-amber-500 bg-yellow-500 bg-lime-500
    bg-green-500 bg-emerald-500 bg-teal-500 bg-cyan-500 bg-sky-500
    bg-blue-500 bg-indigo-500 bg-violet-500 bg-purple-500 bg-fuchsia-500
    bg-pink-500 bg-rose-500
  )

  @doc false
  def name_to_color(nil), do: Enum.at(@avatar_colors, 0)
  def name_to_color(""), do: Enum.at(@avatar_colors, 0)

  def name_to_color(name) do
    index =
      name
      |> String.to_charlist()
      |> Enum.sum()
      |> rem(length(@avatar_colors))

    Enum.at(@avatar_colors, index)
  end

  @doc false
  def initials(nil), do: "?"
  def initials(""), do: "?"

  def initials(name) do
    parts =
      name
      |> String.trim()
      |> String.split(~r/\s+/, trim: true)

    case parts do
      [] ->
        "?"

      [single] ->
        single |> String.upcase() |> String.slice(0, 2)

      [first | rest] ->
        last = List.last(rest)
        (String.at(first, 0) |> String.upcase()) <> (String.at(last, 0) |> String.upcase())
    end
  end

  defp avatar_size_classes(:sm), do: "size-8 text-xs"
  defp avatar_size_classes(:md), do: "size-10 text-sm"
  defp avatar_size_classes(:lg), do: "size-14 text-base"
  defp avatar_size_classes(:xl), do: "size-20 text-xl"
  defp avatar_size_classes(_), do: avatar_size_classes(:md)

  defp tag_color(nil, name), do: name_to_color(name || "")

  defp tag_color(color, _name) do
    "bg-#{color}-100 text-#{color}-800 dark:bg-#{color}-900 dark:text-#{color}-200"
  end

  defp role_classes("admin"),
    do: "bg-[var(--color-error-subtle)] text-[var(--color-error)]"

  defp role_classes("editor"),
    do: "bg-[var(--color-info-subtle)] text-[var(--color-info)]"

  defp role_classes("viewer"),
    do: "bg-[var(--color-surface-sunken)] text-[var(--color-text-secondary)]"

  defp role_classes(_),
    do: "bg-[var(--color-surface-sunken)] text-[var(--color-text-secondary)]"

  defp emotion_classes(emotion) when is_binary(emotion) do
    case String.downcase(emotion) do
      "love" -> "bg-pink-100 text-pink-800 dark:bg-pink-900/30 dark:text-pink-300"
      "happy" -> "bg-[var(--color-warning-subtle)] text-[var(--color-warning)]"
      "grateful" -> "bg-[var(--color-success-subtle)] text-[var(--color-success)]"
      "sad" -> "bg-[var(--color-info-subtle)] text-[var(--color-info)]"
      "angry" -> "bg-[var(--color-error-subtle)] text-[var(--color-error)]"
      "anxious" -> "bg-orange-100 text-orange-800 dark:bg-orange-900/30 dark:text-orange-300"
      "neutral" -> "bg-[var(--color-surface-sunken)] text-[var(--color-text-secondary)]"
      _ -> "bg-purple-100 text-purple-800 dark:bg-purple-900/30 dark:text-purple-300"
    end
  end

  defp reminder_icon_name(%{type: "birthday"}), do: "hero-cake"
  defp reminder_icon_name(%{type: "anniversary"}), do: "hero-heart"
  defp reminder_icon_name(%{type: "call"}), do: "hero-phone"
  defp reminder_icon_name(%{type: "email"}), do: "hero-envelope"
  defp reminder_icon_name(%{type: "meeting"}), do: "hero-calendar-days"
  defp reminder_icon_name(_), do: "hero-bell"

  defp format_reminder_date(%{date: date}, locale) do
    case Kith.Cldr.Date.to_string(date, locale: locale, format: :medium) do
      {:ok, formatted} -> formatted
      _ -> to_string(date)
    end
  end

  defp format_reminder_date(_, _locale), do: ""

  # ==========================================================================
  # Avatar
  # ==========================================================================

  @doc """
  Renders a contact/user avatar with initials fallback and warm color ring on hover.

  ## Examples

      <.avatar name="John Doe" />
      <.avatar id="avatar-1" src="/images/avatar.jpg" name="John Doe" size={:lg} />
  """
  attr :id, :string,
    default: nil,
    doc: "required when `src` is set: the ImgFallback hook needs a unique DOM id"

  attr :src, :string, default: nil
  attr :name, :string, default: nil
  attr :size, :atom, default: :md, values: [:sm, :md, :lg, :xl]
  attr :class, :string, default: nil

  def avatar(assigns) do
    if assigns.src && is_nil(assigns.id),
      do: raise(ArgumentError, "KithUI.avatar/1 needs an :id when :src is set")

    assigns =
      assigns
      |> assign(:initials_text, initials(assigns.name))
      |> assign(:bg_color, name_to_color(assigns.name))
      |> assign(:size_classes, avatar_size_classes(assigns.size))

    ~H"""
    <div
      id={@id}
      phx-hook={@src && "ImgFallback"}
      class={[
        "group inline-flex items-center justify-center rounded-full shrink-0 font-semibold text-white select-none ring-0 hover:ring-2 ring-[var(--color-accent)]/30 transition-shadow duration-200",
        @size_classes,
        !@src && @bg_color,
        @class
      ]}
    >
      <img
        :if={@src}
        data-fallback-img
        src={@src}
        alt={@name || "Avatar"}
        class={["rounded-full object-cover group-data-[img-failed]:hidden", @size_classes]}
      />
      <span
        :if={@src}
        class={[
          "hidden group-data-[img-failed]:inline-flex items-center justify-center rounded-full",
          @size_classes,
          @bg_color
        ]}
      >
        {@initials_text}
      </span>
      <span :if={!@src}>{@initials_text}</span>
    </div>
    """
  end

  # ==========================================================================
  # Contact Badge
  # ==========================================================================

  @doc """
  Renders an avatar + name chip that links to a contact profile.

  ## Examples

      <.contact_badge id="badge-1" contact={%{id: 1, display_name: "John Doe", avatar_url: nil}} />
  """
  attr :id, :string, required: true
  attr :contact, :map, required: true
  attr :navigate, :string, default: nil

  def contact_badge(assigns) do
    assigns =
      assign_new(assigns, :href, fn ->
        assigns.navigate || "/contacts/#{assigns.contact.id}"
      end)

    ~H"""
    <.link
      id={@id}
      navigate={@href}
      class="inline-flex items-center gap-2 rounded-[var(--radius-full)] bg-[var(--color-surface-sunken)] pe-3 ps-1 py-1 text-sm font-medium text-[var(--color-text-primary)] hover:bg-[var(--color-border)] transition-colors duration-150"
    >
      <.avatar
        id={"#{@id}-avatar"}
        src={avatar_url(@contact)}
        name={Map.get(@contact, :display_name, "")}
        size={:sm}
      />
      <span class="truncate max-w-[12rem]">{Map.get(@contact, :display_name, "")}</span>
    </.link>
    """
  end

  # ==========================================================================
  # Tag Badge
  # ==========================================================================

  @doc """
  Renders a colored tag pill.

  ## Examples

      <.tag_badge tag={%{name: "Family", color: "blue"}} />
      <.tag_badge tag={%{name: "Work", color: nil}} />
  """
  attr :id, :string, default: nil
  attr :tag, :map, required: true
  attr :class, :string, default: nil

  def tag_badge(assigns) do
    color = Map.get(assigns.tag, :color)
    name = Map.get(assigns.tag, :name, "")

    assigns =
      if color do
        assign(assigns, :color_classes, tag_color(color, name))
      else
        assign(assigns, :color_classes, "#{name_to_color(name)} text-white")
      end

    ~H"""
    <span
      id={@id}
      class={[
        "inline-flex items-center rounded-[var(--radius-full)] px-2.5 py-0.5 text-xs font-medium",
        @color_classes,
        @class
      ]}
    >
      {Map.get(@tag, :name, "")}
    </span>
    """
  end

  # ==========================================================================
  # Reminder Row
  # ==========================================================================

  @doc """
  Renders a reminder row with Heroicon type icon and formatted date.

  ## Examples

      <.reminder_row reminder={%{type: "birthday", title: "John's birthday", date: ~D[2026-04-15]}} />
  """
  attr :id, :string, default: nil
  attr :reminder, :map, required: true
  attr :locale, :string, default: "en"

  def reminder_row(assigns) do
    assigns =
      assigns
      |> assign(:icon_name, reminder_icon_name(assigns.reminder))
      |> assign(:formatted_date, format_reminder_date(assigns.reminder, assigns.locale))

    ~H"""
    <div id={@id} class="flex items-center gap-3 py-2.5 group">
      <div class="flex items-center justify-center size-9 rounded-[var(--radius-lg)] bg-[var(--color-accent-subtle)] shrink-0">
        <.icon name={@icon_name} class="size-4 text-[var(--color-accent)]" />
      </div>
      <div class="flex-1 min-w-0">
        <p class="text-sm font-medium text-[var(--color-text-primary)] truncate">
          {Map.get(@reminder, :title, "")}
        </p>
        <p class="text-xs text-[var(--color-text-tertiary)]">{@formatted_date}</p>
      </div>
    </div>
    """
  end

  # ==========================================================================
  # Stat Card
  # ==========================================================================

  @doc """
  Renders a stat card for the dashboard.

  ## Examples

      <.stat_card title="Total Contacts" value="142" icon="hero-user-group" />
      <.stat_card title="Reminders" value="7" icon="hero-bell" href="/reminders" />
  """
  attr :id, :string, default: nil
  attr :title, :string, required: true
  attr :value, :any, required: true
  attr :icon, :string, default: nil
  attr :href, :string, default: nil
  attr :change, :string, default: nil
  attr :change_type, :string, default: "neutral", values: ~w(positive negative neutral)
  attr :class, :any, default: nil

  def stat_card(assigns) do
    ~H"""
    <div
      id={@id}
      class={[
        "rounded-[var(--radius-lg)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] p-5",
        @href &&
          "hover:border-[var(--color-accent)]/30 hover:shadow-[var(--shadow-card)] transition-all duration-200 cursor-pointer",
        @class
      ]}
    >
      <.link :if={@href} navigate={@href} class="block">
        <.stat_card_inner
          title={@title}
          value={@value}
          icon={@icon}
          change={@change}
          change_type={@change_type}
        />
      </.link>
      <div :if={!@href}>
        <.stat_card_inner
          title={@title}
          value={@value}
          icon={@icon}
          change={@change}
          change_type={@change_type}
        />
      </div>
    </div>
    """
  end

  defp stat_card_inner(assigns) do
    ~H"""
    <div class="flex items-start justify-between">
      <div>
        <p class="text-xs font-medium uppercase tracking-wider text-[var(--color-text-tertiary)]">
          {@title}
        </p>
        <p class="mt-2 text-2xl font-semibold text-[var(--color-text-primary)] tracking-tight">
          {@value}
        </p>
        <p :if={@change} class={["mt-1 text-xs font-medium", change_color(@change_type)]}>
          {@change}
        </p>
      </div>
      <div
        :if={@icon}
        class="flex items-center justify-center size-10 rounded-[var(--radius-lg)] bg-[var(--color-accent-subtle)]"
      >
        <.icon name={@icon} class="size-5 text-[var(--color-accent)]" />
      </div>
    </div>
    """
  end

  defp change_color("positive"), do: "text-[var(--color-success)]"
  defp change_color("negative"), do: "text-[var(--color-error)]"
  defp change_color(_), do: "text-[var(--color-text-tertiary)]"

  # ==========================================================================
  # Section Header
  # ==========================================================================

  @doc """
  Renders a section title with optional action button.

  ## Examples

      <.section_header title="Recent Activity">
        <:actions>
          <.button variant="ghost" size="sm">View All</.button>
        </:actions>
      </.section_header>
  """
  attr :id, :string, default: nil
  attr :title, :string, required: true
  slot :actions

  def section_header(assigns) do
    ~H"""
    <div id={@id} class="flex items-center justify-between mb-4">
      <h2 class="text-base font-semibold text-[var(--color-text-primary)]">{@title}</h2>
      <div :if={@actions != []} class="flex items-center gap-2">
        {render_slot(@actions)}
      </div>
    </div>
    """
  end

  # ==========================================================================
  # Empty State
  # ==========================================================================

  @doc """
  Renders an empty state with icon, human-voiced copy, and single CTA.

  ## Examples

      <.empty_state icon="hero-users" title="No contacts yet" message="Your relationships start here. Add your first contact to get going.">
        <:actions>
          <.button>Add Contact</.button>
        </:actions>
      </.empty_state>
  """
  attr :id, :string, default: nil
  attr :icon, :string, required: true
  attr :title, :string, required: true
  attr :message, :string, default: nil
  attr :size, :atom, default: :default, values: [:default, :compact]
  slot :actions

  def empty_state(assigns) do
    ~H"""
    <div
      id={@id}
      class={[
        "flex flex-col items-center justify-center text-center",
        @size == :compact && "py-8",
        @size == :default && "py-16"
      ]}
    >
      <div class={[
        "flex items-center justify-center rounded-full bg-[var(--color-accent-subtle)] mb-5",
        @size == :compact && "size-10",
        @size == :default && "size-16"
      ]}>
        <.icon
          name={@icon}
          class={[
            "text-[var(--color-accent)]",
            @size == :compact && "size-5",
            @size == :default && "size-7"
          ]}
        />
      </div>
      <h3 class={[
        "font-semibold text-[var(--color-text-primary)] mb-1",
        @size == :compact && "text-base",
        @size == :default && "text-lg"
      ]}>
        {@title}
      </h3>
      <p
        :if={@message}
        class="text-sm text-[var(--color-text-secondary)] max-w-sm mb-6 leading-relaxed"
      >
        {@message}
      </p>
      <div :if={@actions != []} class="flex items-center gap-3">
        {render_slot(@actions)}
      </div>
    </div>
    """
  end

  # ==========================================================================
  # Role Badge
  # ==========================================================================

  @doc """
  Renders a role badge chip with warm color coding.

  ## Examples

      <.role_badge role="admin" />
      <.role_badge role="editor" />
      <.role_badge role="viewer" />
  """
  attr :id, :string, default: nil
  attr :role, :string, required: true

  def role_badge(assigns) do
    assigns = assign(assigns, :role_classes, role_classes(assigns.role))

    ~H"""
    <span
      id={@id}
      class={[
        "inline-flex items-center rounded-[var(--radius-full)] px-2.5 py-0.5 text-xs font-medium capitalize",
        @role_classes
      ]}
    >
      {@role}
    </span>
    """
  end

  # ==========================================================================
  # Emotion Badge
  # ==========================================================================

  @doc """
  Renders an emotion label chip.

  ## Examples

      <.emotion_badge emotion="happy" />
      <.emotion_badge emotion="grateful" />
  """
  attr :id, :string, default: nil
  attr :emotion, :string, required: true

  def emotion_badge(assigns) do
    assigns = assign(assigns, :emotion_classes, emotion_classes(assigns.emotion))

    ~H"""
    <span
      id={@id}
      class={[
        "inline-flex items-center rounded-[var(--radius-full)] px-2.5 py-0.5 text-xs font-medium capitalize",
        @emotion_classes
      ]}
    >
      {@emotion}
    </span>
    """
  end

  # ==========================================================================
  # Date Display
  # ==========================================================================

  @doc """
  Renders a date using Kith.Cldr for locale-aware formatting.

  ## Examples

      <.date_display date={~D[2026-03-21]} />
      <.date_display date={~D[2026-03-21]} locale="fr" format={:long} />
  """
  attr :id, :string, default: nil
  attr :date, :any, required: true
  attr :locale, :string, default: "en"
  attr :format, :atom, default: :medium
  attr :year_unknown, :boolean, default: false

  def date_display(assigns) do
    formatted =
      if assigns.year_unknown do
        format_month_day(assigns.date)
      else
        case Kith.Cldr.Date.to_string(assigns.date,
               locale: assigns.locale,
               format: assigns.format
             ) do
          {:ok, str} -> str
          _ -> to_string(assigns.date)
        end
      end

    assigns = assign(assigns, :formatted, formatted)

    ~H"""
    <time id={@id} datetime={to_string(@date)} class="text-[var(--color-text-secondary)]">
      {@formatted}
    </time>
    """
  end

  defp format_month_day(%Date{} = date) do
    Calendar.strftime(date, "%B %-d")
  end

  defp format_month_day(date), do: to_string(date)

  # ==========================================================================
  # Datetime Display
  # ==========================================================================

  @doc """
  Renders a formatted datetime using CLDR locale-aware formatting.

  ## Examples

      <.datetime_display datetime={~U[2026-03-21 14:30:00Z]} />
      <.datetime_display datetime={~U[2026-03-21 14:30:00Z]} locale="fr" format={:long} />
  """
  attr :id, :string, default: nil
  attr :datetime, :any, required: true
  attr :locale, :string, default: "en"
  attr :format, :atom, default: :medium

  def datetime_display(assigns) do
    formatted =
      case Kith.Cldr.DateTime.to_string(assigns.datetime,
             locale: assigns.locale,
             format: assigns.format
           ) do
        {:ok, str} -> str
        _ -> to_string(assigns.datetime)
      end

    assigns = assign(assigns, :formatted, formatted)

    ~H"""
    <time id={@id} datetime={to_string(@datetime)} class="text-[var(--color-text-secondary)]">
      {@formatted}
    </time>
    """
  end

  # ==========================================================================
  # Relative Time
  # ==========================================================================

  @doc """
  Renders relative time (e.g. "2 hours ago") using Kith.Cldr.

  ## Examples

      <.relative_time datetime={~U[2026-03-21 10:00:00Z]} />
  """
  attr :id, :string, default: nil
  attr :datetime, :any, required: true
  attr :locale, :string, default: "en"

  def relative_time(assigns) do
    formatted =
      case Relative.to_string(assigns.datetime, locale: assigns.locale) do
        {:ok, str} -> str
        _ -> to_string(assigns.datetime)
      end

    assigns = assign(assigns, :formatted, formatted)

    ~H"""
    <time
      id={@id}
      datetime={to_string(@datetime)}
      title={to_string(@datetime)}
      class="text-[var(--color-text-tertiary)] text-sm"
    >
      {@formatted}
    </time>
    """
  end

  # ==========================================================================
  # Command Palette
  # ==========================================================================

  @doc """
  Renders the command palette overlay (Cmd+K).
  """
  attr :id, :string, default: "command-palette"

  def command_palette(assigns) do
    ~H"""
    <div
      id={@id}
      x-data="commandPalette"
      phx-hook="CommandPalette"
      x-show="open"
      x-cloak
      class="fixed inset-0 z-50"
      x-transition:enter="transition ease-out duration-200"
      x-transition:enter-start="opacity-0"
      x-transition:enter-end="opacity-100"
      x-transition:leave="transition ease-in duration-150"
      x-transition:leave-start="opacity-100"
      x-transition:leave-end="opacity-0"
      role="dialog"
      aria-modal="true"
      aria-label="Command palette"
    >
      <%!-- Backdrop --%>
      <div
        class="fixed inset-0 bg-black/50 backdrop-blur-sm"
        x-on:click="close"
      />

      <%!-- Dialog --%>
      <div class="fixed inset-x-0 top-[15vh] mx-auto w-full max-w-lg px-4">
        <div
          class="rounded-[var(--radius-lg)] border border-[var(--color-border)] bg-[var(--color-surface-overlay)] shadow-[var(--shadow-dropdown)] overflow-hidden"
          x-transition:enter="transition ease-out duration-200"
          x-transition:enter-start="scale-95 opacity-0"
          x-transition:enter-end="scale-100 opacity-100"
          x-transition:leave="transition ease-in duration-150"
          x-transition:leave-start="scale-100 opacity-100"
          x-transition:leave-end="scale-95 opacity-0"
          x-on:keydown="onKeydown"
        >
          <%!-- Search input --%>
          <div class="flex items-center gap-3 px-4 py-3 border-b border-[var(--color-border)]">
            <.icon
              name="hero-magnifying-glass"
              class="size-5 text-[var(--color-text-tertiary)] shrink-0"
            />
            <input
              type="text"
              x-ref="searchInput"
              x-model="query"
              x-on:input="onInput"
              placeholder="Search contacts, pages, actions..."
              class="flex-1 bg-transparent text-sm text-[var(--color-text-primary)] placeholder:text-[var(--color-text-disabled)] outline-none"
              role="combobox"
              aria-expanded="true"
              aria-controls="command-palette-list"
              aria-autocomplete="list"
            />
            <kbd class="text-[10px] font-mono text-[var(--color-text-disabled)] border border-[var(--color-border)] rounded px-1.5 py-0.5">
              Esc
            </kbd>
          </div>

          <%!-- Results --%>
          <div
            id="command-palette-list"
            role="listbox"
            class="max-h-72 overflow-y-auto py-2"
          >
            <%!-- Loading --%>
            <div x-show="loading" class="flex items-center justify-center py-6">
              <div class="size-5 border-2 border-[var(--color-accent)] border-t-transparent rounded-full motion-safe:animate-spin" />
            </div>

            <%!-- Empty state --%>
            <div
              x-show="!loading && query.length >= 2 && allItems.length === 0"
              class="py-6 text-center"
            >
              <p class="text-sm text-[var(--color-text-tertiary)]">No results found</p>
            </div>

            <%!-- Items --%>
            <template
              x-for="(item, index) in allItems"
              x-bind:key="item.type + '-' + (item.id || item.name || index)"
            >
              <div>
                <%!-- Section headers --%>
                <template x-if="index === 0 || allItems[index - 1].section !== item.section">
                  <div class="px-4 py-1.5 text-[10px] font-semibold uppercase tracking-wider text-[var(--color-text-disabled)]">
                    <span x-text="item.section === 'recent' ? 'Recent' : item.section === 'contacts' ? 'Contacts' : item.section === 'pages' ? 'Pages' : 'Actions'" />
                  </div>
                </template>

                <button
                  x-on:click="selectItem(index)"
                  x-on:mouseenter="selectedIndex = index"
                  x-bind:class="selectedIndex === index ? 'bg-[var(--color-accent-subtle)]' : ''"
                  class="flex items-center gap-3 w-full px-4 py-2 text-sm text-start transition-colors duration-75 cursor-pointer"
                  role="option"
                  x-bind:aria-selected="selectedIndex === index"
                >
                  <span class="flex items-center justify-center size-7 rounded-[var(--radius-md)] bg-[var(--color-surface-sunken)] shrink-0">
                    <template x-if="item.type === 'contact'">
                      <.icon name="hero-user" class="size-3.5 text-[var(--color-text-tertiary)]" />
                    </template>
                    <template x-if="item.type === 'page'">
                      <.icon
                        name="hero-rectangle-group"
                        class="size-3.5 text-[var(--color-text-tertiary)]"
                      />
                    </template>
                    <template x-if="item.type === 'action'">
                      <.icon name="hero-bolt" class="size-3.5 text-[var(--color-text-tertiary)]" />
                    </template>
                  </span>
                  <div class="flex-1 min-w-0">
                    <span
                      class="text-[var(--color-text-primary)] truncate block"
                      x-text="item.display_name || item.name"
                    />
                    <span
                      x-show="item.company"
                      class="text-xs text-[var(--color-text-tertiary)] truncate block"
                      x-text="item.company"
                    />
                  </div>
                  <span
                    x-show="selectedIndex === index"
                    class="text-[10px] text-[var(--color-text-disabled)] font-mono"
                  >
                    ↵
                  </span>
                </button>
              </div>
            </template>
          </div>

          <%!-- Footer --%>
          <div class="flex items-center gap-4 px-4 py-2 border-t border-[var(--color-border)] text-[10px] text-[var(--color-text-disabled)]">
            <span class="inline-flex items-center gap-1">
              <kbd class="font-mono border border-[var(--color-border)] rounded px-1 py-0.5">↑↓</kbd>
              Navigate
            </span>
            <span class="inline-flex items-center gap-1">
              <kbd class="font-mono border border-[var(--color-border)] rounded px-1 py-0.5">↵</kbd>
              Select
            </span>
            <span class="inline-flex items-center gap-1">
              <kbd class="font-mono border border-[var(--color-border)] rounded px-1 py-0.5">Esc</kbd>
              Close
            </span>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
