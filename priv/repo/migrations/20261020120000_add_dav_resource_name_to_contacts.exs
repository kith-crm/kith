defmodule Kith.Repo.Migrations.AddDavResourceNameToContacts do
  use Ecto.Migration

  # R2: a CardDAV client chooses the resource name (`<uuid>.vcf`) and the vCard
  # UID. Both are stored so the contact is served at exactly that href with the
  # same UID. NULL means the default `kith-contact-<id>.vcf` / `kith-contact-<id>`.
  def change do
    alter table(:contacts) do
      add :dav_resource_name, :text
      add :dav_uid, :text
    end

    create unique_index(:contacts, [:account_id, :dav_resource_name])
  end
end
