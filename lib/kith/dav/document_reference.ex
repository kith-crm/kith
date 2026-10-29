defmodule Kith.DAV.DocumentReference do
  @moduledoc "Account-scoped UUID dependency index derived from the authoritative DAV document."
  use Ecto.Schema
  @primary_key false
  schema "dav_document_references" do
    field :account_id, :id
    field :source_contact_id, :id
    field :target_uid, Ecto.UUID
  end
end
