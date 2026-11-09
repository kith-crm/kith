defmodule Kith.Accounts.OIDC do
  @moduledoc "Issuer-bound identity ownership and atomic personal-account provisioning."
  import Ecto.Query
  alias Ecto.Multi
  alias Kith.Accounts
  alias Kith.Accounts.{Account, OIDCIdentity, User, UserIdentity, WebauthnCredential}
  alias Kith.Auth.{Policy, Principal}
  alias Kith.Repo

  def resolve(%Principal{} = principal) do
    case identity(principal) do
      nil ->
        if email_collision?(principal.email),
          do: {:error, :email_collision},
          else: {:error, :registration_required}

      identity ->
        {:ok, Repo.get!(User, identity.user_id) |> Repo.preload(:account)}
    end
  end

  def register(%Principal{} = principal, attrs) do
    cond do
      not Policy.registration_enabled?() -> {:error, :registration_disabled}
      principal.email_verified != true -> {:error, :email_unverified}
      true -> register_locked(principal, attrs)
    end
  end

  defp register_locked(principal, attrs) do
    Repo.transaction(fn ->
      lock_identity(principal)

      case resolve(principal) do
        {:ok, user} -> user
        {:error, :email_collision} -> Repo.rollback(:email_collision)
        {:error, :registration_required} -> provision(principal, attrs)
      end
    end)
  end

  defp provision(principal, attrs) do
    user_attrs = %{
      email: principal.email,
      display_name: principal.name,
      tos_accepted: Map.get(attrs, :tos_accepted, Map.get(attrs, "tos_accepted", false))
    }

    Multi.new()
    |> Multi.insert(
      :account,
      Account.registration_changeset(%Account{}, %{name: "Personal account"})
    )
    |> Multi.insert(:user, fn %{account: account} ->
      User.oidc_registration_changeset(%User{account_id: account.id, role: "admin"}, user_attrs)
    end)
    |> Multi.insert(:identity, fn %{user: user} -> identity_changeset(user, principal) end)
    |> Multi.run(:reminder_rules, fn _repo, %{account: account} ->
      {count, _} = Kith.Reminders.seed_default_rules(account.id)
      {:ok, count}
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{user: user, account: account}} -> %{user | account: account}
      {:error, :user, changeset, _} -> Repo.rollback(registration_error(changeset))
      {:error, _, changeset, _} -> Repo.rollback(changeset)
    end
  end

  defp registration_error(changeset) do
    if Enum.any?(changeset.errors, fn
         {:email, {_, options}} ->
           options[:validation] == :unsafe_unique or options[:constraint] == :unique

         _ ->
           false
       end),
       do: :email_collision,
       else: changeset
  end

  @doc "Links after the web completion has verified same-user transaction intent."
  def link(%User{} = user, %Principal{} = principal) do
    with_user_lock(user, fn persisted ->
      require_fresh!(user, persisted)
      lock_identity(principal)

      case identity(principal) do
        nil ->
          insert_identity(persisted, principal)

        %{user_id: owner} = identity when owner == user.id ->
          identity

        _ ->
          Repo.rollback(:identity_in_use)
      end
    end)
  end

  defp insert_identity(user, principal) do
    case Repo.insert(identity_changeset(user, principal)) do
      {:ok, identity} -> identity
      {:error, _} -> Repo.rollback(:identity_in_use)
    end
  end

  def unlink(%User{} = user, id) do
    case delete_login_method(user, OIDCIdentity, id, :last_login_method, true) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  def list(%User{id: user_id}) do
    Repo.all(from(i in OIDCIdentity, where: i.user_id == ^user_id, order_by: i.id))
  end

  # All interactive-method removals share this users-row lock. Re-read state after
  # acquiring it: caller structs may predate another removal or policy change.
  @doc false
  def delete_login_method(user, schema, id, last_error, require_fresh \\ false) do
    with_user_lock(user, fn persisted ->
      if require_fresh, do: require_fresh!(user, persisted)

      remove_owned_method(persisted, schema, id, last_error)
    end)
  end

  defp remove_owned_method(user, schema, id, last_error) do
    with {:ok, id} when id > 0 and id <= 9_223_372_036_854_775_807 <- Ecto.Type.cast(:integer, id),
         %{} = credential <- Repo.get_by(schema, id: id, user_id: user.id) do
      removed = Repo.delete!(credential)
      unless usable_login_method?(user), do: Repo.rollback(last_error)
      removed
    else
      _ -> Repo.rollback(:not_found)
    end
  end

  @doc false
  def usable_login_method?(%User{} = user) do
    usable_password?(user) or usable_passkey?(user) or usable_legacy?(user) or usable_oidc?(user)
  end

  defp usable_password?(user) do
    Policy.password_login_enabled?() and is_binary(user.hashed_password) and
      user.hashed_password != ""
  end

  defp usable_passkey?(user) do
    Application.get_env(:kith, :passkeys_enabled, false) == true and
      Repo.exists?(from(c in WebauthnCredential, where: c.user_id == ^user.id))
  end

  defp usable_legacy?(user) do
    providers =
      for {provider, opts} <- Accounts.oauth_providers(),
          present?(opts[:client_id]) and present?(opts[:client_secret]),
          do: to_string(provider)

    Repo.exists?(
      from(i in UserIdentity, where: i.user_id == ^user.id and i.provider in ^providers)
    )
  end

  defp usable_oidc?(user) do
    config = Application.fetch_env!(:kith, :auth)
    issuer = if config.oidc_enabled, do: config.oidc[:issuer]

    is_binary(issuer) and
      Repo.exists?(from(i in OIDCIdentity, where: i.user_id == ^user.id and i.issuer == ^issuer))
  end

  defp with_user_lock(user, fun) do
    Repo.transaction(fn ->
      case Repo.one(from(u in User, where: u.id == ^user.id, lock: "FOR UPDATE")) do
        nil -> Repo.rollback(:not_found)
        persisted -> fun.(persisted)
      end
    end)
  end

  # Provisional conservative sudo gate. Task 7 replaces this with persisted,
  # MFA-aware authentication evidence; a provider auth_time alone is insufficient.
  defp require_fresh!(user, persisted) do
    fresh? =
      case user.authenticated_at do
        %DateTime{} = timestamp ->
          Accounts.sudo_mode?(user) and DateTime.compare(timestamp, DateTime.utc_now()) != :gt

        _ ->
          false
      end

    unless fresh? and not persisted.totp_enabled, do: Repo.rollback(:reauthentication_required)
  end

  defp identity(principal),
    do: Repo.get_by(OIDCIdentity, issuer: principal.issuer, subject: principal.subject)

  defp identity_changeset(user, principal),
    do:
      OIDCIdentity.changeset(%OIDCIdentity{}, %{
        user_id: user.id,
        issuer: principal.issuer,
        subject: principal.subject
      })

  defp email_collision?(email) when is_binary(email),
    do: Repo.exists?(from(u in User, where: u.email == ^email))

  defp email_collision?(_), do: false
  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp lock_identity(principal) do
    # Parameterized, transaction-scoped lock serializes first signup/link for the
    # exact tuple; uniqueness remains the database invariant. Hash collisions only
    # serialize unrelated requests, never change the identity lookup key.
    key = Jason.encode!([principal.issuer, principal.subject])
    Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [key])
  end
end
