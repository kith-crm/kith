defmodule KithWeb.SettingsLive.ActivityTypes do
  use KithWeb, :live_view

  alias Kith.Contacts
  alias Kith.Contacts.ActivityTypeCategory

  import KithWeb.SettingsLive.SettingsLayout

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Activity Types")
     |> assign(:account_id, nil)
     |> assign(:can_edit, false)
     |> assign(:activity_types, [])
     |> assign(:editing_activity_type, nil)
     |> assign(:changeset, ActivityTypeCategory.changeset(%ActivityTypeCategory{}, %{}))}
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
     |> assign(:activity_types, Contacts.list_activity_type_categories(account_id))}
  end

  @impl true
  def handle_event("validate", %{"activity_type_category" => params}, socket) do
    changeset =
      (socket.assigns.editing_activity_type || %ActivityTypeCategory{})
      |> ActivityTypeCategory.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :changeset, changeset)}
  end

  def handle_event("save", %{"activity_type_category" => params}, socket) do
    account_id = socket.assigns.account_id

    result =
      if socket.assigns.editing_activity_type do
        Contacts.update_activity_type_category(socket.assigns.editing_activity_type, params)
      else
        Contacts.create_activity_type_category(account_id, params)
      end

    case result do
      {:ok, _atc} ->
        action = if socket.assigns.editing_activity_type, do: "updated", else: "created"

        {:noreply,
         socket
         |> put_flash(:info, "Activity type #{action} successfully.")
         |> assign(:activity_types, Contacts.list_activity_type_categories(account_id))
         |> assign(:editing_activity_type, nil)
         |> assign(:changeset, ActivityTypeCategory.changeset(%ActivityTypeCategory{}, %{}))}

      {:error, changeset} ->
        {:noreply, assign(socket, :changeset, changeset)}
    end
  end

  def handle_event("edit", %{"id" => id}, socket) do
    atc = Contacts.get_activity_type_category!(socket.assigns.account_id, String.to_integer(id))
    changeset = ActivityTypeCategory.changeset(atc, %{})

    {:noreply,
     socket
     |> assign(:editing_activity_type, atc)
     |> assign(:changeset, changeset)}
  end

  def handle_event("cancel-edit", _params, socket) do
    {:noreply,
     socket
     |> assign(:editing_activity_type, nil)
     |> assign(:changeset, ActivityTypeCategory.changeset(%ActivityTypeCategory{}, %{}))}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    account_id = socket.assigns.account_id
    atc = Contacts.get_activity_type_category!(account_id, String.to_integer(id))

    {:ok, _} = Contacts.delete_activity_type_category(atc)

    {:noreply,
     socket
     |> put_flash(:info, "Activity type '#{atc.name}' deleted.")
     |> assign(:activity_types, Contacts.list_activity_type_categories(account_id))
     |> assign(:editing_activity_type, nil)
     |> assign(:changeset, ActivityTypeCategory.changeset(%ActivityTypeCategory{}, %{}))}
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
          Activity Types
          <:subtitle>Manage activity type categories for organizing activities</:subtitle>
        </UI.header>

        <%!-- Activity type form (create or edit) --%>
        <%= if @can_edit do %>
          <div class="mt-6 bg-[var(--color-surface-elevated)] border border-[var(--color-border)] rounded-[var(--radius-lg)] p-6">
            <h2 class="text-lg font-semibold mb-4">
              {if @editing_activity_type, do: "Edit Activity Type", else: "New Activity Type"}
            </h2>
            <.form
              id="activity-type-settings-form"
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
                  name="activity_type_category[name]"
                  value={Ecto.Changeset.get_field(@changeset, :name)}
                  class="w-full rounded-[var(--radius-md)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] px-2.5 py-1.5 text-sm text-[var(--color-text-primary)] placeholder:text-[var(--color-text-disabled)] focus:border-[var(--color-border-focus)] focus:outline-none focus:ring-2 focus:ring-[var(--color-border-focus)]/20 transition-colors duration-150"
                  required
                />
              </div>
              <div class="flex gap-2">
                <UI.button type="submit" size="sm" phx-disable-with="Saving...">
                  {if @editing_activity_type, do: "Update", else: "Create"}
                </UI.button>
                <%= if @editing_activity_type do %>
                  <UI.button type="button" variant="ghost" size="sm" phx-click="cancel-edit">
                    Cancel
                  </UI.button>
                <% end %>
              </div>
            </.form>
          </div>
        <% end %>

        <%!-- Activity type list --%>
        <%= if @activity_types == [] do %>
          <div class="text-center py-12 text-[var(--color-text-tertiary)]">
            <UI.icon name="hero-rectangle-group" class="size-12 mb-2 mx-auto block opacity-40" />
            <p class="text-lg">No activity types yet</p>
            <p class="text-sm mt-1">Create your first activity type above.</p>
          </div>
        <% else %>
          <div class="mt-6 space-y-2">
            <%= for atc <- @activity_types do %>
              <div class="flex items-center justify-between p-3 bg-[var(--color-surface-elevated)] border border-[var(--color-border)] rounded-[var(--radius-lg)]">
                <div class="flex items-center gap-3">
                  <span class="text-sm font-medium text-[var(--color-text-primary)]">{atc.name}</span>
                  <%= if is_nil(atc.account_id) do %>
                    <span class="inline-flex items-center rounded-[var(--radius-full)] bg-[var(--color-surface-sunken)] px-2 py-0.5 text-xs text-[var(--color-text-tertiary)]">
                      Default
                    </span>
                  <% end %>
                </div>
                <%= if @can_edit && !is_nil(atc.account_id) do %>
                  <div class="flex gap-1">
                    <UI.button
                      variant="ghost"
                      size="sm"
                      phx-click="edit"
                      phx-value-id={atc.id}
                      class="!px-2"
                    >
                      <UI.icon name="hero-pencil-square" class="size-4" />
                    </UI.button>
                    <UI.button
                      variant="ghost"
                      size="sm"
                      phx-click="delete"
                      phx-value-id={atc.id}
                      class="!px-2 text-[var(--color-error)]"
                      data-confirm={"Delete activity type '#{atc.name}'?"}
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
