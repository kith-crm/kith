defmodule Kith.Accounts.DavAppPasswordsTest do
  use Kith.DataCase, async: true
  alias Kith.Accounts.DavAppPasswords
  alias Kith.Accounts.User
  alias Kith.Repo
  import Kith.AccountsFixtures
  import ExUnit.CaptureLog

  defp fresh_user do
    user = user_fixture()
    assert user.confirmed_at
    %{user | authenticated_at: DateTime.utc_now(:second)}
  end

  test "revocation is immediate and owner-scoped" do
    user = fresh_user()
    other = fresh_user()
    {:ok, row, secret} = DavAppPasswords.create(user, %{name: "Pixel"})
    assert {:ok, _} = DavAppPasswords.authenticate(user.email, secret)
    assert {:error, :not_found} = DavAppPasswords.revoke(other, row.id)
    assert :ok = DavAppPasswords.revoke(user, row.id)
    assert {:error, :unauthorized} = DavAppPasswords.authenticate(user.email, secret)
    assert :ok = DavAppPasswords.revoke(user, row.id)
  end

  test "only hashes persist, inspection and logs redact secret material" do
    user = fresh_user()

    log =
      capture_log(fn ->
        {:ok, row, credential} = DavAppPasswords.create(user, %{name: " Phone "})
        assert credential =~ ~r/\Akith_dav_[A-Za-z0-9_-]{22}\.[A-Za-z0-9_-]{43}\z/
        [_, secret] = String.split(credential, ".")
        persisted = Repo.get!(row.__struct__, row.id)
        assert persisted.name == "Phone"
        assert byte_size(persisted.secret_hash) == 32
        refute inspect(persisted) =~ secret
        refute inspect(persisted) =~ inspect(persisted.secret_hash)
        refute Map.has_key?(Map.from_struct(persisted), :secret)
        assert persisted.secret_hash != secret
        send(self(), {:secret, secret})
      end)

    assert_receive {:secret, secret}
    refute log =~ secret
  end

  test "freshness is required before mutations and nonexistent owners cannot create" do
    user = fresh_user()
    {:ok, row, _} = DavAppPasswords.create(user, %{name: "Phone"})

    for timestamp <- [
          nil,
          DateTime.add(DateTime.utc_now(:second), -1201),
          DateTime.add(DateTime.utc_now(:second), 60)
        ] do
      stale = %{user | authenticated_at: timestamp}

      assert {:error, :reauthentication_required} =
               DavAppPasswords.create(stale, %{name: "Phone"})

      assert {:error, :reauthentication_required} = DavAppPasswords.revoke(stale, row.id)
    end

    Repo.delete!(Repo.get!(User, user.id))
    assert {:error, _} = DavAppPasswords.create(user, %{name: "Phone"})
  end

  test "names are trimmed, bounded and required; list is owner scoped" do
    user = fresh_user()
    other = fresh_user()

    for name <- [nil, "", "   ", String.duplicate("x", 81)] do
      assert {:error, %Ecto.Changeset{}} = DavAppPasswords.create(user, %{name: name})
    end

    {:ok, row, _} = DavAppPasswords.create(user, %{name: String.duplicate("x", 80)})
    assert [listed] = DavAppPasswords.list(user)
    assert listed.id == row.id
    assert [] = DavAppPasswords.list(other)

    for id <- ["bad-id", String.duplicate("9", 200), -1, nil, %{}] do
      assert {:error, :not_found} = DavAppPasswords.revoke(user, id)
    end
  end

  test "Unicode labels enforce the character bound without database errors" do
    user = fresh_user()
    name = String.duplicate("e\u0301", 40)
    assert {:ok, row, _} = DavAppPasswords.create(user, %{name: name})
    assert row.name == name
    assert {:error, %Ecto.Changeset{}} = DavAppPasswords.create(user, %{name: name <> "x"})
  end

  test "verification rejects malformed inputs, wrong owner and secret without elevating freshness" do
    user = fresh_user()
    other = fresh_user()
    {:ok, _, credential} = DavAppPasswords.create(user, %{name: "Phone"})
    assert {:ok, authenticated} = DavAppPasswords.authenticate(user.email, credential)
    assert authenticated.authenticated_at == nil

    for invalid <- [
          nil,
          "",
          "kith_dav_",
          credential <> "x",
          String.duplicate("x", 10000),
          String.replace_suffix(credential, String.last(credential), "!")
        ] do
      assert {:error, :unauthorized} = DavAppPasswords.authenticate(user.email, invalid)
    end

    [public, _] = String.split(credential, ".")

    assert {:error, :unauthorized} =
             DavAppPasswords.authenticate(user.email, public <> "." <> String.duplicate("A", 43))

    assert {:error, :unauthorized} = DavAppPasswords.authenticate(other.email, credential)
    Repo.update_all(from(u in User, where: u.id == ^other.id), set: [account_id: user.account_id])
    assert {:error, :unauthorized} = DavAppPasswords.authenticate(other.email, credential)
    assert [] = DavAppPasswords.list(other)

    assert {:error, :unauthorized} =
             DavAppPasswords.authenticate("missing@example.com", credential)

    Repo.update_all(from(u in User, where: u.id == ^user.id), set: [confirmed_at: nil])
    assert {:error, :unauthorized} = DavAppPasswords.authenticate(user.email, credential)
    Repo.delete!(Repo.get!(User, user.id))
    assert [] = DavAppPasswords.list(user)
    assert {:error, :unauthorized} = DavAppPasswords.authenticate(user.email, credential)
  end

  test "next request after a concurrent revocation reads authoritative state" do
    user = fresh_user()
    {:ok, row, credential} = DavAppPasswords.create(user, %{name: "Phone"})
    assert {:ok, _} = DavAppPasswords.authenticate(user.email, credential)
    task = Task.async(fn -> DavAppPasswords.revoke(user, row.id) end)
    assert :ok = Task.await(task)
    assert {:error, :unauthorized} = DavAppPasswords.authenticate(user.email, credential)
  end
end
