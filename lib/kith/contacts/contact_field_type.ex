defmodule Kith.Contacts.ContactFieldType do
  use Ecto.Schema
  import Ecto.Changeset

  schema "contact_field_types" do
    # Trusted classification assigned only by audited seeds/migrations.
    # Deliberately excluded from ordinary changeset casts.
    field :system_key, :string
    field :name, :string
    field :protocol, :string
    field :icon, :string
    field :vcard_label, :string
    field :position, :integer, default: 0

    belongs_to :account, Kith.Accounts.Account

    timestamps(type: :utc_datetime)
  end

  @allowed_protocols ~w(mailto tel https http)

  def changeset(contact_field_type, attrs) do
    contact_field_type
    |> cast(attrs, [:name, :protocol, :icon, :vcard_label, :position, :account_id])
    |> validate_required([:name])
    |> validate_inclusion(:protocol, @allowed_protocols ++ [nil])
    |> maybe_assoc_constraint_account()
  end

  defp maybe_assoc_constraint_account(changeset) do
    if get_field(changeset, :account_id) do
      assoc_constraint(changeset, :account)
    else
      changeset
    end
  end
end
