defmodule Mix.Tasks.Kith.Duplicates.AutomergeTest do
  use Kith.DataCase, async: false

  import Kith.Factory
  import Kith.ContactsFixtures

  alias Kith.Contacts.Contact
  alias Kith.Contacts.DuplicateCandidate
  alias Mix.Tasks.Kith.Duplicates.Automerge

  setup do
    seed_reference_data!()
    {account, _user} = setup_account()
    %{account: account}
  end

  defp active_count(account_id) do
    Contact
    |> where([c], c.account_id == ^account_id and is_nil(c.deleted_at))
    |> Repo.aggregate(:count)
  end

  # A strong-edge pair: identical name AND a shared email, which the detector
  # scores at 1.0 with a concrete signal. A name-only pair is never auto-merged.
  defp identical_pair(account) do
    email_type_id =
      Repo.one!(
        from(t in "contact_field_types", where: t.protocol == "mailto:", select: t.id, limit: 1)
      )

    a =
      insert(:contact,
        account: account,
        display_name: "Uma Vale",
        first_name: "Uma",
        last_name: "Vale"
      )

    b =
      insert(:contact,
        account: account,
        display_name: "Uma Vale",
        first_name: "Uma",
        last_name: "Vale"
      )

    contact_field_fixture(a, email_type_id, %{"value" => "uma@example.com"})
    contact_field_fixture(b, email_type_id, %{"value" => "uma@example.com"})

    {a, b}
  end

  test "--dry-run writes nothing at all", %{account: account} do
    identical_pair(account)

    Mix.shell(Mix.Shell.Process)

    Automerge.run(["--account", Integer.to_string(account.id), "--dry-run"])

    # Both contacts still active, and the detector scan the pass runs is rolled
    # back, so not a single DuplicateCandidate row persists.
    assert active_count(account.id) == 2

    assert Repo.aggregate(
             from(d in DuplicateCandidate, where: d.account_id == ^account.id),
             :count
           ) == 0
  after
    Mix.shell(Mix.Shell.IO)
  end

  test "without --dry-run it merges the cluster", %{account: account} do
    identical_pair(account)

    Mix.shell(Mix.Shell.Process)

    Automerge.run(["--account", Integer.to_string(account.id)])

    assert active_count(account.id) == 1
    assert Kith.DuplicateDetection.cluster_count(account.id) == 0
  after
    Mix.shell(Mix.Shell.IO)
  end

  test "requires --account" do
    assert_raise Mix.Error, fn -> Automerge.run([]) end
  end
end
