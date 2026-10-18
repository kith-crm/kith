defmodule KithWeb.ContactLive.PetsComponent do
  use KithWeb, :live_component

  alias Kith.Pets

  @species_icons %{
    "dog" => "\u{1F415}",
    "cat" => "\u{1F408}",
    "bird" => "\u{1F426}",
    "fish" => "\u{1F41F}",
    "reptile" => "\u{1F98E}",
    "rabbit" => "\u{1F407}",
    "hamster" => "\u{1F439}",
    "other" => "\u{1F43E}"
  }

  @species_options [
    {"Dog", "dog"},
    {"Cat", "cat"},
    {"Bird", "bird"},
    {"Fish", "fish"},
    {"Reptile", "reptile"},
    {"Rabbit", "rabbit"},
    {"Hamster", "hamster"},
    {"Other", "other"}
  ]

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:pets, [])
     |> assign(:show_form, false)}
  end

  @impl true
  def update(assigns, socket) do
    pets = Pets.list_pets(assigns.account_id, assigns.contact_id)

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:pets, pets)}
  end

  @impl true
  def handle_event("show-form", _params, socket) do
    {:noreply, assign(socket, :show_form, true)}
  end

  def handle_event("cancel-form", _params, socket) do
    {:noreply, assign(socket, :show_form, false)}
  end

  def handle_event("save-pet", %{"pet" => pet_params}, socket) do
    params = Map.put(pet_params, "contact_id", socket.assigns.contact_id)

    case Pets.create_pet(socket.assigns.account_id, params) do
      {:ok, _pet} ->
        pets = Pets.list_pets(socket.assigns.account_id, socket.assigns.contact_id)

        {:noreply,
         socket
         |> assign(:pets, pets)
         |> assign(:show_form, false)
         |> put_flash(:info, "Pet added.")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to save pet.")}
    end
  end

  def handle_event("delete-pet", %{"id" => id}, socket) do
    pet = Pets.get_pet!(socket.assigns.account_id, String.to_integer(id))
    {:ok, _} = Pets.delete_pet(pet)
    pets = Pets.list_pets(socket.assigns.account_id, socket.assigns.contact_id)

    {:noreply,
     socket
     |> assign(:pets, pets)
     |> put_flash(:info, "Pet removed.")}
  end

  defp species_icon(species), do: Map.get(@species_icons, species, "\u{1F43E}")

  defp compute_age(nil), do: nil

  defp compute_age(date_of_birth) when is_struct(date_of_birth, Date) do
    today = Date.utc_today()
    years = today.year - date_of_birth.year

    age =
      if Date.compare(Kith.TimeHelper.anniversary_in_year(date_of_birth, today.year), today) ==
           :gt do
        years - 1
      else
        years
      end

    if age <= 0 do
      months = (today.year - date_of_birth.year) * 12 + today.month - date_of_birth.month
      if months > 0, do: "#{months}mo", else: "<1mo"
    else
      "#{age}y"
    end
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :species_options, @species_options)

    ~H"""
    <div>
      <div class="flex items-center justify-between mb-3">
        <h3 class="text-sm font-semibold text-[var(--color-text-primary)]">Pets</h3>
        <%= if @can_edit do %>
          <button
            id={"add-pet-#{@contact_id}"}
            phx-click="show-form"
            phx-target={@myself}
            class="rounded-[var(--radius-md)] p-1 text-[var(--color-text-tertiary)] hover:text-[var(--color-text-primary)] hover:bg-[var(--color-surface-sunken)] transition-colors cursor-pointer"
          >
            <.icon name="hero-plus" class="size-4" />
          </button>
        <% end %>
      </div>

      <%= if @show_form do %>
        <div class="mb-3">
          <.form for={%{}} phx-submit="save-pet" phx-target={@myself}>
            <div>
              <input
                type="text"
                name="pet[name]"
                placeholder="Pet name *"
                required
                class="w-full rounded-[var(--radius-md)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] px-2.5 py-1.5 text-sm text-[var(--color-text-primary)] placeholder:text-[var(--color-text-disabled)] focus:border-[var(--color-border-focus)] focus:outline-none focus:ring-2 focus:ring-[var(--color-border-focus)]/20 transition-colors duration-150"
              />
            </div>
            <div class="grid grid-cols-2 gap-2 mt-2">
              <select
                name="pet[species]"
                class="w-full rounded-[var(--radius-md)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] px-2.5 py-1.5 text-sm text-[var(--color-text-primary)] focus:border-[var(--color-border-focus)] focus:outline-none focus:ring-2 focus:ring-[var(--color-border-focus)]/20 transition-colors duration-150"
              >
                <%= for {label, value} <- @species_options do %>
                  <option value={value}>{label}</option>
                <% end %>
              </select>
              <input
                type="text"
                name="pet[breed]"
                placeholder="Breed"
                class="w-full rounded-[var(--radius-md)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] px-2.5 py-1.5 text-sm text-[var(--color-text-primary)] placeholder:text-[var(--color-text-disabled)] focus:border-[var(--color-border-focus)] focus:outline-none focus:ring-2 focus:ring-[var(--color-border-focus)]/20 transition-colors duration-150"
              />
            </div>
            <div class="mt-2">
              <label class="block mb-1">
                <span class="text-xs text-[var(--color-text-tertiary)]">Date of birth</span>
              </label>
              <input
                type="date"
                name="pet[date_of_birth]"
                class="w-full rounded-[var(--radius-md)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] px-2.5 py-1.5 text-sm text-[var(--color-text-primary)] focus:border-[var(--color-border-focus)] focus:outline-none focus:ring-2 focus:ring-[var(--color-border-focus)]/20 transition-colors duration-150"
              />
            </div>
            <div class="flex gap-2 mt-3">
              <button
                type="submit"
                class="inline-flex items-center gap-1.5 rounded-[var(--radius-md)] bg-[var(--color-accent)] text-[var(--color-accent-foreground)] px-3 py-1.5 text-xs font-medium hover:bg-[var(--color-accent-hover)] transition-colors cursor-pointer"
              >
                Save
              </button>
              <button
                type="button"
                phx-click="cancel-form"
                phx-target={@myself}
                class="inline-flex items-center gap-1.5 rounded-[var(--radius-md)] px-2.5 py-1.5 text-xs font-medium text-[var(--color-text-secondary)] hover:bg-[var(--color-surface-sunken)] hover:text-[var(--color-text-primary)] transition-colors cursor-pointer"
              >
                Cancel
              </button>
            </div>
          </.form>
        </div>
      <% end %>

      <%= if @pets == [] and not @show_form do %>
        <KithUI.empty_state
          size={:compact}
          icon="hero-heart"
          title="No pets"
          message="Add furry (or scaly) friends for this person."
        >
          <:actions :if={@can_edit}>
            <button
              phx-click="show-form"
              phx-target={@myself}
              class="inline-flex items-center gap-1.5 rounded-[var(--radius-md)] bg-[var(--color-accent)] text-[var(--color-accent-foreground)] px-3 py-1.5 text-xs font-medium hover:bg-[var(--color-accent-hover)] transition-colors cursor-pointer"
            >
              Add Pet
            </button>
          </:actions>
        </KithUI.empty_state>
      <% end %>

      <div class="space-y-2">
        <%= for pet <- @pets do %>
          <div class="flex items-center justify-between">
            <div class="flex items-center gap-2 min-w-0">
              <span class="text-base shrink-0" title={pet.species}>{species_icon(pet.species)}</span>
              <div class="min-w-0">
                <div class="text-sm font-medium text-[var(--color-text-primary)] truncate">
                  {pet.name}
                  <span
                    :if={age = compute_age(pet.date_of_birth)}
                    class="font-normal text-[var(--color-text-tertiary)]"
                  >
                    ({age})
                  </span>
                </div>
                <div :if={pet.breed} class="text-xs text-[var(--color-text-tertiary)] truncate">
                  {pet.breed}
                </div>
              </div>
            </div>
            <%= if @can_edit do %>
              <button
                phx-click="delete-pet"
                phx-value-id={pet.id}
                phx-target={@myself}
                data-confirm={"Remove #{pet.name}?"}
                class="text-[var(--color-text-disabled)] hover:text-[var(--color-error)] text-xs transition-colors cursor-pointer shrink-0 ms-2"
                title="Remove pet"
              >
                <.icon name="hero-x-mark" class="size-3.5" />
              </button>
            <% end %>
          </div>
        <% end %>
      </div>
    </div>
    """
  end
end
