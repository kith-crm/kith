defmodule Kith.Contacts.Debt do
  use Ecto.Schema
  import Ecto.Changeset

  @directions ~w(owed_to_me owed_by_me)
  @statuses ~w(active settled written_off)

  schema "debts" do
    field :title, :string
    field :amount, Kith.Types.BoundedDecimal
    field :direction, :string
    field :status, :string, default: "active"
    field :due_date, :date
    field :notes, :string
    field :settled_at, :utc_datetime
    field :is_private, :boolean, default: true

    belongs_to :account, Kith.Accounts.Account
    belongs_to :contact, Kith.Contacts.Contact
    belongs_to :creator, Kith.Accounts.User
    belongs_to :currency, Kith.Contacts.Currency

    has_many :payments, Kith.Contacts.DebtPayment

    timestamps(type: :utc_datetime)
  end

  def changeset(debt, attrs) do
    debt
    |> cast(attrs, [
      :title,
      :amount,
      :direction,
      :status,
      :due_date,
      :notes,
      :settled_at,
      :is_private,
      :contact_id,
      :currency_id
    ])
    |> validate_required([:title, :amount, :direction])
    |> validate_inclusion(:direction, @directions)
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:amount, greater_than: 0)
    |> foreign_key_constraint(:account_id)
    |> foreign_key_constraint(:contact_id)
    |> foreign_key_constraint(:creator_id)
    |> foreign_key_constraint(:currency_id)
  end

  def settle_changeset(debt) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    change(debt, status: "settled", settled_at: now)
  end

  def write_off_changeset(debt) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    change(debt, status: "written_off", settled_at: now)
  end
end
