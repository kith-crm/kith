defmodule Kith.DAV.DataBoundaryMigrationTest do
  use Kith.DataCase, async: false

  @migration Kith.Repo.Migrations.CarddavDataBoundary
  unless Code.ensure_loaded?(@migration) do
    Code.require_file(
      Path.expand(
        "../../../priv/repo/migrations/20261028120000_carddav_data_boundary.exs",
        __DIR__
      )
    )
  end

  setup do
    # Exercise the actual migration against connection-local temporary tables,
    # without downgrading the installed schema or migration bookkeeping.
    Repo.query!(
      "CREATE TEMP TABLE contact_field_types (id bigserial PRIMARY KEY, account_id bigint, name text NOT NULL, protocol text, icon text, vcard_label text, position integer NOT NULL DEFAULT 0, inserted_at timestamp NOT NULL, updated_at timestamp NOT NULL) ON COMMIT DROP"
    )

    Repo.query!(
      "CREATE TEMP TABLE relationship_types (id bigserial PRIMARY KEY, account_id bigint, name text NOT NULL, reverse_name text NOT NULL, is_bidirectional boolean NOT NULL DEFAULT false, position integer NOT NULL DEFAULT 0, inserted_at timestamp NOT NULL, updated_at timestamp NOT NULL) ON COMMIT DROP"
    )

    Repo.query!(
      "CREATE TEMP TABLE contact_dav (contact_id bigint, account_id bigint, uid uuid, resource_name text, revision bigint DEFAULT 0, extras text[] DEFAULT '{}') ON COMMIT DROP"
    )

    :ok
  end

  test "audits known seed shape, inserts missing canonicals, and preserves identity/private extras" do
    insert_field(nil, "Email", "mailto:", "mail", "EMAIL", 0)
    insert_field(50, "Private Email", "mailto:", "mail", "EMAIL", -10)
    insert_field(nil, "Untrusted global", "mailto:", "mail", "EMAIL", 0)

    Repo.query!(
      "INSERT INTO contact_dav (contact_id, account_id, uid, resource_name, revision, extras) VALUES (1, 50, 'a1000000-0000-4000-8000-000000000001', 'kept.vcf', 0, ARRAY['X-LEGACY:quarantined'])"
    )

    run(:up)

    assert %{rows: [["email"]]} =
             Repo.query!("SELECT system_key FROM contact_field_types WHERE name = 'Email'")

    assert %{rows: [[nil], [nil]]} =
             Repo.query!(
               "SELECT system_key FROM contact_field_types WHERE name IN ('Private Email', 'Untrusted global') ORDER BY name"
             )

    assert %{rows: [[6]]} =
             Repo.query!("SELECT count(*) FROM contact_field_types WHERE system_key IS NOT NULL")

    assert %{rows: [["contact"], ["parent"], ["spouse"]]} =
             Repo.query!(
               "SELECT system_key FROM relationship_types WHERE system_key IN ('contact', 'parent', 'spouse') ORDER BY system_key"
             )

    assert %{rows: [["kept.vcf", true, true, %{}, ["X-LEGACY:quarantined"], true]]} =
             Repo.query!(
               "SELECT resource_name, requires_precondition, revision > 0, document, extras, representation_modified_at IS NOT NULL FROM contact_dav"
             )

    Repo.query!("INSERT INTO contact_dav (contact_id) VALUES (2)")

    assert %{rows: [[false]]} =
             Repo.query!("SELECT requires_precondition FROM contact_dav WHERE contact_id = 2")

    run(:down)

    assert %{rows: [["kept.vcf", ["X-LEGACY:quarantined"]]]} =
             Repo.query!("SELECT resource_name, extras FROM contact_dav WHERE contact_id = 1")
  end

  test "fails before trusting a name-only global impostor" do
    insert_field(nil, "Email", "mailto:", "different icon", "EMAIL", 0)
    assert_raise RuntimeError, ~r/ambiguous or altered global seed rows/, fn -> run(:up) end
    assert %{rows: [["different icon"]]} = Repo.query!("SELECT icon FROM contact_field_types")
  end

  test "fails before choosing among duplicate seed shapes" do
    insert_field(nil, "Email", "mailto:", "mail", "EMAIL", 0)
    insert_field(nil, "Email", "mailto:", "mail", "EMAIL", 0)
    assert_raise RuntimeError, ~r/ambiguous or altered global seed rows/, fn -> run(:up) end
  end

  test "fails before classifying a relationship with an altered reverse mapping" do
    Repo.query!(
      "INSERT INTO relationship_types (name, reverse_name, is_bidirectional, position, inserted_at, updated_at) VALUES ('Parent', 'Private subtype', false, 4, now(), now())"
    )

    assert_raise RuntimeError, ~r/Cannot classify DAV relationship parent/, fn -> run(:up) end
  end

  defp insert_field(account_id, name, protocol, icon, label, position) do
    Repo.query!(
      "INSERT INTO contact_field_types (account_id, name, protocol, icon, vcard_label, position, inserted_at, updated_at) VALUES ($1, $2, $3, $4, $5, $6, now(), now())",
      [account_id, name, protocol, icon, label, position]
    )
  end

  defp run(direction) do
    Ecto.Migration.Runner.run(
      Repo,
      Repo.config(),
      20_261_028_120_000,
      @migration,
      :forward,
      direction,
      direction,
      log: false
    )
  end
end
