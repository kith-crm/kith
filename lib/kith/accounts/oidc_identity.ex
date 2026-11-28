defmodule Kith.Accounts.OIDCIdentity do
  @moduledoc "An exact issuer/subject identity owned by one local user."
  use Ecto.Schema
  import Ecto.Changeset

  schema "oidc_identities" do
    field :issuer, :string
    field :subject, :string
    belongs_to :user, Kith.Accounts.User
    timestamps(type: :utc_datetime)
  end

  def changeset(identity, attrs) do
    identity
    |> cast(attrs, [:issuer, :subject, :user_id], empty_values: [])
    |> validate_required([:issuer, :subject, :user_id], trim: false)
    |> validate_length(:issuer, min: 1)
    |> validate_length(:subject, min: 1)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint([:issuer, :subject])
  end
end
