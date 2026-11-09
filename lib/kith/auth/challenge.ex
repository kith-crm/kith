defmodule Kith.Auth.Challenge do
  @moduledoc "Single-use local MFA challenge with encrypted completion context."
  use Ecto.Schema
  @derive {Inspect, except: [:payload, :handle_hash, :binding_hash]}
  schema "auth_challenges" do
    field :handle_hash, :binary
    field :binding_hash, :binary
    belongs_to :user, Kith.Accounts.User
    field :intent, Ecto.Enum, values: [:login, :reauth, :link]
    field :authenticated_at, :utc_datetime
    field :expires_at, :utc_datetime_usec
    field :consumed_at, :utc_datetime_usec
    field :payload, Kith.EncryptedBinary
  end
end
