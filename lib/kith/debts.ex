defmodule Kith.Debts do
  import Ecto.Query, warn: false
  import Kith.Scope
  alias Ecto.Multi
  alias Kith.Contacts.{Debt, DebtPayment}
  alias Kith.Repo

  def list_debts(account_id, contact_id) do
    Debt
    |> scope_to_account(account_id)
    |> where([d], d.contact_id == ^contact_id)
    |> order_by([d], desc: d.inserted_at)
    |> Repo.all()
    |> Repo.preload([:payments, :currency])
  end

  def get_debt!(account_id, id) do
    Debt |> scope_to_account(account_id) |> Repo.get!(id) |> Repo.preload([:payments, :currency])
  end

  def create_debt(account_id, creator_id, attrs) do
    attrs = maybe_inherit_contact_currency(account_id, attrs)

    %Debt{account_id: account_id, creator_id: creator_id}
    |> Debt.changeset(attrs)
    |> Repo.insert()
  end

  defp maybe_inherit_contact_currency(account_id, attrs) do
    currency_val = attrs["currency_id"] || attrs[:currency_id]
    has_explicit_currency = currency_val not in [nil, ""]

    if has_explicit_currency do
      attrs
    else
      contact_id = attrs["contact_id"] || attrs[:contact_id]

      case contact_id && Kith.Contacts.get_contact(account_id, contact_id) do
        %{currency_id: cid} when not is_nil(cid) -> Map.put(attrs, "currency_id", cid)
        _ -> attrs
      end
    end
  end

  def update_debt(%Debt{} = debt, attrs) do
    debt |> Debt.changeset(attrs) |> Repo.update()
  end

  def delete_debt(%Debt{} = debt), do: Repo.delete(debt)

  def settle_debt(%Debt{} = debt) do
    debt |> Debt.settle_changeset() |> Repo.update()
  end

  def write_off_debt(%Debt{} = debt) do
    debt |> Debt.write_off_changeset() |> Repo.update()
  end

  def add_payment(%Debt{} = debt, attrs) do
    Multi.new()
    |> Multi.insert(:payment, fn _changes ->
      %DebtPayment{debt_id: debt.id, account_id: debt.account_id}
      |> DebtPayment.changeset(attrs)
    end)
    |> Multi.run(:maybe_settle, fn repo, %{payment: _payment} ->
      debt = repo.get!(Debt, debt.id) |> repo.preload(:payments)

      total_paid =
        Enum.reduce(debt.payments, Decimal.new(0), fn p, acc -> Decimal.add(acc, p.amount) end)

      if Decimal.compare(total_paid, debt.amount) in [:eq, :gt] do
        debt |> Debt.settle_changeset() |> repo.update()
      else
        {:ok, debt}
      end
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{payment: payment}} -> {:ok, payment}
      {:error, :payment, changeset, _} -> {:error, changeset}
      {:error, _step, reason, _} -> {:error, reason}
    end
  end

  def delete_payment(%DebtPayment{} = payment), do: Repo.delete(payment)

  def outstanding_balance(%Debt{} = debt) do
    debt = Repo.preload(debt, :payments)

    total_paid =
      Enum.reduce(debt.payments, Decimal.new(0), fn p, acc -> Decimal.add(acc, p.amount) end)

    Decimal.sub(debt.amount, total_paid)
  end
end
