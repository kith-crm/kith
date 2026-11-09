defmodule Kith.Accounts.UserToken do
  @moduledoc """
  Token storage for sessions, email confirmation, password reset, and API tokens.
  """

  use Ecto.Schema
  import Ecto.Query
  alias Kith.Accounts.UserToken

  @hash_algorithm :sha256
  @rand_size 32

  @confirm_validity_in_days 7
  @reset_password_validity_in_hours 1
  @change_email_validity_in_days 7
  @session_validity_in_days 60

  schema "user_tokens" do
    field :token, :binary
    field :context, :string
    field :sent_to, :string
    field :authenticated_at, :utc_datetime
    field :mfa_authenticated_at, :utc_datetime
    belongs_to :user, Kith.Accounts.User

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc """
  Generates a token that will be stored in a signed place,
  such as session or cookie. As they are signed, those
  tokens do not need to be hashed.

  The reason why we store session tokens in the database, even
  though Phoenix already provides a session cookie, is because
  Phoenix's default session cookies are not persisted, they are
  simply signed and potentially encrypted. This means they are
  valid indefinitely, unless you change the signing/encryption
  salt.

  Therefore, storing them allows individual user
  sessions to be expired.
  """
  def build_session_token(user) do
    token = :crypto.strong_rand_bytes(@rand_size)
    dt = user.authenticated_at

    {token,
     %UserToken{
       token: token,
       context: "session",
       user_id: user.id,
       authenticated_at: dt,
       mfa_authenticated_at: user.mfa_authenticated_at
     }}
  end

  @doc """
  Checks if the session token is valid and returns its underlying lookup query.

  The query returns `{user_with_preloaded_account, token_inserted_at}`.
  """
  def verify_session_token_query(token) do
    query =
      from token in by_token_and_context_query(token, "session"),
        join: user in assoc(token, :user),
        join: account in assoc(user, :account),
        where: token.inserted_at > ago(@session_validity_in_days, "day"),
        select:
          {%{
             user
             | authenticated_at: token.authenticated_at,
               mfa_authenticated_at: token.mfa_authenticated_at,
               account: account
           }, token.inserted_at}

    {:ok, query}
  end

  @doc """
  Builds a token and its hash to be delivered to the user's email.

  The non-hashed token is sent to the user email while the
  hashed part is stored in the database.
  """
  def build_email_token(user, context) do
    build_hashed_token(user, context, user.email)
  end

  defp build_hashed_token(user, context, sent_to) do
    token = :crypto.strong_rand_bytes(@rand_size)
    hashed_token = :crypto.hash(@hash_algorithm, token)

    {Base.url_encode64(token, padding: false),
     %UserToken{
       token: hashed_token,
       context: context,
       sent_to: sent_to,
       user_id: user.id
     }}
  end

  @doc """
  Checks if the confirm token is valid and returns its underlying lookup query.
  """
  def verify_confirm_token_query(token) do
    case Base.url_decode64(token, padding: false) do
      {:ok, decoded_token} ->
        hashed_token = :crypto.hash(@hash_algorithm, decoded_token)

        query =
          from token in by_token_and_context_query(hashed_token, "confirm"),
            join: user in assoc(token, :user),
            where: token.inserted_at > ago(@confirm_validity_in_days, "day"),
            where: token.sent_to == user.email,
            select: user

        {:ok, query}

      :error ->
        :error
    end
  end

  @doc """
  Checks if the reset password token is valid and returns its underlying lookup query.
  """
  def verify_reset_password_token_query(token) do
    case Base.url_decode64(token, padding: false) do
      {:ok, decoded_token} ->
        hashed_token = :crypto.hash(@hash_algorithm, decoded_token)

        query =
          from token in by_token_and_context_query(hashed_token, "reset_password"),
            join: user in assoc(token, :user),
            where: token.inserted_at > ago(@reset_password_validity_in_hours, "hour"),
            where: token.sent_to == user.email,
            select: user

        {:ok, query}

      :error ->
        :error
    end
  end

  @doc """
  Checks if the change email token is valid and returns its underlying lookup query.
  """
  def verify_change_email_token_query(token, "change:" <> _ = context) do
    case Base.url_decode64(token, padding: false) do
      {:ok, decoded_token} ->
        hashed_token = :crypto.hash(@hash_algorithm, decoded_token)

        query =
          from token in by_token_and_context_query(hashed_token, context),
            where: token.inserted_at > ago(@change_email_validity_in_days, "day")

        {:ok, query}

      :error ->
        :error
    end
  end

  @doc """
  Builds an API token. Returns `{raw_token_base64url, %UserToken{}}`.

  The raw token is returned to the caller once. The DB stores the SHA-256 hash.
  """
  def build_api_token(user) do
    token = :crypto.strong_rand_bytes(@rand_size)
    hashed_token = :crypto.hash(@hash_algorithm, token)

    {Base.url_encode64(token, padding: false),
     %UserToken{
       token: hashed_token,
       context: "api",
       user_id: user.id
     }}
  end

  @doc """
  Verifies an API token and returns a query to load the user.

  API tokens do not expire (long-lived).
  """
  def verify_api_token_query(raw_token) do
    case Base.url_decode64(raw_token, padding: false) do
      {:ok, decoded_token} ->
        hashed_token = :crypto.hash(@hash_algorithm, decoded_token)

        query =
          from token in by_token_and_context_query(hashed_token, "api"),
            join: user in assoc(token, :user),
            join: account in assoc(user, :account),
            select: {%{user | account: account}, token}

        {:ok, query}

      :error ->
        :error
    end
  end

  @doc """
  Returns the query for finding a token by token value and context.
  """
  def by_token_and_context_query(token, context) do
    from UserToken, where: [token: ^token, context: ^context]
  end

  @doc """
  Returns the query for finding all user tokens by user_id and context.
  """
  def by_user_and_context_query(user_id, context) do
    from t in UserToken, where: t.user_id == ^user_id and t.context == ^context
  end
end
