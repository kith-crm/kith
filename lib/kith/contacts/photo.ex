defmodule Kith.Contacts.Photo do
  use Ecto.Schema
  import Ecto.Changeset

  schema "photos" do
    field :file_name, :string
    field :storage_key, :string
    field :file_size, :integer
    field :content_type, :string
    field :is_private, :boolean, default: false
    field :content_hash, :string
    field :avatar_storage_key, :string
    field :avatar_file_size, :integer
    field :avatar_signature, :string
    field :avatar_crop, :map
    field :avatar_content_hash, :string

    belongs_to :contact, Kith.Contacts.Contact
    belongs_to :account, Kith.Accounts.Account
    belongs_to :creator, Kith.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(photo, attrs) do
    photo
    |> cast(attrs, [
      :file_name,
      :storage_key,
      :file_size,
      :content_type,
      :contact_id,
      :account_id,
      :is_private,
      :content_hash
    ])
    |> validate_required([:file_name, :storage_key, :file_size, :content_type])
    |> unique_constraint([:contact_id, :content_hash], name: :photos_contact_content_hash_idx)
  end

  @doc "Returns true if the photo is awaiting sync from an external source."
  def pending_sync?(%__MODULE__{storage_key: "pending_sync:" <> _}), do: true
  def pending_sync?(%__MODULE__{}), do: false
end
