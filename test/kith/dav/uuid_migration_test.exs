defmodule Kith.DAV.UUIDMigrationTest do
  use Kith.DataCase, async: false

  @migration Kith.Repo.Migrations.CanonicalDavUuids
  unless Code.ensure_loaded?(@migration) do
    Code.require_file(
      Path.expand("../../../priv/repo/migrations/20261028100000_canonical_dav_uuids.exs", __DIR__)
    )
  end

  setup do
    # A temporary table shadows the application table only on this sandbox
    # connection, so these tests exercise the real migration without altering
    # the installed schema or migration bookkeeping.
    Repo.query!(
      "CREATE TEMP TABLE contact_dav (contact_id bigint, account_id bigint, uid text, resource_name text, revision bigint DEFAULT 0) ON COMMIT DROP"
    )

    Repo.query!("CREATE UNIQUE INDEX migration_test_uid ON contact_dav (account_id, uid)")
    :ok
  end

  test "converts equivalent UUID syntax, preserves hrefs, and rolls back to text" do
    uuid = "a1000000-0000-4000-8000-000000000001"
    insert(1, 1, "URN:UUID:" <> String.upcase(uuid))
    insert(2, 2, uuid)
    run(:up)

    assert %{rows: [[^uuid, "kept-1.vcf", "uuid"], [^uuid, "kept-2.vcf", "uuid"]]} =
             Repo.query!(
               "SELECT uid::text, resource_name, pg_typeof(uid)::text FROM contact_dav ORDER BY contact_id"
             )

    assert %{rows: [[true]]} = Repo.query!("SELECT bool_and(revision > 0) FROM contact_dav")
    run(:down)

    assert %{rows: [["text"]]} =
             Repo.query!("SELECT pg_typeof(uid)::text FROM contact_dav LIMIT 1")
  end

  test "fails before converting invalid legacy identities" do
    insert(1, 1, "old-text-identity")
    assert_raise RuntimeError, ~r/non-UUID identities.*1/, fn -> run(:up) end

    assert %{rows: [["old-text-identity", "text"]]} =
             Repo.query!("SELECT uid, pg_typeof(uid)::text FROM contact_dav")
  end

  test "fails before collapsing two identities in one account" do
    uuid = "a1000000-0000-4000-8000-000000000001"
    insert(1, 1, uuid)
    insert(2, 1, "urn:uuid:" <> uuid)
    assert_raise RuntimeError, ~r/equivalent identities collide/, fn -> run(:up) end
    assert %{rows: [[2]]} = Repo.query!("SELECT count(*) FROM contact_dav")
  end

  defp insert(id, account, uid) do
    Repo.query!(
      "INSERT INTO contact_dav (contact_id, account_id, uid, resource_name) VALUES ($1, $2, $3, $4)",
      [
        id,
        account,
        uid,
        "kept-#{id}.vcf"
      ]
    )
  end

  defp run(direction) do
    Ecto.Migration.Runner.run(
      Repo,
      Repo.config(),
      20_261_028_100_000,
      @migration,
      :forward,
      direction,
      direction,
      log: false
    )
  end
end
