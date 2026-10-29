defmodule Kith.AccountsWebauthnTest do
  use Kith.DataCase

  alias Kith.Accounts
  alias Kith.Accounts.WebauthnCredential
  import Kith.AccountsFixtures

  @fake_cose_key %{
    1 => 2,
    3 => -7,
    -1 => 1,
    -2 => :crypto.strong_rand_bytes(32),
    -3 => :crypto.strong_rand_bytes(32)
  }

  defp create_credential(user, opts \\ []) do
    name = Keyword.get(opts, :name, "Test Key")

    %WebauthnCredential{}
    |> WebauthnCredential.changeset(%{
      user_id: user.id,
      credential_id: Keyword.get(opts, :credential_id, :crypto.strong_rand_bytes(32)),
      public_key: :erlang.term_to_binary(@fake_cose_key),
      sign_count: 0,
      name: name
    })
    |> Kith.Repo.insert!()
  end

  test "allow credentials skips corrupted stored keys and preserves valid credential ownership" do
    user = user_fixture()
    valid = create_credential(user)
    invalid = create_credential(user)
    invalid |> Ecto.Changeset.change(public_key: <<131, 255>>) |> Kith.Repo.update!()
    create_credential(user_fixture())

    assert Accounts.get_webauthn_allow_credentials(user) == [
             {valid.credential_id, @fake_cose_key}
           ]
  end

  describe "list_webauthn_credentials/1" do
    test "returns credentials for the user" do
      user = user_fixture()
      c1 = create_credential(user, name: "Key 1")
      c2 = create_credential(user, name: "Key 2")

      creds = Accounts.list_webauthn_credentials(user)
      ids = Enum.map(creds, & &1.id)
      assert c1.id in ids
      assert c2.id in ids
    end

    test "does not return other users' credentials" do
      user1 = user_fixture()
      user2 = user_fixture()
      create_credential(user1, name: "User1 Key")

      assert Accounts.list_webauthn_credentials(user2) == []
    end
  end

  describe "get_webauthn_credential/2" do
    test "returns credential scoped to user" do
      user = user_fixture()
      cred = create_credential(user)

      assert Accounts.get_webauthn_credential(user, cred.id).id == cred.id
    end

    test "returns nil for other user's credential" do
      user1 = user_fixture()
      user2 = user_fixture()
      cred = create_credential(user1)

      assert is_nil(Accounts.get_webauthn_credential(user2, cred.id))
    end
  end

  describe "get_webauthn_credential_by_credential_id/1" do
    test "returns credential with preloaded user and account" do
      user = user_fixture()
      cred = create_credential(user)

      found = Accounts.get_webauthn_credential_by_credential_id(cred.credential_id)
      assert found.id == cred.id
      assert found.user.id == user.id
      assert found.user.account != nil
    end

    test "returns nil for unknown credential_id" do
      assert is_nil(
               Accounts.get_webauthn_credential_by_credential_id(:crypto.strong_rand_bytes(32))
             )
    end
  end

  describe "get_webauthn_allow_credentials/1" do
    test "returns list of {credential_id, cose_key} tuples" do
      user = user_fixture()
      cred = create_credential(user)

      allow = Accounts.get_webauthn_allow_credentials(user)
      assert length(allow) == 1
      [{cred_id, cose_key}] = allow
      assert cred_id == cred.credential_id
      assert is_map(cose_key)
    end
  end

  describe "register_webauthn_credential/3" do
    test "stores credential from auth_data" do
      user = user_fixture()
      cred_id = :crypto.strong_rand_bytes(32)

      # Simulate auth_data structure from Wax.register/3
      auth_data = %{
        attested_credential_data: %{
          credential_id: cred_id,
          credential_public_key: @fake_cose_key
        },
        sign_count: 0
      }

      assert {:ok, credential} =
               Accounts.register_webauthn_credential(user, auth_data, "My Passkey")

      assert credential.credential_id == cred_id
      assert credential.name == "My Passkey"
      assert credential.sign_count == 0
      assert credential.user_id == user.id

      # Verify public key can be deserialized
      assert :erlang.binary_to_term(credential.public_key) == @fake_cose_key
    end

    test "rejects duplicate credential_id" do
      user = user_fixture()
      cred_id = :crypto.strong_rand_bytes(32)

      auth_data = %{
        attested_credential_data: %{
          credential_id: cred_id,
          credential_public_key: @fake_cose_key
        },
        sign_count: 0
      }

      assert {:ok, _} = Accounts.register_webauthn_credential(user, auth_data, "Key 1")
      assert {:error, changeset} = Accounts.register_webauthn_credential(user, auth_data, "Key 2")
      assert errors_on(changeset).credential_id != nil
    end
  end

  describe "touch_webauthn_credential/2" do
    test "updates sign_count and last_used_at" do
      user = user_fixture()
      cred = create_credential(user)
      assert is_nil(cred.last_used_at)

      assert {:ok, updated} = Accounts.touch_webauthn_credential(cred, 5)
      assert updated.sign_count == 5
      assert updated.last_used_at != nil
    end
  end

  describe "delete_webauthn_credential/2" do
    test "deletes credential when user has a password" do
      user = user_fixture()
      cred = create_credential(user)

      assert {:ok, _} = Accounts.delete_webauthn_credential(user, cred.id)
      assert Accounts.list_webauthn_credentials(user) == []
    end

    test "returns :not_found for non-existent credential" do
      user = user_fixture()
      assert {:error, :not_found} = Accounts.delete_webauthn_credential(user, 999_999)
    end

    test "allows deletion when other credentials exist" do
      user = user_fixture()
      cred1 = create_credential(user, name: "Key 1")
      _cred2 = create_credential(user, name: "Key 2")

      assert {:ok, _} = Accounts.delete_webauthn_credential(user, cred1.id)
      assert length(Accounts.list_webauthn_credentials(user)) == 1
    end
  end

  describe "has_login_method?/1" do
    test "returns true when user has a password" do
      user = user_fixture()
      assert Accounts.has_login_method?(user)
    end

    test "returns true when user has WebAuthn credentials" do
      user = user_fixture()
      create_credential(user)
      assert Accounts.has_login_method?(user)
    end
  end

  describe "webauthn_opts/0" do
    test "returns origin and rp_id" do
      opts = Accounts.webauthn_opts()
      assert Keyword.has_key?(opts, :origin)
      assert Keyword.has_key?(opts, :rp_id)
    end
  end
end
