defmodule Kith.Repo.Migrations.AddContactDavVcard do
  use Ecto.Migration

  def change do
    alter table(:contacts) do
      add :dav_vcard, :map, null: false, default: %{}
    end
  end
end
