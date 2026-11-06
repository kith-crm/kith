defmodule Kith.Repo.Migrations.ArchiveMergedDavDocuments do
  use Ecto.Migration

  def change do
    alter table(:contact_dav) do
      # Private merge history; never a DAV source or a revision input.
      add :archived_document, :map
    end
  end
end
