defmodule KithWeb.SettingsLive.Emotions do
  use KithWeb, :live_view

  alias Kith.Contacts
  alias Kith.Contacts.Emotion

  import KithWeb.SettingsLive.SettingsLayout

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Emotions")
     |> assign(:account_id, nil)
     |> assign(:can_edit, false)
     |> assign(:emotions, [])
     |> assign(:editing_emotion, nil)
     |> assign(:changeset, Emotion.changeset(%Emotion{}, %{}))}
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
     |> assign(:emotions, Contacts.list_emotions(account_id))}
  end

  @impl true
  def handle_event("validate", %{"emotion" => params}, socket) do
    changeset =
      (socket.assigns.editing_emotion || %Emotion{})
      |> Emotion.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :changeset, changeset)}
  end

  def handle_event("save", %{"emotion" => params}, socket) do
    account_id = socket.assigns.account_id

    result =
      if socket.assigns.editing_emotion do
        Contacts.update_emotion(socket.assigns.editing_emotion, params)
      else
        Contacts.create_emotion(account_id, params)
      end

    case result do
      {:ok, _emotion} ->
        action = if socket.assigns.editing_emotion, do: "updated", else: "created"

        {:noreply,
         socket
         |> put_flash(:info, "Emotion #{action} successfully.")
         |> assign(:emotions, Contacts.list_emotions(account_id))
         |> assign(:editing_emotion, nil)
         |> assign(:changeset, Emotion.changeset(%Emotion{}, %{}))}

      {:error, changeset} ->
        {:noreply, assign(socket, :changeset, changeset)}
    end
  end

  def handle_event("edit", %{"id" => id}, socket) do
    emotion = Contacts.get_emotion!(socket.assigns.account_id, String.to_integer(id))
    changeset = Emotion.changeset(emotion, %{})

    {:noreply,
     socket
     |> assign(:editing_emotion, emotion)
     |> assign(:changeset, changeset)}
  end

  def handle_event("cancel-edit", _params, socket) do
    {:noreply,
     socket
     |> assign(:editing_emotion, nil)
     |> assign(:changeset, Emotion.changeset(%Emotion{}, %{}))}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    account_id = socket.assigns.account_id
    emotion = Contacts.get_emotion!(account_id, String.to_integer(id))

    {:ok, _} = Contacts.delete_emotion(emotion)

    {:noreply,
     socket
     |> put_flash(:info, "Emotion '#{emotion.name}' deleted.")
     |> assign(:emotions, Contacts.list_emotions(account_id))
     |> assign(:editing_emotion, nil)
     |> assign(:changeset, Emotion.changeset(%Emotion{}, %{}))}
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
          Emotions
          <:subtitle>Manage emotions used when logging calls and activities</:subtitle>
        </UI.header>

        <%!-- Emotion form (create or edit) --%>
        <%= if @can_edit do %>
          <div class="mt-6 bg-[var(--color-surface-elevated)] border border-[var(--color-border)] rounded-[var(--radius-lg)] p-6">
            <h2 class="text-lg font-semibold mb-4">
              {if @editing_emotion, do: "Edit Emotion", else: "New Emotion"}
            </h2>
            <.form
              id="emotion-settings-form"
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
                  name="emotion[name]"
                  value={Ecto.Changeset.get_field(@changeset, :name)}
                  class="w-full rounded-[var(--radius-md)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] px-2.5 py-1.5 text-sm text-[var(--color-text-primary)] placeholder:text-[var(--color-text-disabled)] focus:border-[var(--color-border-focus)] focus:outline-none focus:ring-2 focus:ring-[var(--color-border-focus)]/20 transition-colors duration-150"
                  required
                />
              </div>
              <div class="flex gap-2">
                <UI.button type="submit" size="sm" phx-disable-with="Saving...">
                  {if @editing_emotion, do: "Update", else: "Create"}
                </UI.button>
                <%= if @editing_emotion do %>
                  <UI.button type="button" variant="ghost" size="sm" phx-click="cancel-edit">
                    Cancel
                  </UI.button>
                <% end %>
              </div>
            </.form>
          </div>
        <% end %>

        <%!-- Emotion list --%>
        <%= if @emotions == [] do %>
          <div class="text-center py-12 text-[var(--color-text-tertiary)]">
            <UI.icon name="hero-face-smile" class="size-12 mb-2 mx-auto block opacity-40" />
            <p class="text-lg">No emotions yet</p>
            <p class="text-sm mt-1">Create your first emotion above.</p>
          </div>
        <% else %>
          <div class="mt-6 space-y-2">
            <%= for emotion <- @emotions do %>
              <div class="flex items-center justify-between p-3 bg-[var(--color-surface-elevated)] border border-[var(--color-border)] rounded-[var(--radius-lg)]">
                <div class="flex items-center gap-3">
                  <span class="text-sm font-medium text-[var(--color-text-primary)]">
                    {emotion.name}
                  </span>
                  <%= if is_nil(emotion.account_id) do %>
                    <span class="inline-flex items-center rounded-[var(--radius-full)] bg-[var(--color-surface-sunken)] px-2 py-0.5 text-xs text-[var(--color-text-tertiary)]">
                      Default
                    </span>
                  <% end %>
                </div>
                <%= if @can_edit && !is_nil(emotion.account_id) do %>
                  <div class="flex gap-1">
                    <UI.button
                      variant="ghost"
                      size="sm"
                      phx-click="edit"
                      phx-value-id={emotion.id}
                      class="!px-2"
                    >
                      <UI.icon name="hero-pencil-square" class="size-4" />
                    </UI.button>
                    <UI.button
                      variant="ghost"
                      size="sm"
                      phx-click="delete"
                      phx-value-id={emotion.id}
                      class="!px-2 text-[var(--color-error)]"
                      data-confirm={"Delete emotion '#{emotion.name}'?"}
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
