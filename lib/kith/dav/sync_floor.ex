defmodule Kith.DAV.SyncFloor do
  @moduledoc "Oldest valid CardDAV sync revision for an account."
  use Ecto.Schema

  @primary_key {:account_id, :id, autogenerate: false}
  schema "dav_sync_floors" do
    field :revision, :integer
  end
end
