defmodule Mix.Tasks.Kith.Avatars.Backfill do
  @shortdoc "Normalize existing contact avatars without changing original photos"
  @moduledoc "Run `mix kith.avatars.backfill [--account-id ID]`. Safe to resume after failure."
  use Mix.Task
  import Ecto.Query
  alias Kith.{Contacts, Repo, Storage}
  alias Kith.Contacts.{Avatar, AvatarAsset, AvatarProcessor, Contact, Photo, Write}

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")
    {opts, _, invalid} = OptionParser.parse(args, strict: [account_id: :integer])
    if invalid != [], do: Mix.raise("Usage: mix kith.avatars.backfill [--account-id ID]")

    query = from c in Contact, where: not is_nil(c.avatar), order_by: c.id

    query =
      if opts[:account_id], do: where(query, [c], c.account_id == ^opts[:account_id]), else: query

    # Keyset batches let a large backfill resume without holding all contacts.
    report(backfill_batch(query, 0, {0, 0, []}))
  end

  defp backfill_batch(query, after_id, counters) do
    contacts = Repo.all(from c in query, where: c.id > ^after_id, limit: 100)

    case contacts do
      [] ->
        counters

      _ ->
        backfill_batch(
          query,
          List.last(contacts).id,
          Enum.reduce(contacts, counters, &normalize_one/2)
        )
    end
  end

  defp normalize_one(contact, {converted, skipped, errors}) do
    case normalize(contact) do
      :unchanged -> {converted, skipped + 1, errors}
      {:ok, _} -> {converted + 1, skipped, errors}
      {:error, reason} -> {converted, skipped, [{contact.id, reason} | errors]}
    end
  end

  defp report({converted, skipped, errors}) do
    Mix.shell().info(
      "Avatars: #{converted} converted, #{skipped} already normalized, #{length(errors)} failed"
    )

    Enum.each(Enum.reverse(errors), fn {id, reason} ->
      Mix.shell().error("Contact #{id}: #{inspect(reason)}")
    end)

    if errors != [], do: Mix.raise("Avatar backfill incomplete; fix reported sources and rerun")
  end

  defp normalize(contact) do
    asset = Repo.get_by(AvatarAsset, account_id: contact.account_id, storage_key: contact.avatar)
    if asset, do: verify_asset(contact, asset), else: normalize_unregistered(contact)
  end

  defp verify_asset(contact, asset) do
    with {:ok, bytes} <- Storage.read(contact.avatar),
         true <- Avatar.hash(bytes) == asset.content_hash do
      :unchanged
    else
      _ -> repair_cached_rendition(contact)
    end
  end

  defp normalize_unregistered(contact) do
    source =
      Repo.one(
        from p in Photo,
          where:
            p.account_id == ^contact.account_id and p.contact_id == ^contact.id and
              p.storage_key == ^contact.avatar
      )

    if source, do: Contacts.set_avatar(contact, source), else: register_existing(contact)
  end

  defp register_existing(contact) do
    prefix = "#{contact.account_id}/avatars/"

    with true <- String.starts_with?(contact.avatar, prefix),
         {:ok, bytes} <- Storage.read(contact.avatar),
         :ok <- AvatarProcessor.validate_rendition(bytes) do
      Write.run(contact.account_id, [contact.id], fn ->
        Avatar.register_asset!(contact.account_id, contact.avatar, bytes)
        {:ok, contact}
      end)
    else
      false -> {:error, :source_photo_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp repair_cached_rendition(contact) do
    photo =
      Repo.one(
        from p in Photo,
          where:
            p.account_id == ^contact.account_id and p.contact_id == ^contact.id and
              p.avatar_storage_key == ^contact.avatar,
          limit: 1
      )

    if photo, do: repair_rendition(contact, photo), else: {:error, :rendition_source_unavailable}
  end

  defp repair_rendition(contact, photo) do
    if photo.contact_id == contact.id,
      do: Contacts.set_avatar(contact, photo, crop: photo.avatar_crop),
      else: {:error, :shared_rendition_unavailable}
  end
end
