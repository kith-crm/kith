defmodule Kith.Auth.OIDC.Transaction do
  @moduledoc "An issuer-bound, browser-bound authentication flow. Payload is encrypted at rest."
  use Ecto.Schema

  @derive {Inspect, except: [:payload, :state, :nonce, :code_verifier, :session_token]}
  schema "oidc_transactions" do
    field :state_hash, :binary
    field :binding_hash, :binary
    field :issuer, :string
    field :intent, Ecto.Enum, values: [:login, :link, :reauth]
    field :payload, Kith.EncryptedBinary
    belongs_to :user, Kith.Accounts.User
    field :initiated_at, :utc_datetime_usec
    field :expires_at, :utc_datetime_usec
    field :consumed_at, :utc_datetime_usec
    field :state, :string, virtual: true
    field :nonce, :string, virtual: true
    field :code_verifier, :string, virtual: true
    field :session_token, :binary, virtual: true
    field :redirect_uri, :string, virtual: true
    field :return_to, :string, virtual: true
  end
end
