defmodule Kith.AccountsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `Kith.Accounts` context.
  """

  import Ecto.Query

  alias Kith.Accounts
  alias Kith.Accounts.Scope

  def unique_user_email, do: "user#{System.unique_integer()}@example.com"
  def valid_user_password, do: "hello world!!"

  def unique_account_name, do: "Account #{System.unique_integer([:positive])}"

  def valid_user_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      email: unique_user_email(),
      password: valid_user_password(),
      name: unique_account_name(),
      tos_accepted: true
    })
  end

  def user_fixture(attrs \\ %{}) do
    {role, attrs} = Map.pop(attrs, :role, "admin")

    {:ok, user} =
      attrs
      |> valid_user_attributes()
      |> Accounts.register_user()

    if role != "admin" do
      user
      |> Ecto.Changeset.change(%{role: role})
      |> Kith.Repo.update!()
    else
      user
    end
  end

  def enable_optional_features(user, keys) do
    account = Accounts.get_account!(user.account_id)
    flags = Enum.reduce(keys, account.feature_flags || %{}, &Map.put(&2, &1, true))
    {:ok, updated} = Accounts.update_account(account, %{feature_flags: flags})
    updated
  end

  def user_scope_fixture do
    user = user_fixture()
    user_scope_fixture(user)
  end

  def user_scope_fixture(user) do
    Scope.for_user(user)
  end

  def extract_user_token(fun) do
    {:ok, captured_email} = fun.(&"[TOKEN]#{&1}[TOKEN]")
    [_, token | _] = String.split(captured_email.text_body, "[TOKEN]")
    token
  end

  def override_token_authenticated_at(token, authenticated_at) when is_binary(token) do
    Kith.Repo.update_all(
      from(t in Accounts.UserToken,
        where: t.token == ^token
      ),
      set: [authenticated_at: authenticated_at]
    )
  end

  def offset_user_token(token, amount_to_add, unit) do
    dt = DateTime.add(DateTime.utc_now(:second), amount_to_add, unit)

    Kith.Repo.update_all(
      from(ut in Accounts.UserToken, where: ut.token == ^token),
      set: [inserted_at: dt, authenticated_at: dt]
    )
  end
end
