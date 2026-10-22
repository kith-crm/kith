defmodule Kith.Repo.Migrations.AddContactsDavUidBareIndex do
  use Ecto.Migration

  # CDV-105: RELATED resolution (CDV-99/102) compares
  # `lower(regexp_replace(dav_uid, '^urn:uuid:', '', 'i'))`, an expression no
  # existing index covers, so each RELATED line of a PUT scanned every contact
  # of the account holding a UID (17 ms per line at 10 000 contacts; a card of
  # a few hundred lines took seconds, a 1 MiB one minutes). This expression
  # index answers the lookup in ~0.6 ms.
  def change do
    create index(
             :contacts,
             [:account_id, "(lower(regexp_replace(dav_uid, '^urn:uuid:', '', 'i')))"],
             name: :contacts_account_id_dav_uid_bare_index,
             where: "dav_uid IS NOT NULL"
           )
  end
end
