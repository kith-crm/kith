defmodule KithWeb.SettingsLive.LifeEventTypes do
  use KithWeb, :live_view

  alias Kith.Contacts
  alias Kith.Contacts.LifeEventType

  import KithWeb.SettingsLive.SettingsLayout

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Life Event Types")
     |> assign(:account_id, nil)
     |> assign(:can_edit, false)
     |> assign(:life_event_types, [])
     |> assign(:editing_life_event_type, nil)
     |> assign(:changeset, LifeEventType.changeset(%LifeEventType{}, %{}))}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    account_id = socket.assigns.current_scope.account.id
    user = socket.assigns.current_scope.user
    can_edit = Kith.Policy.can?(user, :create, :reference_data)

    {:noreply,
     socket
     |> assign(:account_id, account_id)
     |> assign(:can_edit, can_edit)
     |> assign(:life_event_types, Contacts.list_life_event_types(account_id))}
  end

  @impl true
  def handle_event("validate", %{"life_event_type" => params}, socket) do
    changeset =
      (socket.assigns.editing_life_event_type || %LifeEventType{})
      |> LifeEventType.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :changeset, changeset)}
  end

  def handle_event("save", %{"life_event_type" => params}, socket) do
    account_id = socket.assigns.account_id

    result =
      if socket.assigns.editing_life_event_type do
        Contacts.update_life_event_type(socket.assigns.editing_life_event_type, params)
      else
        Contacts.create_life_event_type(account_id, params)
      end

    case result do
      {:ok, _let} ->
        action = if socket.assigns.editing_life_event_type, do: "updated", else: "created"

        {:noreply,
         socket
         |> put_flash(:info, "Life event type #{action} successfully.")
         |> assign(:life_event_types, Contacts.list_life_event_types(account_id))
         |> assign(:editing_life_event_type, nil)
         |> assign(:changeset, LifeEventType.changeset(%LifeEventType{}, %{}))}

      {:error, changeset} ->
        {:noreply, assign(socket, :changeset, changeset)}
    end
  end

  def handle_event("edit", %{"id" => id}, socket) do
    let = Contacts.get_life_event_type!(socket.assigns.account_id, String.to_integer(id))
    changeset = LifeEventType.changeset(let, %{})

    {:noreply,
     socket
     |> assign(:editing_life_event_type, let)
     |> assign(:changeset, changeset)}
  end

  def handle_event("cancel-edit", _params, socket) do
    {:noreply,
     socket
     |> assign(:editing_life_event_type, nil)
     |> assign(:changeset, LifeEventType.changeset(%LifeEventType{}, %{}))}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    account_id = socket.assigns.account_id
    let = Contacts.get_life_event_type!(account_id, String.to_integer(id))

    {:ok, _} = Contacts.delete_life_event_type(let)

    {:noreply,
     socket
     |> put_flash(:info, "Life event type '#{let.name}' deleted.")
     |> assign(:life_event_types, Contacts.list_life_event_types(account_id))
     |> assign(:editing_life_event_type, nil)
     |> assign(:changeset, LifeEventType.changeset(%LifeEventType{}, %{}))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_path={@current_path}
      pending_duplicates_count={@pending_duplicates_count}
    >
      <.settings_shell current_path={@current_path} current_scope={@current_scope}>
        <UI.header>
          Life Event Types
          <:subtitle>Manage life event types for tracking milestones</:subtitle>
        </UI.header>

        <%!-- Life event type form (create or edit) --%>
        <%= if @can_edit do %>
          <div class="mt-6 bg-[var(--color-surface-elevated)] border border-[var(--color-border)] rounded-[var(--radius-lg)] p-6">
            <h2 class="text-lg font-semibold mb-4">
              {if @editing_life_event_type, do: "Edit Life Event Type", else: "New Life Event Type"}
            </h2>
            <.form
              id="life-event-type-settings-form"
              for={@changeset}
              phx-change="validate"
              phx-submit="save"
              class="flex gap-3 items-end flex-wrap"
            >
              <div class="flex-1 min-w-[200px]">
                <label class="block text-sm font-medium text-[var(--color-text-primary)] mb-1.5">
                  Name
                </label>
                <input
                  type="text"
                  name="life_event_type[name]"
                  value={Ecto.Changeset.get_field(@changeset, :name)}
                  class="w-full rounded-[var(--radius-md)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] px-2.5 py-1.5 text-sm text-[var(--color-text-primary)] placeholder:text-[var(--color-text-disabled)] focus:border-[var(--color-border-focus)] focus:outline-none focus:ring-2 focus:ring-[var(--color-border-focus)]/20 transition-colors duration-150"
                  required
                />
              </div>
              <div class="flex-1 min-w-[200px]">
                <label class="block text-sm font-medium text-[var(--color-text-primary)] mb-1.5">
                  Category
                </label>
                <input
                  type="text"
                  name="life_event_type[category]"
                  value={Ecto.Changeset.get_field(@changeset, :category)}
                  placeholder="e.g. Career, Family, Health"
                  class="w-full rounded-[var(--radius-md)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] px-2.5 py-1.5 text-sm text-[var(--color-text-primary)] placeholder:text-[var(--color-text-disabled)] focus:border-[var(--color-border-focus)] focus:outline-none focus:ring-2 focus:ring-[var(--color-border-focus)]/20 transition-colors duration-150"
                />
              </div>
              <div class="flex gap-2">
                <UI.button type="submit" size="sm" phx-disable-with="Saving...">
                  {if @editing_life_event_type, do: "Update", else: "Create"}
                </UI.button>
                <%= if @editing_life_event_type do %>
                  <UI.button type="button" variant="ghost" size="sm" phx-click="cancel-edit">
                    Cancel
                  </UI.button>
                <% end %>
              </div>
            </.form>
          </div>
        <% end %>

        <%!-- Life event type list --%>
        <%= if @life_event_types == [] do %>
          <div class="text-center py-12 text-[var(--color-text-tertiary)]">
            <UI.icon name="hero-star" class="size-12 mb-2 mx-auto block opacity-40" />
            <p class="text-lg">No life event types yet</p>
            <p class="text-sm mt-1">Create your first life event type above.</p>
          </div>
        <% else %>
          <div class="mt-6 space-y-2">
            <%= for let <- @life_event_types do %>
              <div class="flex items-center justify-between p-3 bg-[var(--color-surface-elevated)] border border-[var(--color-border)] rounded-[var(--radius-lg)]">
                <div class="flex items-center gap-3">
                  <span class="text-sm font-medium text-[var(--color-text-primary)]">{let.name}</span>
                  <%= if let.category && let.category != "" do %>
                    <span class="inline-flex items-center rounded-[var(--radius-full)] bg-[var(--color-accent-subtle)] px-2 py-0.5 text-xs text-[var(--color-accent)]">
                      {let.category}
                    </span>
                  <% end %>
                  <%= if is_nil(let.account_id) do %>
                    <span class="inline-flex items-center rounded-[var(--radius-full)] bg-[var(--color-surface-sunken)] px-2 py-0.5 text-xs text-[var(--color-text-tertiary)]">
                      Default
                    </span>
                  <% end %>
                </div>
                <%= if @can_edit && !is_nil(let.account_id) do %>
                  <div class="flex gap-1">
                    <UI.button
                      variant="ghost"
                      size="sm"
                      phx-click="edit"
                      phx-value-id={let.id}
                      class="!px-2"
                    >
                      <UI.icon name="hero-pencil-square" class="size-4" />
                    </UI.button>
                    <UI.button
                      variant="ghost"
                      size="sm"
                      phx-click="delete"
                      phx-value-id={let.id}
                      class="!px-2 text-[var(--color-error)]"
                      data-confirm={"Delete life event type '#{let.name}'?"}
                    >
                      <UI.icon name="hero-trash" class="size-4" />
                    </UI.button>
                  </div>
                <% end %>
              </div>
            <% end %>
          </div>
        <% end %>
      </.settings_shell>
    </Layouts.app>
    """
  end
end
