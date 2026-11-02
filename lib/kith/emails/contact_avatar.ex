defmodule Kith.Emails.ContactAvatar do
  @moduledoc "Best-effort inline email attachment from an account's registered processed avatar."

  import Ecto.Query

  alias Kith.Contacts.{Avatar, AvatarAsset, AvatarProcessor}
  alias Kith.{Repo, Storage}
  alias Swoosh.Attachment

  def load(
        %{account_id: account_id},
        %{
          account_id: account_id,
          account: %{id: account_id},
          reminder: %{account_id: account_id, contact: %{account_id: account_id, avatar: key}}
        }
      )
      when is_integer(account_id) and is_binary(key) do
    with %AvatarAsset{} = asset <-
           Repo.one(
             from a in AvatarAsset,
               where: a.account_id == ^account_id and a.storage_key == ^key
           ),
         {:ok, bytes} <- Storage.read(key),
         true <- byte_size(bytes) == asset.byte_size and Avatar.hash(bytes) == asset.content_hash,
         :ok <- AvatarProcessor.validate_rendition(bytes) do
      Attachment.new({:data, bytes},
        filename: "contact-avatar.jpg",
        content_type: "image/jpeg",
        type: :inline,
        cid: "contact-avatar.jpg"
      )
    else
      _ -> nil
    end
  rescue
    # Optional images must never prevent the reminder from being delivered.
    _ -> nil
  end

  def load(_user, _instance), do: nil
end
