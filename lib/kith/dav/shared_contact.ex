defmodule Kith.DAV.SharedContact do
  @moduledoc "The explicit native contact values owned by the DAV shared view."

  import Ecto.Query
  alias Kith.Contacts.{AvatarAsset, AvatarProcessor}
  alias Kith.DAV.{FieldRegistry, Relationships}
  alias Kith.{Repo, Storage}

  @scalars ~w(id account_id first_name middle_name last_name display_name nickname birthdate birthdate_year_unknown company occupation)a

  @snapshot_key {__MODULE__, :avatar_assets}

  def with_snapshot(account_id, fun) do
    previous = Process.get(@snapshot_key)

    assets =
      Repo.all(from(a in AvatarAsset, where: a.account_id == ^account_id))
      |> Map.new(&{&1.storage_key, &1})

    Process.put(@snapshot_key, {account_id, assets})

    try do
      fun.()
    after
      if previous, do: Process.put(@snapshot_key, previous), else: Process.delete(@snapshot_key)
    end
  end

  def project(contact, opts \\ []) do
    contact
    |> Map.take(@scalars)
    |> Map.merge(%{
      description: nil,
      gender: nil,
      updated_at: get_in_dav(contact, :representation_modified_at),
      dav: %{uid: get_in_dav(contact, :uid), extras: []},
      contact_fields:
        if(Keyword.get(opts, :skip_fields, false), do: [], else: shared_fields(contact)),
      addresses:
        if(Keyword.get(opts, :skip_fields, false), do: [], else: shared_addresses(contact)),
      tags:
        contact |> owned(:tags) |> Enum.sort_by(& &1.id) |> Enum.map(&Map.take(&1, [:id, :name])),
      relationships: Relationships.project(contact),
      avatar_data: avatar_data(contact, opts)
    })
  end

  defp shared_addresses(contact) do
    contact
    |> owned(:addresses)
    |> Enum.sort_by(& &1.id)
    |> Enum.map(&Map.take(&1, ~w(id line1 line2 city province postal_code country label)a))
  end

  def fields(contact), do: shared_fields(contact)

  defp shared_fields(contact) do
    contact
    |> owned(:contact_fields)
    |> Enum.sort_by(& &1.id)
    |> Enum.flat_map(fn field ->
      case FieldRegistry.kind(field.contact_field_type) do
        nil ->
          []

        kind ->
          [
            field
            |> Map.take([:id, :value, :label])
            |> Map.put(:label, public_label(field))
            |> Map.put(:contact_field_type, public_type(kind))
          ]
      end
    end)
  end

  def field_label(field), do: public_label(field)

  def type_tokens(nil), do: []

  def type_tokens(label) when is_binary(label) do
    label
    |> String.replace(~r/["\x00-\x1F\x7F]/, "")
    |> String.split(",")
    |> Enum.map(&normalize_type/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp normalize_type(value) do
    case value |> String.trim() |> String.downcase() do
      "mobile" -> "cell"
      "personal" -> "home"
      "business" -> "work"
      other -> other
    end
  end

  defp public_label(%{label: label}) when label not in [nil, ""], do: label
  defp public_label(%{contact_field_type: %{system_key: "mobile"}}), do: "cell"
  defp public_label(%{contact_field_type: %{system_key: "work_phone"}}), do: "work"
  defp public_label(%{contact_field_type: %{system_key: "fax"}}), do: "fax"
  defp public_label(_), do: nil

  defp public_type(:emails), do: %{protocol: "mailto", vcard_label: "EMAIL"}
  defp public_type(:phones), do: %{protocol: "tel", vcard_label: "TEL"}
  defp public_type(:urls), do: %{protocol: "https", vcard_label: "URL"}

  defp avatar_data(contact, opts) do
    cond do
      not Keyword.get(opts, :include_photo, true) -> nil
      is_nil(Map.get(contact, :avatar)) -> nil
      true -> load_avatar!(contact)
    end
  end

  def avatar_fingerprint(%{avatar: key, account_id: account_id}) when is_binary(key) do
    case avatar_asset(account_id, key) do
      %AvatarAsset{content_hash: digest} -> digest
      _ -> :crypto.hash(:sha256, key) |> Base.encode16(case: :lower)
    end
  end

  def avatar_fingerprint(_), do: nil

  defp load_avatar!(%{avatar: key, account_id: account_id}) do
    limit = Application.get_env(:kith, :max_vcard_photo_embed_bytes, 512 * 1024)

    with %AvatarAsset{} = asset <- avatar_asset(account_id, key),
         {:ok, binary} <- Storage.read(key),
         true <- byte_size(binary) <= limit and byte_size(binary) == asset.byte_size,
         true <-
           :crypto.hash(:sha256, binary) |> Base.encode16(case: :lower) == asset.content_hash,
         :ok <- AvatarProcessor.validate_rendition(binary) do
      %{binary: binary, content_type: "image/jpeg"}
    else
      _ ->
        raise Kith.DAV.RepresentationError,
              "DAV selected avatar is unavailable or is not a registered processed rendition"
    end
  end

  defp avatar_asset(account_id, key) do
    case Process.get(@snapshot_key) do
      {^account_id, assets} ->
        Map.get(assets, key)

      _ ->
        Repo.one(
          from(a in AvatarAsset, where: a.account_id == ^account_id and a.storage_key == ^key)
        )
    end
  end

  defp owned(contact, key) do
    contact
    |> loaded(key)
    |> Enum.filter(fn row ->
      row.account_id == contact.account_id and
        (key == :tags or row.contact_id == contact.id)
    end)
  end

  defp loaded(contact, key) do
    case Map.get(contact, key, []) do
      value when is_list(value) -> value
      _ -> raise ArgumentError, "DAV projection requires loaded #{key}"
    end
  end

  defp get_in_dav(contact, key) do
    case Map.get(contact, :dav) do
      %{__struct__: Ecto.Association.NotLoaded} -> nil
      dav when is_map(dav) -> Map.get(dav, key)
      _ -> nil
    end
  end
end
