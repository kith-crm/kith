defmodule PR44ReleaseSmoke do
  @moduledoc false
  import Ecto.Query
  require Logger

  alias Kith.Accounts.{Account, User}
  alias Kith.{Imports, Repo, Vault}
  alias Kith.Imports.JobCancellation
  alias Kith.Workers.{MonicaApiKeyReleaseWorker, MonicaDocumentImportWorker}

  @legacy_key Base.decode64!("oQaI0liBwsBX4ClJyWexY+lHhC3R3RPn1t9N8VPFdho=")
  # Captured from Cloak 1.1.4, using the public development key above.
  @legacy Base.decode64!(
            "AQpBRVMuR0NNLlYxUoO/SZBctykBlgqbOBpTeZSK99VT31TMEcEzz/Pg3PJHQlvjw2xDAKWqAHezobgesw=="
          )

  def run("roundtrip") do
    {:ok, _} = Application.ensure_all_started(:ssl)

    case Application.load(:kith) do
      :ok -> :ok
      {:error, {:already_loaded, :kith}} -> :ok
    end

    path = Application.app_dir(:kith, "priv/repo/migrations")

    {:ok, _, _} =
      Ecto.Migrator.with_repo(Repo, fn repo ->
        # The preceding migration is the last Kith migration at Oban schema 12.
        Ecto.Migrator.run(repo, path, :up, to: 20_261_015_120_000)
        expect_version("12")
        constraints = constraints()
        true = length(constraints) >= 6

        %{rows: rows} =
          repo.query!("""
          INSERT INTO oban_jobs (worker, queue, args, state, scheduled_at)
          VALUES ('Kith.Workers.ImportWorker', 'pr44_release_hold', '{"pr44":1}', 'available', now()),
                 ('Kith.Workers.ImportWorker', 'pr44_release_hold', '{"pr44":2}', 'scheduled', now() + interval '1 day')
          RETURNING id
          """)

        ids = List.flatten(rows)
        jobs = retained_jobs(ids)

        for {direction, target, expected} <- [
              {:up, 20_261_029_120_000, "14"},
              {:down, 20_261_029_120_000, "12"},
              {:up, 20_261_029_120_000, "14"}
            ] do
          # Ecto recompiles the source on each direction. Unload the completed
          # migration between runs rather than suppressing compiler warnings.
          :code.purge(Kith.Repo.Migrations.UpgradeObanToV14)
          :code.delete(Kith.Repo.Migrations.UpgradeObanToV14)
          Ecto.Migrator.run(repo, path, direction, to: target)
          expect_version(expected)
          ^constraints = constraints()
          ^jobs = retained_jobs(ids)
        end

        marker("oban_roundtrip", %{
          versions: [12, 14, 12, 14],
          jobs: 2,
          constraints: length(constraints)
        })
      end)
  end

  def run(mode) when mode in ["web", "worker", "enabled"] do
    expected_dsn = if mode == "enabled", do: :enabled, else: :disabled
    actual_dsn = if is_nil(Sentry.Config.dsn()), do: :disabled, else: :enabled
    ^expected_dsn = actual_dsn
    true = is_pid(Process.whereis(Repo))
    true = is_pid(Process.whereis(Kith.PubSub))
    true = is_pid(Process.whereis(Kith.TaskSupervisor))
    true = is_pid(Oban.whereis(Oban))

    if mode == "worker" do
      nil = Process.whereis(KithWeb.Endpoint)
      nil = Process.whereis(Kith.PromEx)
      :ok = Kith.Imports.Sources.MonicaApi.RateLimiter.wait!("https://pr44.invalid")
    else
      true = is_pid(Process.whereis(KithWeb.Endpoint))
    end

    {:ok, ciphertext} = Vault.encrypt("pr44-do-not-log-credential")
    {:ok, "pr44-do-not-log-credential"} = Vault.decrypt(ciphertext)
    :error = Vault.decrypt("malformed")

    if mode == "web", do: credentials()
    # RPC normally forwards logs to the caller's group leader, whose CLI
    # formatter is unrelated to the production node's console formatter.
    Task.async(fn ->
      Process.group_leader(self(), Process.whereis(:user))
      Logger.info("PR44_RELEASE_LOG #{mode}", account_id: 44, request_id: "pr44-smoke")
      Logger.flush()
    end)
    |> Task.await()

    marker("boot", %{mode: mode, sentry: actual_dsn})
  end

  defp credentials do
    account = Repo.insert!(%Account{name: "PR44 synthetic release account"})

    user =
      Repo.insert!(%User{
        account_id: account.id,
        email: "release-#{account.id}@example.invalid",
        hashed_password: Pbkdf2.hash_pwd_salt(Base.encode64(:crypto.strong_rand_bytes(32)))
      })

    {:ok, import} =
      Imports.create_import(account.id, user.id, %{
        source: "monica_api",
        api_url: "https://pr44.invalid"
      })

    previous = Application.fetch_env!(:kith, Vault)

    try do
      Application.put_env(:kith, Vault, key: @legacy_key)

      Repo.update_all(from(a in "accounts", where: a.id == ^account.id),
        set: [immich_api_key: @legacy]
      )

      Repo.update_all(from(i in "imports", where: i.id == ^import.id),
        set: [api_key_encrypted: @legacy]
      )

      "legacy credential" = Repo.get!(Account, account.id).immich_api_key
      "legacy credential" = Imports.get_import!(import.id).api_key_encrypted

      args = %{
        "account_id" => account.id,
        "user_id" => user.id,
        "contact_id" => 0,
        "import_id" => import.id,
        "credential_url" => "https://pr44.invalid",
        "documents" => []
      }

      {:ok, job} = Oban.insert(MonicaDocumentImportWorker.new(args, schedule_in: 86_400))
      false = Map.has_key?(job.args, "api_key")
      :ok = MonicaDocumentImportWorker.perform(job)

      {:snooze, 60} =
        MonicaApiKeyReleaseWorker.perform(%Oban.Job{args: %{"import_id" => import.id}})

      "legacy credential" = Imports.get_import!(import.id).api_key_encrypted
      :ok = JobCancellation.wipe_for_account(account.id)
      "cancelled" = Repo.reload!(job).state
      :ok = MonicaApiKeyReleaseWorker.perform(%Oban.Job{args: %{"import_id" => import.id}})
      nil = Imports.get_import!(import.id).api_key_encrypted
    after
      Application.put_env(:kith, Vault, previous)
    end

    {:ok, updated} =
      Kith.Immich.Settings.update_settings(account, %{
        immich_api_key: "pr44-do-not-log-credential"
      })

    "pr44-do-not-log-credential" = Repo.reload!(updated).immich_api_key

    {:ok, updated_import} =
      import
      |> Ecto.Changeset.change(api_key_encrypted: "pr44-do-not-log-credential")
      |> Repo.update()

    "pr44-do-not-log-credential" = Repo.reload!(updated_import).api_key_encrypted

    for {table, id, column} <- [
          {"accounts", account.id, "immich_api_key"},
          {"imports", import.id, "api_key_encrypted"}
        ] do
      %{rows: [[raw]]} = Repo.query!("SELECT #{column} FROM #{table} WHERE id=$1", [id])
      <<1, 10, "AES.GCM.V1", iv::binary-size(16), mac::binary-size(16), body::binary>> = raw
      key = Keyword.fetch!(previous, :key)

      "pr44-do-not-log-credential" =
        :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, body, "AES256GCM", mac, false)
    end

    {:ok, _} = Imports.wipe_api_key(updated_import)

    marker("credentials", %{
      columns: 2,
      legacy_rows: 2,
      continued_document_job: true,
      key_release: true
    })
  end

  defp expect_version(expected) do
    %{rows: [[^expected]]} = Repo.query!("SELECT obj_description('public.oban_jobs'::regclass)")
  end

  defp constraints do
    Repo.query!("""
    SELECT conname, pg_get_constraintdef(oid) FROM pg_constraint
    WHERE conrelid='public.oban_jobs'::regclass ORDER BY conname
    """).rows
  end

  defp retained_jobs(ids) do
    Repo.query!(
      "SELECT id, args, state::text, worker, queue, scheduled_at FROM oban_jobs WHERE id=ANY($1) ORDER BY id",
      [ids]
    ).rows
  end

  defp marker(check, details),
    do: IO.puts(Jason.encode!(Map.merge(%{pr44_release_check: check, status: "passed"}, details)))
end

PR44ReleaseSmoke.run(System.fetch_env!("PR44_RELEASE_PROBE"))
