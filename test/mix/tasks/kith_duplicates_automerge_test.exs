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

  defp identical_pair(account) do
    insert(:contact,
      account: account,
      display_name: "Uma Vale",
      first_name: "Uma",
      last_name: "Vale"
    )

    insert(:contact,
      account: account,
      display_name: "Uma Vale",
      first_name: "Uma",
      last_name: "Vale"
    )
  end

  test "--dry-run reports the merge but writes nothing", %{account: account} do
    identical_pair(account)

    Mix.shell(Mix.Shell.Process)

    Automerge.run(["--account", Integer.to_string(account.id), "--dry-run"])

    assert active_count(account.id) == 2

    # No candidate rows were resolved — the pair is still pending.
    assert Repo.aggregate(
             from(d in DuplicateCandidate,
               where: d.account_id == ^account.id and d.status == "merged"
             ),
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
