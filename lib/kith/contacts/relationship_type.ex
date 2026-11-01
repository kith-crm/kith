defmodule Kith.Contacts.RelationshipType do
  use Ecto.Schema
  import Ecto.Changeset

  schema "relationship_types" do
    # Trusted classification assigned only by audited seeds/migrations.
    # Deliberately excluded from ordinary changeset casts.
    field :system_key, :string
    field :name, :string
    field :reverse_name, :string
    field :is_bidirectional, :boolean, default: false
    field :position, :integer, default: 0

    belongs_to :account, Kith.Accounts.Account

    timestamps(type: :utc_datetime)
  end

  def changeset(relationship_type, attrs) do
    relationship_type
    |> cast(attrs, [:name, :reverse_name, :is_bidirectional, :position, :account_id])
    |> validate_required([:name, :reverse_name])
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
