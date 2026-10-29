defmodule Kith.Contacts.Tag do
  use Ecto.Schema
  import Ecto.Changeset

  schema "tags" do
    field :name, :string
    field :color, :string

    belongs_to :account, Kith.Accounts.Account
    many_to_many :contacts, Kith.Contacts.Contact, join_through: "contact_tags"

    timestamps(type: :utc_datetime)
  end

  def changeset(tag, attrs) do
    tag
    |> cast(attrs, [:name, :color, :account_id])
    |> validate_required([:name])
    |> validate_length(:name, max: 255, count: :codepoints)
    |> validate_format(:color, ~r/^#[0-9a-fA-F]{6}$/,
      message: "must be a hex color (e.g., #FF5733)"
    )
    |> unique_constraint([:account_id, :name])
  end
end
