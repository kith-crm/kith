defmodule Kith.Workers.DisplayNameBoundaryTest do
  use Kith.DataCase, async: true

  import Kith.AccountsFixtures
  import Kith.ContactsFixtures

  alias Kith.{Accounts, Repo}
  alias Kith.DAV.{ContactDav, VCardAdapter}
  alias Kith.Workers.DisplayNameRecomputeWorker, as: Worker

  setup do
    user = user_fixture()
    contact = contact_fixture(user.account_id, %{first_name: "Ada", last_name: "Lovelace"})
    %{user: user, contact: contact}
  end

  test "an obsolete job reads its user's latest persisted preference", c do
    c.user |> Ecto.Changeset.change(display_name_format: "last_first_comma") |> Repo.update!()
    before = Repo.get!(ContactDav, c.contact.id)

    assert :ok = perform(c.user, "first_only")
    assert Repo.reload!(c.contact).display_name == "Lovelace, Ada"
    assert Repo.get!(ContactDav, c.contact.id).revision > before.revision
  end

  test "a job cannot select a user outside its account", c do
    other = user_fixture()
    other |> Ecto.Changeset.change(display_name_format: "last_first") |> Repo.update!()
    before_contact = Repo.reload!(c.contact)
    before_dav = Repo.get!(ContactDav, c.contact.id)

    assert :ok =
             Worker.perform(%Oban.Job{
               args: %{
                 "account_id" => c.user.account_id,
                 "user_id" => other.id,
                 "display_name_format" => "first_only"
               }
             })

    assert Repo.reload!(c.contact) == before_contact
    assert Repo.get!(ContactDav, c.contact.id) == before_dav
  end

  test "repeating the current preference leaves DAV bytes and publication unchanged", c do
    c.user |> Ecto.Changeset.change(display_name_format: "first_last") |> Repo.update!()
    assert :ok = perform(c.user, "last_first")
    before = Repo.get!(ContactDav, c.contact.id)
    wire = VCardAdapter.contact_to_vcard(Repo.reload!(c.contact))

    assert :ok = perform(c.user, "first_only")
    assert Repo.get!(ContactDav, c.contact.id) == before
    assert VCardAdapter.contact_to_vcard(Repo.reload!(c.contact)) == wire
  end

  test "pending account jobs replace obsolete args with the latest user preference", c do
    assert {:ok, user} =
             Accounts.update_user_profile(c.user, %{display_name_format: "first_only"})

    assert {:ok, user} = Accounts.update_user_profile(user, %{display_name_format: "last_first"})

    jobs = Repo.all(from j in Oban.Job, where: j.worker == ^Oban.Worker.to_string(Worker))
    assert [job] = jobs
    assert job.args["account_id"] == user.account_id
    assert job.args["user_id"] == user.id
    assert job.args["display_name_format"] == "last_first"

    changeset = Worker.new(%{account_id: user.account_id, user_id: user.id})
    unique = Ecto.Changeset.get_field(changeset, :unique)
    refute :executing in unique.states
    refute :completed in unique.states
  end

  test "legacy jobs keep their explicit format without guessing between account users", c do
    other = user_fixture()

    other
    |> Ecto.Changeset.change(account_id: c.user.account_id, display_name_format: "last_first")
    |> Repo.update!()

    assert :ok =
             Worker.perform(%Oban.Job{
               args: %{
                 "account_id" => c.user.account_id,
                 "display_name_format" => "first_only"
               }
             })

    assert Repo.reload!(c.contact).display_name == "Ada"
  end

  defp perform(user, obsolete_format) do
    Worker.perform(%Oban.Job{
      args: %{
        "account_id" => user.account_id,
        "user_id" => user.id,
        "display_name_format" => obsolete_format
      }
    })
  end
end
