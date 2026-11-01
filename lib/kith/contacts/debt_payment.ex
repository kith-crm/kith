defmodule Kith.Contacts.DebtPayment do
  use Ecto.Schema
  import Ecto.Changeset

  schema "debt_payments" do
    field :amount, Kith.Types.BoundedDecimal
    field :paid_at, :date
    field :notes, :string

    belongs_to :debt, Kith.Contacts.Debt
    belongs_to :account, Kith.Accounts.Account

    timestamps(type: :utc_datetime)
  end

  def changeset(payment, attrs) do
    payment
    |> cast(attrs, [:amount, :paid_at, :notes])
    |> validate_required([:amount, :paid_at])
    |> validate_number(:amount, greater_than: 0)
    |> foreign_key_constraint(:debt_id)
    |> foreign_key_constraint(:account_id)
  end
end
