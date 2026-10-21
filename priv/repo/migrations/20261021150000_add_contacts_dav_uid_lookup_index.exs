defmodule Kith.Repo.Migrations.AddContactsDavUidLookupIndex do
  use Ecto.Migration

  # CDV-104: the only `dav_uid` index is the partial unique one over visible
  # contacts (`deleted_at IS NULL AND is_archived = false`). The contacts
  # BEFORE INSERT trigger (CDV-32/38) must also see trashed and archived rows,
  # so its `dav_uid IN (...)` EXISTS could not use that index and scanned every
  # contact of the account on each insert: a bulk import was O(n^2)
  # (2000 inserts: 0.4 s into an empty account, 1.9 s into one holding 8000).
  # A plain (non-unique) index over every row with a UID fixes the lookup.
  def change do
    create index(:contacts, [:account_id, :dav_uid],
             name: :contacts_account_id_dav_uid_lookup_index,
             where: "dav_uid IS NOT NULL"
           )
  end
end
