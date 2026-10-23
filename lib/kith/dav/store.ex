defmodule Kith.DAV.Store do
  @moduledoc "Account-scoped CardDAV identities and commit-ordered sync revisions."
  import Ecto.Query
  alias Kith.{Contacts, Repo}
  alias Kith.Contacts.Contact
  alias Kith.DAV.ContactDav

  def ensure_rows(account_id) do
    transact(account_id, fn ->
      Repo.query!(
        """
        INSERT INTO contact_dav (contact_id, account_id, uid, resource_name)
        SELECT id, account_id, uid, uid || '.vcf'
        FROM (
          SELECT c.id, c.account_id, gen_random_uuid()::text AS uid
          FROM contacts c LEFT JOIN contact_dav d ON d.contact_id = c.id
          WHERE c.account_id = $1 AND d.contact_id IS NULL
        ) identities
        ON CONFLICT DO NOTHING
        """,
        [account_id]
      )
    end)
  end

  def touch(_account_id, []), do: :ok

  def touch(account_id, ids) do
    transact(account_id, fn ->
      query = from d in ContactDav, where: d.account_id == ^account_id

      query =
        if is_list(ids),
          do: where(query, [d], d.contact_id in ^ids),
          else: where(query, [d], d.contact_id in subquery(ids))

      Repo.update_all(query,
        set: [revision: dynamic(fragment("nextval('contact_dav_revision_seq')"))]
      )
    end)
  end

  def record_hard_delete(account_id) do
    transact(account_id, fn ->
      Repo.query!(
        """
        INSERT INTO dav_sync_floors (account_id, revision)
        VALUES ($1, nextval('contact_dav_revision_seq'))
        ON CONFLICT (account_id) DO UPDATE SET revision = EXCLUDED.revision
        """,
        [account_id]
      )
    end)
  end

  def sync_state(account_id) do
    %{rows: [[token, floor]]} =
      Repo.query!(
        """
        SELECT GREATEST(COALESCE((SELECT max(revision) FROM contact_dav WHERE account_id = $1), 0), COALESCE(f.revision, 0)), COALESCE(f.revision, 0)
        FROM (SELECT $1::bigint AS account_id) a
        LEFT JOIN dav_sync_floors f ON f.account_id = a.account_id
        """,
        [account_id]
      )

    %{token: token, floor: floor}
  end

  def list_changed_since(account_id, revision) do
    base(account_id)
    |> where([c, d], d.revision > ^revision)
    |> preload(^([:dav] ++ Contacts.dav_preloads()))
    |> Repo.all()
  end

  def get_by_resource_name(account_id, name),
    do: base(account_id) |> where([c, d], d.resource_name == ^name) |> Repo.one()

  def get_by_resource_names(account_id, names) do
    base(account_id)
    |> where([c, d], d.resource_name in ^names)
    |> Repo.all()
    |> Map.new(&{&1.dav.resource_name, &1})
  end

  def get_by_uid(account_id, uid),
    do: base(account_id) |> where([c, d], d.uid == ^uid) |> Repo.one()

  def get_related(account_id, value) do
    stripped = String.replace_prefix(value, "urn:uuid:", "")
    variants = Enum.uniq([value, stripped, "urn:uuid:" <> stripped])

    base(account_id)
    |> where([c, d], d.uid in ^variants)
    |> order_by([c, d], fragment("array_position(?::text[], ?)", ^variants, d.uid))
    |> limit(1)
    |> Repo.one()
  end

  @doc "Re-reads a contact under a row lock; call inside a transaction."
  def lock(%Contact{id: id, account_id: account_id}) do
    from(c in Contact,
      where: c.id == ^id and c.account_id == ^account_id,
      lock: "FOR NO KEY UPDATE",
      preload: [:dav]
    )
    |> Repo.one()
  end

  def put_identity(%ContactDav{} = dav, attrs),
    do: dav |> ContactDav.identity_changeset(attrs) |> Repo.update()

  def put_extras(%ContactDav{} = dav, extras),
    do: dav |> Ecto.Changeset.change(extras: extras) |> Repo.update()

  def href(%Contact{dav: dav}),
    do: "/dav/addressbooks/default/" <> URI.encode(dav.resource_name, &URI.char_unreserved?/1)

  defp base(account_id) do
    from c in Contact,
      join: d in ContactDav,
      on: d.contact_id == c.id and d.account_id == c.account_id,
      where: c.account_id == ^account_id,
      preload: [dav: d]
  end

  @doc "Runs a write transaction with the account lock acquired before any contact locks."
  def transaction(account_id, fun) do
    Repo.transaction(fn ->
      lock_account(account_id)
      fun.()
    end)
  end

  defp transact(account_id, fun) do
    {:ok, _} = transaction(account_id, fun)
    :ok
  end

  # Hold the lock until commit so a later writer cannot publish a revision
  # ahead of a revision that is still invisible to sync readers.
  defp lock_account(account_id) do
    Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
      "kith-dav:#{account_id}"
    ])
  end
end
