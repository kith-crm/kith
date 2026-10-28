defmodule Kith.Contacts.AvatarAsset do
  @moduledoc "Account-owned rendition metadata survives photo deduplication and contact merges."
  use Ecto.Schema

  @primary_key {:storage_key, :string, autogenerate: false}
  schema "avatar_assets" do
    field :byte_size, :integer
    field :content_hash, :string
    belongs_to :account, Kith.Accounts.Account
  end
end
