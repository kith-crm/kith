defmodule Kith.Accounts.Scope do
  @moduledoc """
  Defines the scope of the caller to be used throughout the app.

  The scope carries the current user and their account, providing
  authorization context and tenant isolation for all operations.
  """

  alias Kith.Accounts.{Account, User}

  defstruct user: nil, account: nil

  @doc """
  Creates a scope for the given user.

  Extracts the account from the user's preloaded association.
  Returns nil if no user is given.
  """
  def for_user(%User{account: %Account{} = account} = user) do
    %__MODULE__{user: user, account: account}
  end

  def for_user(%User{} = user) do
    %__MODULE__{user: user}
  end

  def for_user(nil), do: nil

  @doc """
  Builds a scope for background and adapter callers that have an account id but
  no user. `user` is nil, so callers needing an audit actor must supply one.
  """
  def for_account_id(account_id) do
    %__MODULE__{user: nil, account: Kith.Repo.get!(Kith.Accounts.Account, account_id)}
  end
end
