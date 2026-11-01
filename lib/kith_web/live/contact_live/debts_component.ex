defmodule KithWeb.ContactLive.DebtsComponent do
  use KithWeb, :live_component

  alias Kith.{Contacts, Debts}

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:debts, [])
     |> assign(:currencies, [])
     |> assign(:contact_currency, nil)
     |> assign(:show_form, false)
     |> assign(:expanded_debt_id, nil)
     |> assign(:show_payment_form_for, nil)}
  end

  @impl true
  def update(assigns, socket) do
    debts = Debts.list_debts(assigns.account_id, assigns.contact_id)
    currencies = Contacts.list_currencies()
    contact = Contacts.get_contact(assigns.account_id, assigns.contact_id, preload: [:currency])
    contact_currency = contact && contact.currency

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:debts, debts)
     |> assign(:currencies, currencies)
     |> assign(:contact_currency, contact_currency)}
  end

  @impl true
  def handle_event("show-form", _params, socket) do
    {:noreply, assign(socket, :show_form, true)}
  end

  def handle_event("cancel-form", _params, socket) do
    {:noreply, assign(socket, :show_form, false)}
  end

  def handle_event("set-contact-currency", %{"currency_id" => currency_id}, socket) do
    contact = Contacts.get_contact(socket.assigns.account_id, socket.assigns.contact_id)
    currency_id = if currency_id == "", do: nil, else: String.to_integer(currency_id)

    case Contacts.update_contact(contact, %{currency_id: currency_id}) do
      {:ok, updated_contact} ->
        updated_contact = Kith.Repo.preload(updated_contact, :currency)

        {:noreply,
         socket
         |> assign(:contact_currency, updated_contact.currency)
         |> put_flash(:info, "Default currency updated.")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to update currency.")}
    end
  end

  def handle_event("save-debt", %{"debt" => debt_params}, socket) do
    params = Map.put(debt_params, "contact_id", socket.assigns.contact_id)

    case Debts.create_debt(socket.assigns.account_id, socket.assigns.current_user_id, params) do
      {:ok, _debt} ->
        debts = Debts.list_debts(socket.assigns.account_id, socket.assigns.contact_id)

        {:noreply,
         socket
         |> assign(:debts, debts)
         |> assign(:show_form, false)
         |> put_flash(:info, "Debt added.")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to save debt.")}
    end
  end

  def handle_event("delete-debt", %{"id" => id}, socket) do
    debt = Debts.get_debt!(socket.assigns.account_id, String.to_integer(id))
    {:ok, _} = Debts.delete_debt(debt)
    debts = Debts.list_debts(socket.assigns.account_id, socket.assigns.contact_id)

    {:noreply,
     socket
     |> assign(:debts, debts)
     |> put_flash(:info, "Debt deleted.")}
  end

  def handle_event("toggle-debt", %{"id" => id}, socket) do
    debt_id = String.to_integer(id)

    new_expanded =
      if socket.assigns.expanded_debt_id == debt_id, do: nil, else: debt_id

    {:noreply,
     socket
     |> assign(:expanded_debt_id, new_expanded)
     |> assign(:show_payment_form_for, nil)}
  end

  def handle_event("settle-debt", %{"id" => id}, socket) do
    debt = Debts.get_debt!(socket.assigns.account_id, String.to_integer(id))
    {:ok, _} = Debts.settle_debt(debt)
    debts = Debts.list_debts(socket.assigns.account_id, socket.assigns.contact_id)

    {:noreply,
     socket
     |> assign(:debts, debts)
     |> put_flash(:info, "Debt settled.")}
  end

  def handle_event("show-payment-form", %{"id" => id}, socket) do
    {:noreply, assign(socket, :show_payment_form_for, String.to_integer(id))}
  end

  def handle_event("cancel-payment-form", _params, socket) do
    {:noreply, assign(socket, :show_payment_form_for, nil)}
  end

  def handle_event("add-payment", %{"payment" => payment_params}, socket) do
    debt = Debts.get_debt!(socket.assigns.account_id, socket.assigns.show_payment_form_for)

    case Debts.add_payment(debt, payment_params) do
      {:ok, _payment} ->
        debts = Debts.list_debts(socket.assigns.account_id, socket.assigns.contact_id)

        {:noreply,
         socket
         |> assign(:debts, debts)
         |> assign(:show_payment_form_for, nil)
         |> put_flash(:info, "Payment recorded.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to record payment.")}
    end
  end

  defp active_debts(debts) do
    Enum.filter(debts, &(&1.status == "active"))
  end

  defp total_paid(debt) do
    Enum.reduce(debt.payments, Decimal.new(0), fn p, acc -> Decimal.add(acc, p.amount) end)
  end

  defp format_amount(amount, currency) do
    symbol = if currency, do: currency.symbol, else: "$"
    formatted = amount |> Decimal.round(2) |> Decimal.to_string(:normal)
    "#{symbol}#{formatted}"
  end

  defp totals_by_currency(debts, direction) do
    debts
    |> Enum.filter(&(&1.direction == direction and &1.status == "active"))
    |> Enum.group_by(& &1.currency_id)
    |> Enum.map(fn {_currency_id, group} ->
      currency = List.first(group).currency
      total = Enum.reduce(group, Decimal.new(0), fn d, acc -> Decimal.add(acc, d.amount) end)
      {currency, total}
    end)
    |> Enum.reject(fn {_currency, total} -> Decimal.equal?(total, Decimal.new(0)) end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <div class="flex items-center justify-between mb-3">
        <div class="flex items-center gap-2">
          <h3 class="text-sm font-semibold text-[var(--color-text-primary)]">Debts</h3>
          <%= if @can_edit do %>
            <form id={"#{@id}-currency-form"} phx-change="set-contact-currency" phx-target={@myself}>
              <select
                name="currency_id"
                class="rounded-[var(--radius-md)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] px-1.5 py-0.5 text-xs text-[var(--color-text-secondary)] focus:border-[var(--color-border-focus)] focus:outline-none focus:ring-2 focus:ring-[var(--color-border-focus)]/20 transition-colors"
              >
                <option value="">No default currency</option>
                <%= for c <- @currencies do %>
                  <option value={c.id} selected={@contact_currency && @contact_currency.id == c.id}>
                    {c.code} ({c.symbol})
                  </option>
                <% end %>
              </select>
            </form>
          <% else %>
            <span :if={@contact_currency} class="text-xs text-[var(--color-text-tertiary)]">
              {@contact_currency.code}
            </span>
          <% end %>
        </div>
        <%= if @can_edit do %>
          <button
            id={"add-debt-#{@contact_id}"}
            phx-click="show-form"
            phx-target={@myself}
            class="rounded-[var(--radius-md)] p-1 text-[var(--color-text-tertiary)] hover:text-[var(--color-text-primary)] hover:bg-[var(--color-surface-sunken)] transition-colors cursor-pointer"
          >
            <.icon name="hero-plus" class="size-4" />
          </button>
        <% end %>
      </div>

      <%!-- Summary --%>
      <%= if @debts != [] do %>
        <div class="flex gap-3 mb-3 text-xs flex-wrap">
          <% owed_to_groups = totals_by_currency(@debts, "owed_to_me") %>
          <% owed_by_groups = totals_by_currency(@debts, "owed_by_me") %>
          <%= for {currency, total} <- owed_to_groups do %>
            <span class="inline-flex items-center gap-1 text-[var(--color-success)]">
              <.icon name="hero-arrow-down-left" class="size-3" />
              Owed to you: {format_amount(total, currency)}
            </span>
          <% end %>
          <%= for {currency, total} <- owed_by_groups do %>
            <span class="inline-flex items-center gap-1 text-[var(--color-error)]">
              <.icon name="hero-arrow-up-right" class="size-3" />
              You owe: {format_amount(total, currency)}
            </span>
          <% end %>
        </div>
      <% end %>

      <%!-- Add debt form --%>
      <%= if @show_form do %>
        <div class="mb-3">
          <.form for={%{}} phx-submit="save-debt" phx-target={@myself}>
            <div>
              <input
                type="text"
                name="debt[title]"
                placeholder="What for? *"
                required
                class="w-full rounded-[var(--radius-md)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] px-2.5 py-1.5 text-sm text-[var(--color-text-primary)] placeholder:text-[var(--color-text-disabled)] focus:border-[var(--color-border-focus)] focus:outline-none focus:ring-2 focus:ring-[var(--color-border-focus)]/20 transition-colors duration-150"
              />
            </div>
            <div class="grid grid-cols-3 gap-2 mt-2">
              <input
                type="number"
                name="debt[amount]"
                placeholder="Amount *"
                required
                step="0.01"
                min="0.01"
                class="w-full rounded-[var(--radius-md)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] px-2.5 py-1.5 text-sm text-[var(--color-text-primary)] placeholder:text-[var(--color-text-disabled)] focus:border-[var(--color-border-focus)] focus:outline-none focus:ring-2 focus:ring-[var(--color-border-focus)]/20 transition-colors duration-150"
              />
              <select
                name="debt[currency_id]"
                class="w-full rounded-[var(--radius-md)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] px-2.5 py-1.5 text-sm text-[var(--color-text-primary)] focus:border-[var(--color-border-focus)] focus:outline-none focus:ring-2 focus:ring-[var(--color-border-focus)]/20 transition-colors duration-150"
              >
                <option value="">Currency</option>
                <%= for c <- @currencies do %>
                  <option value={c.id} selected={@contact_currency && @contact_currency.id == c.id}>
                    {c.code} ({c.symbol})
                  </option>
                <% end %>
              </select>
              <select
                name="debt[direction]"
                required
                class="w-full rounded-[var(--radius-md)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] px-2.5 py-1.5 text-sm text-[var(--color-text-primary)] focus:border-[var(--color-border-focus)] focus:outline-none focus:ring-2 focus:ring-[var(--color-border-focus)]/20 transition-colors duration-150"
              >
                <option value="">Direction *</option>
                <option value="owed_to_me">They owe me</option>
                <option value="owed_by_me">I owe them</option>
              </select>
            </div>
            <div class="mt-2">
              <label class="block mb-1">
                <span class="text-xs text-[var(--color-text-tertiary)]">Due date</span>
              </label>
              <input
                type="date"
                name="debt[due_date]"
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

      <%!-- Empty state --%>
      <%= if @debts == [] and not @show_form do %>
        <KithUI.empty_state
          size={:compact}
          icon="hero-banknotes"
          title="No debts"
          message="Track money lent or borrowed with this person."
        >
          <:actions :if={@can_edit}>
            <button
              phx-click="show-form"
              phx-target={@myself}
              class="inline-flex items-center gap-1.5 rounded-[var(--radius-md)] bg-[var(--color-accent)] text-[var(--color-accent-foreground)] px-3 py-1.5 text-xs font-medium hover:bg-[var(--color-accent-hover)] transition-colors cursor-pointer"
            >
              Add Debt
            </button>
          </:actions>
        </KithUI.empty_state>
      <% end %>

      <%!-- Active debts list --%>
      <div class="space-y-2">
        <%= for debt <- active_debts(@debts) do %>
          <div class="rounded-[var(--radius-md)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)]">
            <button
              phx-click="toggle-debt"
              phx-value-id={debt.id}
              phx-target={@myself}
              class="w-full flex items-center justify-between px-3 py-2 text-left cursor-pointer hover:bg-[var(--color-surface-sunken)] transition-colors rounded-[var(--radius-md)]"
            >
              <div class="flex items-center gap-2 min-w-0">
                <.icon
                  name={
                    if @expanded_debt_id == debt.id,
                      do: "hero-chevron-down",
                      else: "hero-chevron-right"
                  }
                  class="size-3 text-[var(--color-text-tertiary)] shrink-0"
                />
                <span class="text-sm font-medium text-[var(--color-text-primary)] truncate">
                  {debt.title}
                </span>
              </div>
              <div class="flex items-center gap-2 shrink-0 ms-2">
                <span class={[
                  "text-sm font-semibold",
                  debt.direction == "owed_to_me" && "text-[var(--color-success)]",
                  debt.direction == "owed_by_me" && "text-[var(--color-error)]"
                ]}>
                  {format_amount(debt.amount, debt.currency)}
                </span>
                <span class={[
                  "inline-flex items-center rounded-[var(--radius-full)] px-1.5 py-0.5 text-[10px] font-medium border",
                  debt.direction == "owed_to_me" &&
                    "border-[var(--color-success)]/30 text-[var(--color-success)] bg-[var(--color-success)]/10",
                  debt.direction == "owed_by_me" &&
                    "border-[var(--color-error)]/30 text-[var(--color-error)] bg-[var(--color-error)]/10"
                ]}>
                  {if debt.direction == "owed_to_me", do: "IN", else: "OUT"}
                </span>
              </div>
            </button>

            <%!-- Expanded details --%>
            <%= if @expanded_debt_id == debt.id do %>
              <div class="px-3 pb-3 border-t border-[var(--color-border-subtle)]">
                <%!-- Due date & paid info --%>
                <div class="flex items-center gap-3 mt-2 text-xs text-[var(--color-text-tertiary)]">
                  <span :if={debt.due_date}>
                    Due: <.date_display date={debt.due_date} />
                  </span>
                  <% paid = total_paid(debt) %>
                  <%= if Decimal.gt?(paid, Decimal.new(0)) do %>
                    <span>Paid: {format_amount(paid, debt.currency)}</span>
                  <% end %>
                </div>

                <%!-- Payments list --%>
                <%= if debt.payments != [] do %>
                  <div class="mt-2 space-y-1">
                    <%= for payment <- debt.payments do %>
                      <div class="flex items-center justify-between text-xs text-[var(--color-text-secondary)]">
                        <span>
                          {format_amount(payment.amount, debt.currency)} on
                          <.date_display date={payment.paid_at} />
                        </span>
                        <span
                          :if={payment.notes}
                          class="text-[var(--color-text-tertiary)] truncate ms-2"
                        >
                          {payment.notes}
                        </span>
                      </div>
                    <% end %>
                  </div>
                <% end %>

                <%!-- Inline payment form --%>
                <%= if @show_payment_form_for == debt.id do %>
                  <div class="mt-2 pt-2 border-t border-[var(--color-border-subtle)]">
                    <.form for={%{}} phx-submit="add-payment" phx-target={@myself}>
                      <div class="grid grid-cols-2 gap-2">
                        <input
                          type="number"
                          name="payment[amount]"
                          placeholder="Amount *"
                          required
                          step="0.01"
                          min="0.01"
                          class="w-full rounded-[var(--radius-md)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] px-2 py-1 text-xs text-[var(--color-text-primary)] placeholder:text-[var(--color-text-disabled)] focus:border-[var(--color-border-focus)] focus:outline-none focus:ring-2 focus:ring-[var(--color-border-focus)]/20"
                        />
                        <input
                          type="date"
                          name="payment[paid_at]"
                          required
                          value={Date.utc_today() |> Date.to_iso8601()}
                          class="w-full rounded-[var(--radius-md)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] px-2 py-1 text-xs text-[var(--color-text-primary)] focus:border-[var(--color-border-focus)] focus:outline-none focus:ring-2 focus:ring-[var(--color-border-focus)]/20"
                        />
                      </div>
                      <input
                        type="text"
                        name="payment[notes]"
                        placeholder="Note (optional)"
                        class="w-full mt-1 rounded-[var(--radius-md)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] px-2 py-1 text-xs text-[var(--color-text-primary)] placeholder:text-[var(--color-text-disabled)] focus:border-[var(--color-border-focus)] focus:outline-none focus:ring-2 focus:ring-[var(--color-border-focus)]/20"
                      />
                      <div class="flex gap-2 mt-2">
                        <button
                          type="submit"
                          class="inline-flex items-center rounded-[var(--radius-md)] bg-[var(--color-accent)] text-[var(--color-accent-foreground)] px-2 py-1 text-xs font-medium hover:bg-[var(--color-accent-hover)] transition-colors cursor-pointer"
                        >
                          Record
                        </button>
                        <button
                          type="button"
                          phx-click="cancel-payment-form"
                          phx-target={@myself}
                          class="inline-flex items-center rounded-[var(--radius-md)] px-2 py-1 text-xs font-medium text-[var(--color-text-secondary)] hover:bg-[var(--color-surface-sunken)] transition-colors cursor-pointer"
                        >
                          Cancel
                        </button>
                      </div>
                    </.form>
                  </div>
                <% end %>

                <%!-- Action buttons --%>
                <%= if @can_edit do %>
                  <div class="flex gap-2 mt-2 pt-2 border-t border-[var(--color-border-subtle)]">
                    <button
                      :if={@show_payment_form_for != debt.id}
                      phx-click="show-payment-form"
                      phx-value-id={debt.id}
                      phx-target={@myself}
                      class="text-xs text-[var(--color-accent)] hover:text-[var(--color-accent-hover)] transition-colors cursor-pointer"
                    >
                      + Payment
                    </button>
                    <button
                      phx-click="settle-debt"
                      phx-value-id={debt.id}
                      phx-target={@myself}
                      data-confirm="Mark this debt as settled?"
                      class="text-xs text-[var(--color-success)] hover:text-[var(--color-success)] transition-colors cursor-pointer"
                    >
                      Settle
                    </button>
                    <button
                      phx-click="delete-debt"
                      phx-value-id={debt.id}
                      phx-target={@myself}
                      data-confirm="Delete this debt?"
                      class="text-xs text-[var(--color-error)] hover:text-[var(--color-error)] transition-colors cursor-pointer"
                    >
                      Delete
                    </button>
                  </div>
                <% end %>
              </div>
            <% end %>
          </div>
        <% end %>
      </div>

      <%!-- Settled/written-off debts (collapsed) --%>
      <% settled = Enum.filter(@debts, &(&1.status in ["settled", "written_off"])) %>
      <%= if settled != [] do %>
        <div class="mt-3 pt-2 border-t border-[var(--color-border-subtle)]">
          <p class="text-xs text-[var(--color-text-tertiary)] mb-1">Resolved ({length(settled)})</p>
          <div class="space-y-1">
            <%= for debt <- settled do %>
              <div class="flex items-center justify-between text-xs text-[var(--color-text-disabled)]">
                <span class="line-through truncate">{debt.title}</span>
                <span>{format_amount(debt.amount, debt.currency)}</span>
              </div>
            <% end %>
          </div>
        </div>
      <% end %>
    </div>
    """
  end
end
