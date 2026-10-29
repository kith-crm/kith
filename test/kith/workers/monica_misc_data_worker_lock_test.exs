defmodule Kith.Workers.MonicaMiscDataWorkerLockTest do
  # Committed fixtures are required: NOWAIT below uses an independent database
  # connection to observe the importer's actual locks, not sandbox serialization.
  use ExUnit.Case, async: false

  import Ecto.Query
  import Kith.AccountsFixtures
  import Kith.ContactsFixtures
  import Kith.ImportsFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Kith.{Contacts, Imports, Repo}
  alias Kith.Workers.MonicaMiscDataWorker

  setup do
    Kith.TestEnv.put_env_restoring(:kith, :monica_req_options,
      plug: {Req.Test, __MODULE__},
      retry: false
    )

    fixture =
      unboxed(fn ->
        user = user_fixture()
        survivor = contact_fixture(user.account_id)
        loser = contact_fixture(user.account_id)

        import_job =
          import_fixture(user.account_id, user.id, %{
            source: "monica_api",
            api_url: "https://monica.test",
            api_key_encrypted: "test-key",
            status: "completed"
          })

        {:ok, _} = Imports.record_imported_entity(import_job, "contact", "1", "contact", loser.id)
        %{user: user, survivor: survivor, loser: loser, import_job: import_job}
      end)

    handler = {__MODULE__, make_ref()}
    :ok = :telemetry.attach(handler, [:kith, :repo, :query], &__MODULE__.barrier/4, nil)

    on_exit(fn ->
      :telemetry.detach(handler)

      unboxed(fn ->
        Repo.delete_all(
          from(j in Oban.Job,
            where: fragment("?->>'import_id'", j.args) == ^to_string(fixture.import_job.id)
          )
        )

        Repo.delete_all(from(a in Kith.Accounts.Account, where: a.id == ^fixture.user.account_id))
      end)
    end)

    fixture
  end

  # Stop after the response row has actually been inserted but before the
  # endpoint/checkpoint transaction commits, so contact locks are still held.
  def barrier(_event, _measurements, %{query: query}, _config) do
    case Process.get(:misc_response_gate) do
      owner when is_pid(owner) ->
        if String.starts_with?(query, ~s(INSERT INTO "calls")) do
          Process.delete(:misc_response_gate)
          send(owner, {:response_written, self()})

          receive do
            :continue_response -> :ok
          after
            5_000 -> raise "misc response gate was not released"
          end
        end

      _ ->
        :ok
    end
  end

  test "resolving a merged contact locks the live survivor but leaves the deleted loser unlocked",
       ctx do
    Req.Test.stub(__MODULE__, fn conn ->
      # The worker captured the original target before HTTP; fold it away only
      # now, so persistence must follow a mapping that changed in flight.
      {:ok, _} = Contacts.merge_contacts(ctx.survivor.id, ctx.loser.id)

      Req.Test.json(conn, %{
        "data" => [
          %{
            "id" => 90,
            "called_at" => "2025-01-01T10:00:00Z",
            "content" => "Current survivor"
          }
        ]
      })
    end)

    owner = self()

    job = %Oban.Job{
      attempt: 1,
      max_attempts: 3,
      args: %{
        "import_id" => ctx.import_job.id,
        "credential_url" => "https://monica.test",
        "plan" => [%{"source_id" => "1", "local_id" => ctx.loser.id, "endpoints" => ["calls"]}]
      }
    }

    task =
      Task.async(fn ->
        unboxed(fn ->
          Process.put(:misc_response_gate, owner)
          MonicaMiscDataWorker.perform(job)
        end)
      end)

    on_exit(fn -> if Process.alive?(task.pid), do: Process.exit(task.pid, :kill) end)
    assert_receive {:response_written, importer}, 5_000

    try do
      # A stale merge request may lock contacts in ascending order even though
      # its loser is already deleted. The importer must not retain that loser
      # while waiting for a lower-id survivor.
      unboxed(fn ->
        assert {:ok, %{rows: [[id]]}} =
                 Repo.transaction(fn ->
                   Repo.query!("SELECT id FROM contacts WHERE id = $1 FOR UPDATE NOWAIT", [
                     ctx.loser.id
                   ])
                 end)

        assert id == ctx.loser.id
      end)

      # FK insertion takes KEY SHARE on the survivor. NO KEY UPDATE is
      # compatible with that incidental lock, so this positive control proves
      # the explicit eligibility guard blocks a concurrent soft delete.
      error =
        assert_raise Postgrex.Error, fn ->
          unboxed(fn ->
            Repo.transaction(fn ->
              Repo.query!("SELECT id FROM contacts WHERE id = $1 FOR NO KEY UPDATE NOWAIT", [
                ctx.survivor.id
              ])
            end)
          end)
        end

      assert error.postgres.code == :lock_not_available
    after
      send(importer, :continue_response)
    end

    assert :ok = Task.await(task, 5_000)

    unboxed(fn ->
      assert [%{contact_id: id, notes: "Current survivor"}] =
               Repo.all(
                 from(c in Kith.Activities.Call, where: c.account_id == ^ctx.user.account_id)
               )

      assert id == ctx.survivor.id
    end)
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)
end
