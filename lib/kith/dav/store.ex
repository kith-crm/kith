defmodule Kith.DAV.Store do
  @moduledoc "Account-scoped CardDAV identities and commit-ordered sync revisions."
  import Ecto.Query
  alias Kith.{Contacts, Repo}
  alias Kith.Contacts.{Contact, Write}
  alias Kith.DAV.{ContactDav, Document, References, Relationships, SharedContact, UID}

  def ensure_rows(account_id) do
    if Process.get({__MODULE__, :snapshot}) do
      :ok
    else
      ensure_rows_outside_snapshot(account_id)
    end
  end

  defp ensure_rows_outside_snapshot(account_id) do
    transact(account_id, fn ->
      Repo.query!(
        """
        INSERT INTO contact_dav (contact_id, account_id, uid, resource_name)
        SELECT id, account_id, uid::uuid, uid || '.vcf'
        FROM (
          SELECT c.id, c.account_id, gen_random_uuid()::text AS uid
          FROM contacts c LEFT JOIN contact_dav d ON d.contact_id = c.id
          WHERE c.account_id = $1 AND d.contact_id IS NULL
        ) identities
        ON CONFLICT DO NOTHING
        """,
        [account_id]
      )

      pending =
        Repo.all(
          from d in ContactDav,
            where: d.account_id == ^account_id and is_nil(d.representation_fingerprint),
            select: d.contact_id
        )

      initialize(account_id, pending)
    end)
  end

  def etag(%{dav: %{revision: revision}}, version \\ :v30),
    do: "#{revision}-#{version}"

  def current_etags(contact), do: Enum.map([:v30, :v40], &etag(contact, &1))

  def snapshot(account_id, fun) do
    ensure_rows(account_id)
    nested? = Repo.in_transaction?()
    sandbox? = Repo.config()[:pool] == Ecto.Adapters.SQL.Sandbox

    case Repo.transaction(fn -> read_snapshot(account_id, fun, nested? or sandbox?) end) do
      {:ok, result} -> result
      {:error, reason} -> raise "DAV read snapshot failed: #{inspect(reason)}"
    end
  end

  defp read_snapshot(account_id, fun, nested?) do
    if nested? do
      Repo.query!("SELECT pg_advisory_xact_lock_shared(hashtextextended($1, 0))", [
        "kith-dav:#{account_id}"
      ])
    else
      Repo.query!("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ")
    end

    previous = Process.put({__MODULE__, :snapshot}, true)

    try do
      Relationships.with_snapshot(account_id, fn ->
        SharedContact.with_snapshot(account_id, fun)
      end)
    after
      if previous,
        do: Process.put({__MODULE__, :snapshot}, previous),
        else: Process.delete({__MODULE__, :snapshot})
    end
  end

  def touch(_account_id, []), do: :ok

  def touch(account_id, ids) do
    ids = if is_list(ids), do: ids, else: Repo.all(ids)
    Write.mark(account_id, ids)
  end

  def ensure_contact_rows(_account_id, []), do: :ok

  def ensure_contact_rows(account_id, ids) do
    Repo.query!(
      """
      INSERT INTO contact_dav (contact_id, account_id, uid, resource_name)
      SELECT id, account_id, uid::uuid, uid || '.vcf'
      FROM (SELECT id, account_id, gen_random_uuid()::text AS uid FROM contacts
        WHERE account_id = $1 AND id = ANY($2)) identities
      ON CONFLICT DO NOTHING
      """,
      [account_id, ids]
    )

    :ok
  end

  def initialize(account_id, ids) do
    contacts =
      from(c in Contact,
        join: d in ContactDav,
        on: d.contact_id == c.id,
        where:
          c.account_id == ^account_id and c.id in ^ids and is_nil(d.representation_fingerprint),
        preload: [:dav]
      )
      |> Repo.all()

    Enum.each(contacts, &publish_contact(&1, true))
  end

  def publish(_account_id, []), do: :ok

  def publish(account_id, ids) do
    ensure_contact_rows(account_id, ids)

    from(c in Contact, where: c.account_id == ^account_id and c.id in ^ids)
    |> Repo.all()
    |> Enum.each(&publish_contact(&1, false))

    :ok
  end

  defp publish_contact(contact, initial?) do
    {contact, document} = publication_document(contact)
    dav_record = contact.dav
    original_document = dav_record.document
    References.replace(contact.account_id, contact.id, document)
    contact = put_in(contact.dav.document, document)
    fingerprint = fingerprint(contact)

    if initial? or fingerprint != contact.dav.representation_fingerprint do
      now = if initial?, do: contact.dav.representation_modified_at, else: DateTime.utc_now()
      document = Document.stamp(document, now)

      attrs = [
        document: document,
        representation_fingerprint: fingerprint,
        representation_modified_at: now
      ]

      dav_record |> Ecto.Changeset.change(attrs) |> Repo.update!()

      unless initial? do
        from(d in ContactDav, where: d.contact_id == ^contact.id)
        |> Repo.update_all(
          set: [revision: dynamic(fragment("nextval('contact_dav_revision_seq')"))]
        )
      end
    else
      if document != original_document do
        dav_record |> Ecto.Changeset.change(document: document) |> Repo.update!()
      end
    end
  end

  defp publication_document(contact) do
    case Write.staged_document(contact.id) do
      {current, document} ->
        {current, document}

      nil ->
        current = Repo.preload(contact, Contacts.dav_preloads(), force: true)
        {current, Document.capture(current)}
    end
  end

  defp fingerprint(contact) do
    view = Document.fingerprint(contact)

    :crypto.hash(
      :sha256,
      :erlang.term_to_binary({contact.deleted_at == nil and not contact.is_archived, view})
    )
    |> Base.encode16(case: :lower)
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

  def get_by_uid(account_id, uid) do
    case UID.normalize(uid) do
      {:ok, canonical} -> base(account_id) |> where([c, d], d.uid == ^canonical) |> Repo.one()
      _ -> nil
    end
  end

  def get_related(account_id, value), do: get_by_uid(account_id, value)

  @doc "Re-reads a contact under a row lock; call inside a transaction."
  def lock(%Contact{id: id, account_id: account_id}) do
    Write.prepare(account_id, [id])

    from(c in Contact,
      where: c.id == ^id and c.account_id == ^account_id,
      lock: "FOR NO KEY UPDATE",
      preload: [:dav]
    )
    |> Repo.one()
  end

  def lock_resource(account_id, name) do
    id =
      Repo.one(
        from d in ContactDav,
          where: d.account_id == ^account_id and d.resource_name == ^name,
          select: d.contact_id
      )

    if id do
      Write.prepare(account_id, [id])

      Repo.one(
        from c in Contact,
          join: d in ContactDav,
          on: d.contact_id == c.id,
          where: c.id == ^id and c.account_id == ^account_id and d.account_id == ^account_id,
          lock: fragment("FOR NO KEY UPDATE OF ?", c),
          preload: [dav: d]
      )
    end
  end

  def put_identity(%ContactDav{} = dav, attrs) do
    Write.run(dav.account_id, [dav.contact_id], fn ->
      current = Repo.get_by!(ContactDav, contact_id: dav.contact_id, account_id: dav.account_id)
      current |> ContactDav.identity_changeset(attrs) |> Repo.update()
    end)
  end

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
  def transaction(account_id, fun), do: Write.transaction(account_id, fun)

  defp transact(account_id, fun) do
    {:ok, _} = transaction(account_id, fun)
    :ok
  end

  # Hold the lock until commit so a later writer cannot publish a revision
  # ahead of a revision that is still invisible to sync readers.
  def lock_account!(account_id) do
    Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
      "kith-dav:#{account_id}"
    ])
  end
end
