defmodule Kith.Workers.ImportApiKeySweepWorkerTest do
  use Kith.DataCase, async: true
  use Oban.Testing, repo: Kith.Repo

  alias Kith.Imports
  alias Kith.Imports.Import
  alias Kith.Workers.ImportApiKeySweepWorker

  import Kith.AccountsFixtures
  import Kith.ImportsFixtures

  test "wipes keys left on imports finished more than 24h ago and keeps recent ones" do
    stale = monica_import!()
    fresh = monica_import!()

    finished!(stale, hours_ago(25))
    finished!(fresh, hours_ago(2))

    assert :ok = perform_job(ImportApiKeySweepWorker, %{})

    assert is_nil(Imports.get_import!(stale.id).api_key_encrypted)
    assert Imports.get_import!(fresh.id).api_key_encrypted == "test-key"
  end

  test "is scheduled in the Oban crontab" do
    crontab =
      Application.fetch_env!(:kith, Oban)
      |> Keyword.fetch!(:plugins)
      |> Enum.find_value(fn
        {Oban.Plugins.Cron, opts} -> opts[:crontab]
        _ -> nil
      end)

    assert Enum.any?(crontab, &match?({_, ImportApiKeySweepWorker}, &1))
  end

  # Each import needs its own account: only one pending import per account.
  defp monica_import! do
    user = user_fixture()

    import_fixture(user.account_id, user.id, %{
      source: "monica_api",
      api_url: "https://monica.test",
      api_key_encrypted: "test-key"
    })
  end

  defp finished!(import, at) do
    Repo.update_all(from(i in Import, where: i.id == ^import.id),
      set: [status: "completed", completed_at: at]
    )
  end

  defp hours_ago(hours),
    do: DateTime.utc_now() |> DateTime.add(-hours * 3600, :second) |> DateTime.truncate(:second)
end
