defmodule Kith.Accounts do
  @moduledoc """
  The Accounts context — authentication, registration, and user management.
  """

  import Ecto.Query, warn: false
  alias Kith.Repo

  alias Kith.Workers.AccountDeletionWorker
  alias Kith.Workers.AccountResetWorker
  alias Kith.Workers.DisplayNameRecomputeWorker

  alias Kith.Accounts.{
    Account,
    AccountInvitation,
    User,
    UserIdentity,
    UserNotifier,
    UserRecoveryCode,
    UserToken,
    WebauthnCredential
  }

  ## Database getters

  @doc """
  Gets a user by email.
  """
  def get_user_by_email(email) when is_binary(email) do
    Repo.get_by(User, email: email)
  end

  @doc """
  Gets a user by email and password.

  Returns nil if the email or password is invalid.
  """
  def get_user_by_email_and_password(email, password)
      when is_binary(email) and is_binary(password) do
    user = Repo.get_by(User, email: email) |> Repo.preload(:account)
    if User.valid_password?(user, password), do: user
  end

  @doc """
  Gets a single user. Preloads account.
  """
  def get_user!(id), do: Repo.get!(User, id) |> Repo.preload(:account)

  ## User registration

  @doc """
  Registers a user by creating an Account and User atomically.

  The first user on a new account always gets role "admin".
  """
  def register_user(attrs) do
    account_attrs = ensure_account_name(attrs)

    Ecto.Multi.new()
    |> Ecto.Multi.insert(:account, Account.registration_changeset(%Account{}, account_attrs))
    |> Ecto.Multi.insert(:user, fn %{account: account} ->
      %User{account_id: account.id}
      |> User.registration_changeset(attrs)
      |> Ecto.Changeset.put_change(:role, "admin")
      |> maybe_auto_confirm()
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{user: user, account: account}} ->
        {:ok, %{user | account: account}}

      {:error, :user, changeset, _changes} ->
        {:error, changeset}

      {:error, :account, changeset, _changes} ->
        {:error, changeset}
    end
  end

  defp maybe_auto_confirm(changeset) do
    if signup_double_optin?() do
      changeset
    else
      Ecto.Changeset.put_change(changeset, :confirmed_at, DateTime.utc_now(:second))
    end
  end

  defp signup_double_optin? do
    Application.get_env(:kith, :signup_double_optin, false)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking user registration changes.
  """
  def change_user_registration(%User{} = user, attrs \\ %{}, opts \\ []) do
    User.registration_changeset(
      user,
      attrs,
      [hash_password: false, validate_unique: false] ++ opts
    )
  end

  ## Settings

  @doc """
  Checks whether the user is in sudo mode.

  The user is in sudo mode when the last authentication was done no further
  than 20 minutes ago.
  """
  def sudo_mode?(user, minutes \\ -20)

  def sudo_mode?(%User{authenticated_at: ts}, minutes) when is_struct(ts, DateTime) do
    DateTime.after?(ts, DateTime.utc_now() |> DateTime.add(minutes, :minute))
  end

  def sudo_mode?(_user, _minutes), do: false

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user email.
  """
  def change_user_email(user, attrs \\ %{}, opts \\ []) do
    User.email_changeset(user, attrs, opts)
  end

  @doc """
  Updates the user email using the given token.
  """
  def update_user_email(user, token) do
    context = "change:#{user.email}"

    Repo.transact(fn ->
      with {:ok, query} <- UserToken.verify_change_email_token_query(token, context),
           %UserToken{sent_to: email} <- Repo.one(query),
           {:ok, user} <- Repo.update(User.email_changeset(user, %{email: email})),
           {_count, _result} <-
             Repo.delete_all(from(UserToken, where: [user_id: ^user.id, context: ^context])) do
        {:ok, user}
      else
        _ -> {:error, :transaction_aborted}
      end
    end)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user password.
  """
  def change_user_password(user, attrs \\ %{}, opts \\ []) do
    User.password_changeset(user, attrs, opts)
  end

  @doc """
  Updates the user password.

  Returns a tuple with the updated user, as well as a list of expired tokens.
  """
  def update_user_password(user, attrs) do
    user
    |> User.password_changeset(attrs)
    |> update_user_and_delete_all_tokens()
  end

  ## Confirmation

  @doc """
  Delivers the confirmation instructions to the given user.
  """
  def deliver_user_confirmation_instructions(%User{} = user, confirmation_url_fun)
      when is_function(confirmation_url_fun, 1) do
    if user.confirmed_at do
      {:error, :already_confirmed}
    else
      {encoded_token, user_token} = UserToken.build_email_token(user, "confirm")
      Repo.insert!(user_token)
      UserNotifier.deliver_confirmation_instructions(user, confirmation_url_fun.(encoded_token))
    end
  end

  @doc """
  Confirms a user by the given token.
  """
  def confirm_user(token) do
    with {:ok, query} <- UserToken.verify_confirm_token_query(token),
         %User{} = user <- Repo.one(query),
         {:ok, %{user: user}} <-
           Ecto.Multi.new()
           |> Ecto.Multi.update(:user, User.confirm_changeset(user))
           |> Ecto.Multi.delete_all(
             :tokens,
             UserToken.by_user_and_context_query(user.id, "confirm")
           )
           |> Repo.transaction() do
      {:ok, user}
    else
      _ -> :error
    end
  end

  ## Password Reset

  @doc """
  Delivers the reset password instructions to the given user.
  """
  def deliver_user_reset_password_instructions(%User{} = user, reset_password_url_fun)
      when is_function(reset_password_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "reset_password")
    Repo.insert!(user_token)
    UserNotifier.deliver_reset_password_instructions(user, reset_password_url_fun.(encoded_token))
  end

  @doc """
  Gets the user by reset password token.
  """
  def get_user_by_reset_password_token(token) do
    with {:ok, query} <- UserToken.verify_reset_password_token_query(token),
         %User{} = user <- Repo.one(query) do
      user
    else
      _ -> nil
    end
  end

  @doc """
  Resets the user password.

  Deletes all tokens for the given user (invalidating all sessions).
  """
  def reset_user_password(user, attrs) do
    user
    |> User.password_changeset(attrs)
    |> update_user_and_delete_all_tokens()
  end

  ## Session

  @doc """
  Generates a session token.
  """
  def generate_user_session_token(user) do
    {token, user_token} = UserToken.build_session_token(user)
    Repo.insert!(user_token)
    token
  end

  @doc """
  Gets the user with the given signed token.

  Returns `{user, token_inserted_at}` or `nil`.
  The user has the account preloaded.
  """
  def get_user_by_session_token(token) do
    {:ok, query} = UserToken.verify_session_token_query(token)
    Repo.one(query)
  end

  ## Email delivery

  @doc ~S"""
  Delivers the update email instructions to the given user.
  """
  def deliver_user_update_email_instructions(%User{} = user, current_email, update_email_url_fun)
      when is_function(update_email_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "change:#{current_email}")

    Repo.insert!(user_token)
    UserNotifier.deliver_update_email_instructions(user, update_email_url_fun.(encoded_token))
  end

  @doc """
  Deletes the signed token with the given context.
  """
  def delete_user_session_token(token) do
    Repo.delete_all(from(UserToken, where: [token: ^token, context: "session"]))
    :ok
  end

  ## API Tokens

  @doc """
  Generates an API bearer token. Returns `{raw_token, %UserToken{}}`.

  The raw token is shown once. The DB stores the SHA-256 hash.
  """
  def generate_api_token(user) do
    {raw_token, user_token} = UserToken.build_api_token(user)
    inserted = Repo.insert!(user_token)
    {raw_token, inserted}
  end

  @doc """
  Validates an API bearer token and returns `{user, token_record}` or nil.
  """
  def get_user_by_api_token(raw_token) do
    case UserToken.verify_api_token_query(raw_token) do
      {:ok, query} -> Repo.one(query)
      :error -> nil
    end
  end

  @doc """
  Lists all API tokens for a user.
  """
  def list_api_tokens(user) do
    from(t in UserToken,
      where: t.user_id == ^user.id and t.context == "api",
      order_by: [desc: t.inserted_at]
    )
    |> Repo.all()
  end

  @doc """
  Revokes an API token by its DB id (scoped to user).
  """
  def revoke_api_token(user, token_id) do
    case Repo.get_by(UserToken, id: token_id, user_id: user.id, context: "api") do
      nil -> {:error, :not_found}
      token -> Repo.delete(token)
    end
  end

  @doc """
  Revokes the API token matching the given raw token string.
  """
  def revoke_api_token_by_value(raw_token) do
    case Base.url_decode64(raw_token, padding: false) do
      {:ok, decoded} ->
        hashed = :crypto.hash(:sha256, decoded)

        case Repo.get_by(UserToken, token: hashed, context: "api") do
          nil -> {:error, :not_found}
          token -> Repo.delete(token)
        end

      :error ->
        {:error, :invalid_token}
    end
  end

  ## TOTP Two-Factor Authentication

  @totp_issuer Application.compile_env(:kith, :totp_issuer, "Kith")

  @doc """
  Generates a new TOTP secret (base32-encoded, 20 bytes of entropy).
  """
  def generate_totp_secret do
    :crypto.strong_rand_bytes(20) |> Base.encode32(padding: false)
  end

  @doc """
  Returns the otpauth:// URI for QR code enrollment.
  """
  def totp_uri(secret, email) do
    issuer = Application.get_env(:kith, :totp_issuer, @totp_issuer)

    "otpauth://totp/#{URI.encode(issuer)}:#{URI.encode(email)}?secret=#{secret}&issuer=#{URI.encode(issuer)}"
  end

  @doc """
  Generates a QR code PNG as a base64 data URL for the given TOTP URI.
  """
  def totp_qr_code_data_url(uri) do
    png =
      uri
      |> EQRCode.encode()
      |> EQRCode.png(width: 300)

    "data:image/png;base64," <> Base.encode64(png)
  end

  @doc """
  Verifies a TOTP code against a secret. Allows window of 1 (previous period).
  """
  def valid_totp_code?(secret, code) do
    :pot.valid_totp(code, secret, window: 1, addwindow: 1)
  end

  @doc """
  Enables TOTP for a user after verifying the confirmation code.

  Stores the encrypted secret, sets totp_enabled to true, and generates
  recovery codes. Returns `{:ok, user, raw_recovery_codes}` or `{:error, reason}`.
  """
  def enable_totp(user, secret, code) do
    if valid_totp_code?(secret, code) do
      do_enable_totp(user, secret)
    else
      {:error, :invalid_code}
    end
  end

  defp do_enable_totp(user, secret) do
    Repo.transact(fn ->
      changeset = Ecto.Changeset.change(user, %{totp_secret: secret, totp_enabled: true})

      with {:ok, user} <- Repo.update(changeset),
           raw_codes <- generate_recovery_codes(user) do
        {:ok, {user, raw_codes}}
      end
    end)
  end

  @doc """
  Disables TOTP for a user. Clears secret and deletes all recovery codes.
  """
  def disable_totp(user) do
    Repo.transact(fn ->
      changeset =
        user
        |> Ecto.Changeset.change(%{totp_secret: nil, totp_enabled: false})

      with {:ok, user} <- Repo.update(changeset) do
        Repo.delete_all(from(rc in UserRecoveryCode, where: rc.user_id == ^user.id))
        {:ok, user}
      end
    end)
  end

  ## Recovery Codes

  @recovery_code_count 8

  @doc """
  Generates recovery codes for a user, replacing any existing ones.

  Returns the list of raw (unhashed) codes formatted as "XXXX-XXXX".
  """
  def generate_recovery_codes(user) do
    # Delete existing codes
    Repo.delete_all(from(rc in UserRecoveryCode, where: rc.user_id == ^user.id))

    raw_codes =
      for _i <- 1..@recovery_code_count do
        raw = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
        String.slice(raw, 0, 4) <> "-" <> String.slice(raw, 4, 4)
      end

    now = DateTime.utc_now(:second)

    entries =
      Enum.map(raw_codes, fn code ->
        %{
          user_id: user.id,
          hashed_code: UserRecoveryCode.hash_code(code),
          inserted_at: now
        }
      end)

    Repo.insert_all(UserRecoveryCode, entries)
    raw_codes
  end

  @doc """
  Returns the count of remaining recovery codes for a user.
  """
  def recovery_code_count(user) do
    Repo.aggregate(
      from(rc in UserRecoveryCode, where: rc.user_id == ^user.id),
      :count
    )
  end

  @doc """
  Verifies and consumes a recovery code. Returns true if valid (and deletes it).
  """
  def use_recovery_code(user, code) do
    codes = Repo.all(from(rc in UserRecoveryCode, where: rc.user_id == ^user.id))

    Enum.find(codes, fn rc -> UserRecoveryCode.valid_code?(code, rc.hashed_code) end)
    |> case do
      nil ->
        false

      rc ->
        Repo.delete!(rc)
        true
    end
  end

  ## WebAuthn Credentials

  @doc """
  Lists all WebAuthn credentials for a user.
  """
  def list_webauthn_credentials(user) do
    from(wc in WebauthnCredential,
      where: wc.user_id == ^user.id,
      order_by: [desc: wc.inserted_at]
    )
    |> Repo.all()
  end

  @doc """
  Gets a single WebAuthn credential by ID, scoped to user.
  """
  def get_webauthn_credential(user, id) do
    Repo.get_by(WebauthnCredential, id: id, user_id: user.id)
  end

  @doc """
  Gets a WebAuthn credential by its credential_id (binary).
  """
  def get_webauthn_credential_by_credential_id(credential_id) do
    Repo.get_by(WebauthnCredential, credential_id: credential_id)
    |> Repo.preload(user: :account)
  end

  @doc """
  Gets all WebAuthn credentials for a user as `{credential_id, cose_key}` tuples
  suitable for passing to `Wax.new_authentication_challenge/1`.
  """
  def get_webauthn_allow_credentials(user) do
    from(wc in WebauthnCredential,
      where: wc.user_id == ^user.id,
      select: {wc.credential_id, wc.public_key}
    )
    |> Repo.all()
    |> Enum.map(fn {cred_id, pk_binary} ->
      {cred_id, :erlang.binary_to_term(pk_binary)}
    end)
  end

  @doc """
  Registers a new WebAuthn credential for a user.

  Takes the raw authenticator_data from `Wax.register/3` and stores the
  credential_id, public_key (as erlang term binary), and sign_count.
  """
  def register_webauthn_credential(user, auth_data, name) do
    cred_data = auth_data.attested_credential_data

    attrs = %{
      user_id: user.id,
      credential_id: cred_data.credential_id,
      public_key: :erlang.term_to_binary(cred_data.credential_public_key),
      sign_count: auth_data.sign_count,
      name: name
    }

    %WebauthnCredential{}
    |> WebauthnCredential.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates the sign_count and last_used_at after successful authentication.
  """
  def touch_webauthn_credential(credential, sign_count) do
    credential
    |> Ecto.Changeset.change(%{sign_count: sign_count, last_used_at: DateTime.utc_now(:second)})
    |> Repo.update()
  end

  @doc """
  Deletes a WebAuthn credential, with safety check.

  Returns `{:error, :last_credential}` if removing would leave the user with
  no login method (no password and no other WebAuthn credentials and no OAuth).
  """
  def delete_webauthn_credential(user, credential_id) do
    case get_webauthn_credential(user, credential_id) do
      nil ->
        {:error, :not_found}

      credential ->
        other_cred_count =
          Repo.aggregate(
            from(wc in WebauthnCredential,
              where: wc.user_id == ^user.id and wc.id != ^credential.id
            ),
            :count
          )

        has_password = is_binary(user.hashed_password) and user.hashed_password != ""

        if other_cred_count == 0 and not has_password do
          {:error, :last_credential}
        else
          Repo.delete(credential)
        end
    end
  end

  @doc """
  Returns the Wax options for this application (origin, rp_id).
  """
  def webauthn_opts do
    origin = Application.get_env(:wax_, :origin, "http://localhost:4000")
    rp_id = Application.get_env(:wax_, :rp_id, :auto)
    [origin: origin, rp_id: rp_id]
  end

  @doc """
  Checks if the user has any login method remaining
  (password, WebAuthn credentials, or OAuth links).
  """
  def has_login_method?(user) do
    has_password = is_binary(user.hashed_password) and user.hashed_password != ""

    webauthn_count =
      Repo.aggregate(
        from(wc in WebauthnCredential, where: wc.user_id == ^user.id),
        :count
      )

    oauth_count =
      Repo.aggregate(
        from(ui in UserIdentity, where: ui.user_id == ^user.id),
        :count
      )

    has_password or webauthn_count > 0 or oauth_count > 0
  end

  ## OAuth Identities

  @doc """
  Returns the configured OAuth providers.
  """
  def oauth_providers do
    Application.get_env(:kith, :oauth_providers, %{})
  end

  @doc """
  Returns the assent strategy config for a provider.
  """
  def oauth_provider_config(provider) when is_binary(provider) do
    case Map.get(oauth_providers(), provider) do
      nil -> {:error, :unknown_provider}
      config -> {:ok, config}
    end
  end

  @doc """
  Finds a UserIdentity by provider and uid.
  """
  def get_identity_by_provider_uid(provider, uid) do
    Repo.get_by(UserIdentity, provider: provider, uid: uid)
    |> case do
      nil -> nil
      identity -> Repo.preload(identity, user: :account)
    end
  end

  @doc """
  Lists all OAuth identities for a user.
  """
  def list_user_identities(user) do
    from(ui in UserIdentity, where: ui.user_id == ^user.id)
    |> Repo.all()
  end

  @doc """
  Creates or updates a UserIdentity from an OAuth callback.

  If an identity with the same provider+uid exists, updates tokens.
  Otherwise creates a new identity linked to the given user.
  """
  def upsert_identity(user, provider, uid, token_attrs) do
    case get_identity_by_provider_uid(provider, uid) do
      nil ->
        attrs =
          Map.merge(token_attrs, %{
            provider: provider,
            uid: uid,
            user_id: user.id
          })

        %UserIdentity{}
        |> UserIdentity.changeset(attrs)
        |> Repo.insert()

      existing ->
        existing
        |> UserIdentity.update_tokens_changeset(token_attrs)
        |> Repo.update()
    end
  end

  @doc """
  Registers a new user via OAuth. Creates Account + User + UserIdentity atomically.

  The user is auto-confirmed since the OAuth provider verified the email.
  """
  def register_oauth_user(provider, uid, user_info, token_attrs) do
    email = user_info["email"]

    account_name = user_info["name"] || email_to_account_name(email)

    Ecto.Multi.new()
    |> Ecto.Multi.insert(
      :account,
      Account.registration_changeset(%Account{}, %{name: account_name})
    )
    |> Ecto.Multi.insert(:user, fn %{account: account} ->
      # OAuth users get a random password (they log in via OAuth, not password)
      random_password = :crypto.strong_rand_bytes(32) |> Base.encode64()

      %User{account_id: account.id}
      |> User.registration_changeset(%{email: email, password: random_password})
      |> Ecto.Changeset.put_change(:role, "admin")
      |> Ecto.Changeset.put_change(:confirmed_at, DateTime.utc_now(:second))
      |> Ecto.Changeset.put_change(
        :display_name,
        user_info["name"] || user_info["preferred_username"]
      )
    end)
    |> Ecto.Multi.insert(:identity, fn %{user: user} ->
      UserIdentity.changeset(%UserIdentity{}, %{
        user_id: user.id,
        provider: provider,
        uid: uid,
        access_token: token_attrs[:access_token],
        refresh_token: token_attrs[:refresh_token],
        expires_at: token_attrs[:expires_at]
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{user: user, account: account}} ->
        {:ok, %{user | account: account}}

      {:error, :user, changeset, _} ->
        {:error, changeset}

      {:error, :account, changeset, _} ->
        {:error, changeset}

      {:error, :identity, changeset, _} ->
        {:error, changeset}
    end
  end

  @doc """
  Deletes an OAuth identity. Returns error if it would leave user with no login method.
  """
  def delete_identity(user, identity_id) do
    case Repo.get_by(UserIdentity, id: identity_id, user_id: user.id) do
      nil ->
        {:error, :not_found}

      identity ->
        # Check if user would still have a login method
        other_identity_count =
          Repo.aggregate(
            from(ui in UserIdentity, where: ui.user_id == ^user.id and ui.id != ^identity.id),
            :count
          )

        has_password = is_binary(user.hashed_password) and user.hashed_password != ""

        webauthn_count =
          Repo.aggregate(
            from(wc in WebauthnCredential, where: wc.user_id == ^user.id),
            :count
          )

        if has_password or other_identity_count > 0 or webauthn_count > 0 do
          Repo.delete(identity)
        else
          {:error, :last_login_method}
        end
    end
  end

  @doc """
  Extracts token attributes from an assent callback result.
  """
  def extract_token_attrs(token_map) do
    expires_at =
      case token_map["expires_in"] do
        seconds when is_integer(seconds) ->
          DateTime.utc_now() |> DateTime.add(seconds, :second) |> DateTime.truncate(:second)

        _ ->
          nil
      end

    %{
      access_token: token_map["access_token"],
      access_token_secret: token_map["access_token_secret"],
      refresh_token: token_map["refresh_token"],
      token_url: token_map["token_url"],
      expires_at: expires_at
    }
  end

  ## Account CRUD

  @doc """
  Gets an account by ID.
  """
  def get_account!(id), do: Repo.get!(Account, id)

  @doc """
  Updates an account's settings.
  """
  def update_account(%Account{} = account, attrs) do
    account
    |> Account.settings_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Permanently deletes an account and all associated data.
  """
  def delete_account(%Account{} = account) do
    Repo.delete(account)
  end

  @doc """
  Lists all users for an account.
  """
  def list_users(account_id) do
    from(u in User, where: u.account_id == ^account_id, order_by: [asc: u.email])
    |> Repo.all()
  end

  @doc """
  Updates a user's profile settings.

  If display_name_format changes, enqueues an Oban job to recompute
  display_name on all contacts in the account.
  """
  def update_user_profile(%User{} = user, attrs) do
    changeset = User.profile_changeset(user, attrs)
    format_changed? = Ecto.Changeset.get_change(changeset, :display_name_format) != nil

    case Repo.update(changeset) do
      {:ok, updated_user} = result ->
        if format_changed? do
          %{account_id: user.account_id, display_name_format: updated_user.display_name_format}
          |> DisplayNameRecomputeWorker.new()
          |> Oban.insert()
        end

        result

      error ->
        error
    end
  end

  @doc """
  Returns user settings fields as a map.
  """
  def get_user_settings(%User{} = user) do
    Map.take(user, [
      :display_name,
      :display_name_format,
      :timezone,
      :locale,
      :currency,
      :temperature_unit,
      :default_profile_tab,
      :me_contact_id
    ])
  end

  @doc """
  Links the user to their own contact card.
  Validates that the contact belongs to the user's account.
  """
  def link_me_contact(%User{} = user, contact_id) do
    contact = Kith.Contacts.get_contact!(user.account_id, contact_id)

    if contact.account_id == user.account_id do
      user
      |> Ecto.Changeset.change(%{me_contact_id: contact.id})
      |> Repo.update()
    else
      {:error, :contact_not_in_account}
    end
  end

  @doc """
  Unlinks the user's me_contact.
  """
  def unlink_me_contact(%User{} = user) do
    user
    |> Ecto.Changeset.change(%{me_contact_id: nil})
    |> Repo.update()
  end

  @doc """
  Updates a user's role (admin-only operation).
  """
  def update_user_role(%User{} = user, attrs) do
    user
    |> User.role_changeset(attrs)
    |> Repo.update()
  end

  ## Token helper

  defp ensure_account_name(attrs) when is_map(attrs) do
    has_name = Map.has_key?(attrs, :name) || Map.has_key?(attrs, "name")

    if has_name do
      attrs
    else
      name = email_to_account_name(attrs[:email] || attrs["email"])

      # Preserve key type consistency (atom vs string) for Ecto.Changeset.cast
      if map_has_string_keys?(attrs),
        do: Map.put(attrs, "name", name),
        else: Map.put(attrs, :name, name)
    end
  end

  defp map_has_string_keys?(map) do
    map |> Map.keys() |> Enum.any?(&is_binary/1)
  end

  defp email_to_account_name(nil), do: "My Account"

  defp email_to_account_name(email) when is_binary(email) do
    email |> String.split("@") |> hd() |> String.capitalize() |> Kernel.<>("'s Account")
  end

  defp update_user_and_delete_all_tokens(changeset) do
    Repo.transact(fn ->
      with {:ok, user} <- Repo.update(changeset) do
        tokens_to_expire = Repo.all_by(UserToken, user_id: user.id)

        Repo.delete_all(from(t in UserToken, where: t.id in ^Enum.map(tokens_to_expire, & &1.id)))

        {:ok, {user, tokens_to_expire}}
      end
    end)
  end

  ## Invitations ────────────────────────────────────────────────────────────

  @doc """
  Creates an invitation and sends the invitation email.
  Validates email is not already a user in the account and not already invited (pending).
  """
  def create_invitation(account_id, invited_by_id, attrs, invitation_url_fun)
      when is_function(invitation_url_fun, 1) do
    email = attrs[:email] || attrs["email"]

    with :ok <- validate_not_existing_user(account_id, email),
         :ok <- validate_not_pending_invitation(account_id, email) do
      {raw_token, token_hash} = AccountInvitation.build_token()

      invitation_attrs =
        Map.merge(attrs, %{
          account_id: account_id,
          invited_by_id: invited_by_id
        })

      changeset = AccountInvitation.changeset(%AccountInvitation{}, invitation_attrs)

      changeset =
        changeset
        |> Ecto.Changeset.put_change(:token_hash, token_hash)
        |> Ecto.Changeset.put_change(:expires_at, AccountInvitation.token_expiry())

      case Repo.insert(changeset) do
        {:ok, invitation} ->
          account = get_account!(account_id)
          invited_by = get_user!(invited_by_id)

          UserNotifier.deliver_invitation(email, %{
            account_name: account.name,
            invited_by_name: invited_by.display_name || invited_by.email,
            role: invitation.role,
            url: invitation_url_fun.(raw_token)
          })

          Kith.AuditLogs.log_event(account_id, invited_by, :invitation_sent,
            metadata: %{email: email, role: invitation.role}
          )

          {:ok, invitation}

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end

  @doc """
  Accepts an invitation: validates token, creates user, marks invitation accepted.
  """
  def accept_invitation(raw_token, user_params) do
    with {:ok, invitation} <- get_valid_invitation_by_token(raw_token) do
      Ecto.Multi.new()
      |> Ecto.Multi.insert(:user, fn _changes ->
        %User{account_id: invitation.account_id}
        |> User.registration_changeset(user_params)
        |> Ecto.Changeset.put_change(:role, invitation.role)
        |> Ecto.Changeset.put_change(:confirmed_at, DateTime.utc_now(:second))
      end)
      |> Ecto.Multi.update(:invitation, fn _changes ->
        Ecto.Changeset.change(invitation, %{accepted_at: DateTime.utc_now(:second)})
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{user: user}} -> {:ok, Repo.preload(user, :account)}
        {:error, :user, changeset, _} -> {:error, changeset}
        {:error, :invitation, changeset, _} -> {:error, changeset}
      end
    end
  end

  @doc "Revokes a pending invitation by deleting it."
  def revoke_invitation(account_id, invitation_id) do
    case Repo.get_by(AccountInvitation, id: invitation_id, account_id: account_id) do
      nil ->
        {:error, :not_found}

      %AccountInvitation{accepted_at: accepted_at} when not is_nil(accepted_at) ->
        {:error, :already_accepted}

      invitation ->
        Repo.delete(invitation)
    end
  end

  @doc "Resends the invitation email with the same token."
  def resend_invitation(account_id, invitation_id, invitation_url_fun) do
    case Repo.get_by(AccountInvitation, id: invitation_id, account_id: account_id) do
      nil ->
        {:error, :not_found}

      %AccountInvitation{accepted_at: accepted_at} when not is_nil(accepted_at) ->
        {:error, :already_accepted}

      invitation ->
        # We can't reconstruct the raw token from the hash, so we generate a new one
        {raw_token, token_hash} = AccountInvitation.build_token()

        invitation
        |> Ecto.Changeset.change(%{
          token_hash: token_hash,
          expires_at: AccountInvitation.token_expiry()
        })
        |> Repo.update()
        |> case do
          {:ok, updated} ->
            account = get_account!(account_id)

            UserNotifier.deliver_invitation(updated.email, %{
              account_name: account.name,
              invited_by_name: "The account admin",
              role: updated.role,
              url: invitation_url_fun.(raw_token)
            })

            {:ok, updated}

          error ->
            error
        end
    end
  end

  @doc "Lists all invitations for the account."
  def list_invitations(account_id) do
    from(i in AccountInvitation,
      where: i.account_id == ^account_id,
      order_by: [desc: i.inserted_at],
      preload: [:invited_by]
    )
    |> Repo.all()
  end

  @doc "Gets a pending invitation by token (public, no scope needed)."
  def get_invitation_by_token(raw_token) do
    case AccountInvitation.hash_token(raw_token) do
      {:ok, token_hash} ->
        invitation =
          from(i in AccountInvitation,
            where: i.token_hash == ^token_hash,
            preload: [:account]
          )
          |> Repo.one()

        case invitation do
          nil -> {:error, :not_found}
          inv -> {:ok, inv}
        end

      :error ->
        {:error, :invalid_token}
    end
  end

  defp get_valid_invitation_by_token(raw_token) do
    with {:ok, invitation} <- get_invitation_by_token(raw_token) do
      cond do
        AccountInvitation.accepted?(invitation) -> {:error, :already_accepted}
        AccountInvitation.expired?(invitation) -> {:error, :expired}
        true -> {:ok, invitation}
      end
    end
  end

  defp validate_not_existing_user(account_id, email) do
    exists? =
      Repo.exists?(from(u in User, where: u.account_id == ^account_id and u.email == ^email))

    if exists?, do: {:error, :already_a_member}, else: :ok
  end

  defp validate_not_pending_invitation(account_id, email) do
    exists? =
      Repo.exists?(
        from(i in AccountInvitation,
          where: i.account_id == ^account_id and i.email == ^email and is_nil(i.accepted_at)
        )
      )

    if exists?, do: {:error, :already_invited}, else: :ok
  end

  ## Role Management ────────────────────────────────────────────────────────

  @doc """
  Changes a user's role. Admin cannot change their own role.
  Cannot demote the last admin.
  """
  def change_user_role(actor_id, target_user_id, new_role)
      when is_binary(new_role) and new_role in ~w(admin editor viewer) do
    if actor_id == target_user_id do
      {:error, :cannot_change_own_role}
    else
      target = get_user!(target_user_id)

      with :ok <- check_not_last_admin_demotion(target, new_role) do
        do_update_role(target, new_role)
      end
    end
  end

  defp do_update_role(user, new_role) do
    old_role = user.role

    case user |> User.role_changeset(%{role: new_role}) |> Repo.update() do
      {:ok, updated} ->
        Kith.AuditLogs.log_event(user.account_id, user, :user_role_changed,
          metadata: %{
            target_user_id: user.id,
            target_email: user.email,
            old_role: old_role,
            new_role: new_role
          }
        )

        {:ok, updated}

      error ->
        error
    end
  end

  @doc """
  Removes a user from the account. Cannot remove self or last admin.
  Invalidates all sessions within the same transaction.
  """
  def remove_user(actor_id, target_user_id) do
    if actor_id == target_user_id do
      {:error, :cannot_remove_self}
    else
      target = get_user!(target_user_id)

      with :ok <- check_not_last_admin_removal(target) do
        do_remove_user(target)
      end
    end
  end

  defp check_not_last_admin_demotion(%{role: "admin"} = target, new_role)
       when new_role != "admin" do
    check_admin_count(target.account_id)
  end

  defp check_not_last_admin_demotion(_target, _new_role), do: :ok

  defp check_not_last_admin_removal(%{role: "admin"} = target) do
    check_admin_count(target.account_id)
  end

  defp check_not_last_admin_removal(_target), do: :ok

  defp check_admin_count(account_id) do
    admin_count =
      Repo.aggregate(
        from(u in User, where: u.account_id == ^account_id and u.role == "admin"),
        :count
      )

    if admin_count <= 1, do: {:error, :last_admin}, else: :ok
  end

  defp do_remove_user(user) do
    # Snapshot user info before deletion
    user_name = user.display_name || user.email

    Ecto.Multi.new()
    |> Ecto.Multi.delete_all(
      :delete_tokens,
      from(t in UserToken, where: t.user_id == ^user.id)
    )
    |> Ecto.Multi.delete(:delete_user, user)
    |> Repo.transaction()
    |> case do
      {:ok, %{delete_user: deleted_user}} ->
        Kith.AuditLogs.create_audit_log(user.account_id, %{
          user_id: user.id,
          user_name: user_name,
          event: "user_removed",
          metadata: %{email: user.email, role: user.role}
        })

        {:ok, deleted_user}

      {:error, _step, changeset, _} ->
        {:error, changeset}
    end
  end

  ## Feature Modules ────────────────────────────────────────────────────────

  @known_modules ~w(immich)

  @doc "Returns true if a feature module is enabled for the account."
  def module_enabled?(%Account{feature_flags: flags}, module_name)
      when is_binary(module_name) do
    Map.get(flags || %{}, module_name, false) == true
  end

  def module_enabled?(%Account{}, _module_name), do: false

  @doc "Enables a feature module for the account."
  def enable_module(%Account{} = account, module_name) when module_name in @known_modules do
    new_flags = Map.put(account.feature_flags || %{}, module_name, true)

    account
    |> Ecto.Changeset.change(%{feature_flags: new_flags})
    |> Repo.update()
  end

  def enable_module(_account, _module_name), do: {:error, :unknown_module}

  @doc "Disables a feature module for the account."
  def disable_module(%Account{} = account, module_name) when module_name in @known_modules do
    new_flags = Map.put(account.feature_flags || %{}, module_name, false)

    account
    |> Ecto.Changeset.change(%{feature_flags: new_flags})
    |> Repo.update()
  end

  def disable_module(_account, _module_name), do: {:error, :unknown_module}

  @doc "Returns all known modules with their enabled/disabled status."
  def list_modules(%Account{} = account) do
    Enum.map(@known_modules, fn name ->
      %{name: name, enabled: module_enabled?(account, name)}
    end)
  end

  ## Account Reset & Deletion ──────────────────────────────────────────────

  @doc """
  Requests an account data reset. Admin must type "RESET" exactly.
  Queues an Oban job to perform the actual reset.
  """
  def request_account_reset(account_id, "RESET") do
    %{account_id: account_id}
    |> AccountResetWorker.new()
    |> Oban.insert()

    {:ok, :queued}
  end

  def request_account_reset(_account_id, _confirmation), do: {:error, :invalid_confirmation}

  @doc """
  Requests full account deletion. Admin must type the exact account name.
  Immediately invalidates all sessions, then queues Oban job for deletion.
  """
  def request_account_deletion(account_id, confirmation_name) do
    account = get_account!(account_id)

    if account.name == confirmation_name do
      # Immediately invalidate all sessions for all users in the account
      user_ids = from(u in User, where: u.account_id == ^account_id, select: u.id) |> Repo.all()

      from(t in UserToken, where: t.user_id in ^user_ids)
      |> Repo.delete_all()

      # Queue the deletion job
      %{account_id: account_id}
      |> AccountDeletionWorker.new()
      |> Oban.insert()

      {:ok, :queued}
    else
      {:error, :invalid_confirmation}
    end
  end

  @doc "Invalidates all sessions for all users in an account."
  def invalidate_all_sessions(account_id) do
    user_ids = from(u in User, where: u.account_id == ^account_id, select: u.id) |> Repo.all()

    from(t in UserToken, where: t.user_id in ^user_ids)
    |> Repo.delete_all()
  end
end
