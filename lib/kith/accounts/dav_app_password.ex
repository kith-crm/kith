defmodule Kith.Accounts.DavAppPassword do
  @moduledoc "A user-owned, hash-only credential for DAV requests."
  use Ecto.Schema
  import Ecto.Changeset

  schema "dav_app_passwords" do
    belongs_to :user, Kith.Accounts.User
    field :name, :string
    field :public_id, :string
    field :secret_hash, :binary, redact: true
    field :revoked_at, :utc_datetime
    timestamps(type: :utc_datetime)
  end

  def changeset(row, attrs) do
    row
    |> cast(attrs, [:name])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name, :user_id, :public_id, :secret_hash])
    |> validate_length(:name, min: 1, max: 80, count: :codepoints)
    |> unique_constraint(:public_id)
    |> foreign_key_constraint(:user_id)
  end
end
