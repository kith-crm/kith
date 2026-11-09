defmodule Kith.Auth.Principal do
  @moduledoc "Verified protocol identity, without provider tokens or local account policy."
  @enforce_keys [:issuer, :subject]
  defstruct [:issuer, :subject, :email, :email_verified, :name, :auth_time]
end
