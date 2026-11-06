defmodule Kith.Contacts.ContactField do
  use Ecto.Schema
  import Ecto.Changeset

  schema "contact_fields" do
    field :value, :string
    field :label, :string

    belongs_to :contact, Kith.Contacts.Contact
    belongs_to :account, Kith.Accounts.Account
    belongs_to :contact_field_type, Kith.Contacts.ContactFieldType

    timestamps(type: :utc_datetime)
  end

  def changeset(contact_field, attrs) do
    contact_field
    |> cast(attrs, [:value, :label, :contact_id, :account_id, :contact_field_type_id])
    |> validate_required([:value])
    |> validate_length(:value, max: 255, count: :codepoints)
    |> validate_length(:label, max: 255, count: :codepoints)
  end
end
