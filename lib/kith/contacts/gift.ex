defmodule Kith.Contacts.Gift do
  use Ecto.Schema
  import Ecto.Changeset

  @occasions ~w(birthday christmas anniversary wedding thank_you other)
  @directions ~w(given received)
  @statuses ~w(idea purchased given received)

  schema "gifts" do
    field :name, :string
    field :description, :string
    field :occasion, :string
    field :date, :date
    field :amount, Kith.Types.BoundedDecimal
    field :direction, :string
    field :status, :string, default: "idea"
    field :purchase_url, :string
    field :is_private, :boolean, default: true

    belongs_to :account, Kith.Accounts.Account
    belongs_to :contact, Kith.Contacts.Contact
    belongs_to :creator, Kith.Accounts.User
    belongs_to :currency, Kith.Contacts.Currency

    timestamps(type: :utc_datetime)
  end

  def changeset(gift, attrs) do
    gift
    |> cast(attrs, [
      :name,
      :description,
      :occasion,
      :date,
      :amount,
      :direction,
      :status,
      :purchase_url,
      :is_private,
      :contact_id,
      :currency_id
    ])
    |> validate_required([:name, :direction])
    |> validate_inclusion(:occasion, @occasions)
    |> validate_inclusion(:direction, @directions)
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:account_id)
    |> foreign_key_constraint(:contact_id)
    |> foreign_key_constraint(:creator_id)
    |> foreign_key_constraint(:currency_id)
  end
end
