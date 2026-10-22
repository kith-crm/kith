defmodule Kith.DAV.ContactDav do
  @moduledoc "CardDAV identity, revision and unmapped vCard properties for a contact."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:contact_id, :id, autogenerate: false}
  schema "contact_dav" do
    field :account_id, :id
    field :uid, :string
    field :resource_name, :string
    field :revision, :integer, read_after_writes: true
    field :extras, {:array, :string}, default: []
  end

  def identity_changeset(dav, attrs) do
    dav
    |> cast(attrs, [:uid, :resource_name])
    |> validate_required([:uid, :resource_name])
    |> unique_constraint(:uid, name: :contact_dav_account_id_uid_index)
    |> unique_constraint(:resource_name, name: :contact_dav_account_id_resource_name_index)
  end
end
