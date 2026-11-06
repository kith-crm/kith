defmodule Kith.VaultCredentialsIntegrationTest do
  use Kith.DataCase, async: false
  use Oban.Testing, repo: Kith.Repo

  alias Kith.Accounts.Account
  alias Kith.Immich.Settings
  alias Kith.Imports
  alias Kith.Imports.JobCancellation
  alias Kith.Workers.{MonicaApiKeyReleaseWorker, MonicaPhotoSyncWorker}

  import Kith.AccountsFixtures

  @legacy_ciphertext Base.decode64!(
                       "AQpBRVMuR0NNLlYxUoO/SZBctykBlgqbOBpTeZSK99VT31TMEcEzz/Pg3PJHQlvjw2xDAKWqAHezobgesw=="
                     )

  setup do
    previous = Application.fetch_env!(:kith, Kith.Vault)

    Application.put_env(:kith, Kith.Vault,
      key: Base.decode64!("oQaI0liBwsBX4ClJyWexY+lHhC3R3RPn1t9N8VPFdho=")
    )

    on_exit(fn -> Application.put_env(:kith, Kith.Vault, previous) end)
    user = user_fixture()
    %{user: user}
  end

  test "existing Immich ciphertext loads and new settings persist encrypted", %{user: user} do
    # Schemaless writes deliberately bypass the new Ecto type to simulate old rows.
    Repo.update_all(from(a in "accounts", where: a.id == ^user.account_id),
      set: [immich_api_key: @legacy_ciphertext]
    )

    account = Repo.get!(Account, user.account_id)
    assert Settings.get_settings(account).api_key == "legacy credential"
    assert {:ok, updated} = Settings.update_settings(account, %{immich_api_key: "new credential"})
    assert Repo.reload!(updated).immich_api_key == "new credential"

    raw =
      Repo.one(from(a in "accounts", where: a.id == ^user.account_id, select: a.immich_api_key))

    assert <<1, 10, "AES.GCM.V1", _::binary>> = raw
    refute raw == "new credential"
  end

  test "queued follow-ups retain old credentials until cancellation and key release", %{
    user: user
  } do
    {:ok, import} =
      Imports.create_import(user.account_id, user.id, %{
        source: "monica_api",
        api_url: "https://monica.test"
      })

    Repo.update_all(from(i in "imports", where: i.id == ^import.id),
      set: [api_key_encrypted: @legacy_ciphertext]
    )

    {:ok, followup} = Oban.insert(MonicaPhotoSyncWorker.new(%{"import_id" => import.id}))
    assert followup.args == %{"import_id" => import.id}
    assert Imports.get_import!(import.id).api_key_encrypted == "legacy credential"

    assert {:snooze, 60} = perform_job(MonicaApiKeyReleaseWorker, %{import_id: import.id})
    assert Imports.get_import!(import.id).api_key_encrypted == "legacy credential"
    assert :ok = JobCancellation.wipe_for_account(user.account_id)
    assert Repo.reload!(followup).state == "cancelled"
    assert :ok = perform_job(MonicaApiKeyReleaseWorker, %{import_id: import.id})
    assert is_nil(Imports.get_import!(import.id).api_key_encrypted)

    assert Repo.one(from(i in "imports", where: i.id == ^import.id, select: i.api_key_encrypted)) ==
             nil
  end
end
