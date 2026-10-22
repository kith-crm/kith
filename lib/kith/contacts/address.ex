defmodule Kith.Contacts.Address do
  use Ecto.Schema
  import Ecto.Changeset

  schema "addresses" do
    field :label, :string
    field :line1, :string
    field :line2, :string
    field :city, :string
    field :province, :string
    field :postal_code, :string
    field :country, :string
    field :latitude, :float
    field :longitude, :float

    belongs_to :contact, Kith.Contacts.Contact
    belongs_to :account, Kith.Accounts.Account

    timestamps(type: :utc_datetime)
  end

  def changeset(address, attrs) do
    address
    |> cast(attrs, [
      :label,
      :line1,
      :line2,
      :city,
      :province,
      :postal_code,
      :country,
      :latitude,
      :longitude,
      :contact_id,
      :account_id
    ])
    |> validate_column_lengths()
  end

  # varchar(255) columns (CDV-21)
  defp validate_column_lengths(changeset) do
    [:label, :line1, :line2, :city, :province, :postal_code, :country]
    |> Enum.reduce(changeset, &validate_length(&2, &1, max: 255, count: :codepoints))
  end
end
