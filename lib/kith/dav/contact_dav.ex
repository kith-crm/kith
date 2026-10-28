defmodule Kith.DAV.ContactDav do
  @moduledoc "CardDAV identity, revision and unmapped vCard properties for a contact."
  use Ecto.Schema
  import Ecto.Changeset
  alias Kith.DAV.UID

  @primary_key {:contact_id, :id, autogenerate: false}
  schema "contact_dav" do
    field :account_id, :id
    field :uid, Ecto.UUID
    field :resource_name, :string
    field :revision, :integer, read_after_writes: true
    field :extras, {:array, :string}, default: []
  end

  def identity_changeset(dav, attrs) do
    {attrs, invalid_uid?} = normalize_uid(attrs)

    dav
    |> cast(attrs, [:uid, :resource_name])
    |> validate_required([:uid, :resource_name])
    |> unique_constraint(:uid, name: :contact_dav_account_id_uid_index)
    |> unique_constraint(:resource_name, name: :contact_dav_account_id_resource_name_index)
    |> validate_uid_input(invalid_uid?)
  end

  defp normalize_uid(attrs) do
    key = if Map.has_key?(attrs, :uid), do: :uid, else: "uid"

    case UID.normalize(Map.get(attrs, key)) do
      {:ok, uid} -> {Map.put(attrs, key, uid), false}
      _ -> {attrs, Map.has_key?(attrs, key) and Map.get(attrs, key) != nil}
    end
  end

  defp validate_uid_input(changeset, false), do: changeset
  defp validate_uid_input(changeset, true), do: add_error(changeset, :uid, "must be a UUID")
end
