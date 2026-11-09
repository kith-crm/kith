defmodule Kith.Accounts.DavAppPasswords do
  @moduledoc "Creation, owner-scoped revocation and uncached DAV-only verification."
  import Ecto.Query
  alias Kith.Accounts.{DavAppPassword, User}
  alias Kith.Repo

  @credential ~r/\Akith_dav_([A-Za-z0-9_-]{22})\.([A-Za-z0-9_-]{43})\z/

  def create(%User{} = user, attrs) do
    if fresh?(user) do
      public_id = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
      secret = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

      %DavAppPassword{
        user_id: user.id,
        public_id: public_id,
        secret_hash: :crypto.hash(:sha256, secret)
      }
      |> DavAppPassword.changeset(attrs)
      |> Repo.insert()
      |> case do
        {:ok, row} -> {:ok, row, "kith_dav_" <> public_id <> "." <> secret}
        {:error, changeset} -> {:error, changeset}
      end
    else
      {:error, :reauthentication_required}
    end
  end

  def list(%User{id: user_id}) do
    Repo.all(from(p in DavAppPassword, where: p.user_id == ^user_id, order_by: [desc: p.id]))
  end

  def revoke(%User{} = user, id) do
    if fresh?(user) do
      revoke_owned(user.id, id)
    else
      {:error, :reauthentication_required}
    end
  end

  def authenticate(email, credential)
      when is_binary(email) and is_binary(credential) and byte_size(credential) == 75 do
    with [_, public_id, secret] <- Regex.run(@credential, credential),
         {row, user} <-
           Repo.one(
             from(p in DavAppPassword,
               join: u in User,
               on: u.id == p.user_id,
               where:
                 p.public_id == ^public_id and u.email == ^email and is_nil(p.revoked_at) and
                   not is_nil(u.confirmed_at),
               select: {p, u}
             )
           ),
         true <- Plug.Crypto.secure_compare(row.secret_hash, :crypto.hash(:sha256, secret)) do
      {:ok, Repo.preload(user, :account)}
    else
      _ -> {:error, :unauthorized}
    end
  end

  def authenticate(_, _), do: {:error, :unauthorized}

  defp revoke_owned(user_id, id) do
    case Ecto.Type.cast(:integer, id) do
      {:ok, id} when id > 0 and id <= 9_223_372_036_854_775_807 ->
        {count, _} =
          Repo.update_all(from(p in DavAppPassword, where: p.user_id == ^user_id and p.id == ^id),
            set: [revoked_at: DateTime.utc_now(:second), updated_at: DateTime.utc_now(:second)]
          )

        if count == 1, do: :ok, else: {:error, :not_found}

      _ ->
        {:error, :not_found}
    end
  end

  # Provisional sudo evidence; task 7 replaces this with persisted MFA-aware freshness.
  defp fresh?(%User{authenticated_at: %DateTime{} = timestamp} = user) do
    Kith.Accounts.sudo_mode?(user) and DateTime.compare(timestamp, DateTime.utc_now()) != :gt
  end

  defp fresh?(_), do: false
end
