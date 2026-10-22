defmodule KithWeb.DAV.SyncEpochTest do
  @moduledoc """
  The sync token epoch across restores. These tests run DDL inside the sandbox
  transaction (rolled back afterwards), so the module is not async.
  """
  use KithWeb.ConnCase, async: false

  import KithWeb.DAV.TestHelpers

  alias Kith.{ContactsFixtures, Repo}

  setup :setup_dav_user

  defp sync(context, token) do
    body =
      ~s(<d:sync-collection xmlns:d="DAV:"><d:sync-token>#{token}</d:sync-token>) <>
        ~s(<d:sync-level>1</d:sync-level><d:prop><d:getetag/></d:prop></d:sync-collection>)

    authed_dav(context, "REPORT", "/dav/addressbooks/default/", body)
  end

  defp initial_token(context) do
    conn = sync(context, "")

    [token] =
      Regex.run(~r{<d:sync-token>([^<]+)</d:sync-token>}, conn.resp_body, capture: :all_but_first)

    token
  end

  defp assert_invalid(conn) do
    assert conn.status == 403
    assert conn.resp_body =~ "<d:valid-sync-token/>"
  end

  test "CDV-56: an in-place restore (pg_restore --clean) refuses older tokens", context do
    ContactsFixtures.contact_fixture(context.account_id)
    token = initial_token(context)

    # --clean drops and recreates every table and sequence with its dumped
    # contents: same data, same values, new oids
    Repo.query!("ALTER TABLE contact_dav_changes RENAME TO contact_dav_changes_dumped")

    Repo.query!(
      "CREATE TABLE contact_dav_changes (LIKE contact_dav_changes_dumped INCLUDING ALL)"
    )

    Repo.query!("INSERT INTO contact_dav_changes SELECT * FROM contact_dav_changes_dumped")
    Repo.query!("DROP TABLE contact_dav_changes_dumped")

    # a later write in this account lifts its seq above the stale token
    ContactsFixtures.contact_fixture(context.account_id)

    assert_invalid(sync(context, token))
    assert sync(context, initial_token(context)).status == 207
  end

  test "CDV-56: kith_dav_rotate_sync_epoch() refuses every older token", context do
    ContactsFixtures.contact_fixture(context.account_id)
    token = initial_token(context)

    Repo.query!("SELECT kith_dav_rotate_sync_epoch()")

    assert_invalid(sync(context, token))
    assert sync(context, initial_token(context)).status == 207
  end
end
