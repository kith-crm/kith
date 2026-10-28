defmodule Kith.Repo.Migrations.AddUniqueVisibleDavUidIndex do
  use Ecto.Migration

  # RFC 6352 §6.3.2.1 (no-uid-conflict): at most one visible contact (neither
  # trashed nor archived, matching R5) per stored vCard UID in an account.
  #
  # Rows created before this index may already share a UID. The oldest visible
  # holder keeps it; the others drop their stored UID and fall back to the
  # default `kith-contact-<id>` UID.
  def up do
    execute """
    UPDATE contacts c SET dav_uid = NULL
    FROM (
      SELECT id, row_number() OVER (PARTITION BY account_id, dav_uid ORDER BY id) AS rn
      FROM contacts
      WHERE dav_uid IS NOT NULL AND deleted_at IS NULL AND is_archived = false
    ) d
    WHERE c.id = d.id AND d.rn > 1
    """

    create unique_index(:contacts, [:account_id, :dav_uid],
             name: :contacts_account_id_dav_uid_index,
             where: "dav_uid IS NOT NULL AND deleted_at IS NULL AND is_archived = false"
           )
  end

  def down do
    drop index(:contacts, [:account_id, :dav_uid], name: :contacts_account_id_dav_uid_index)
  end
end
