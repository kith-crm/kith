defmodule Kith.Workers.MonicaMiscDataWorkerTest do
  use Kith.DataCase, async: false
  use Oban.Testing, repo: Kith.Repo

  import Ecto.Query
  import ExUnit.CaptureLog
  import Kith.AccountsFixtures
  import Kith.ContactsFixtures
  import Kith.ImportsFixtures

  alias Kith.Imports
  alias Kith.Reminders.Reminder
  alias Kith.TimeHelper
  alias Kith.Workers.MonicaMiscDataWorker

  @stub_name MonicaMiscDataReqStub

  setup do
    seed_reference_data!()
    user = user_fixture()

    Application.put_env(
      :kith,
      :monica_req_options,
      plug: {Req.Test, @stub_name},
      retry: false
    )

    on_exit(fn -> Application.delete_env(:kith, :monica_req_options) end)

    %{user: user, account_id: user.account_id}
  end

  defp build_args(import_job, plan) do
    %{
      "import_id" => import_job.id,
      "credential_url" => "https://monica.test",
      "credential_api_key" => "test-key",
      "plan" => plan
    }
  end

  defp api_import(account_id, user_id, api_options \\ %{}) do
    import_fixture(account_id, user_id, %{
      source: "monica_api",
      api_url: "https://monica.test",
      api_key_encrypted: "test-key",
      api_options: api_options,
      status: "completed"
    })
  end

  describe "perform/1" do
    test "fires only the endpoints listed in the plan",
         %{user: user, account_id: account_id} do
      contact = contact_fixture(account_id)
      import_job = api_import(account_id, user.id)

      pid = self()

      Req.Test.stub(@stub_name, fn conn ->
        send(pid, {:request, conn.request_path})
        Req.Test.json(conn, %{"data" => []})
      end)

      plan = [
        %{
          "source_id" => "42",
          "local_id" => contact.id,
          "endpoints" => ["calls", "gifts"]
        }
      ]

      assert :ok = perform_job(MonicaMiscDataWorker, build_args(import_job, plan))

      paths = collect_requests([])
      assert "/api/contacts/42/calls" in paths
      assert "/api/contacts/42/gifts" in paths
      refute "/api/contacts/42/pets" in paths
      refute "/api/contacts/42/activities" in paths
    end

    test "exits early when the import is cancelled",
         %{user: user, account_id: account_id} do
      import_job = api_import(account_id, user.id)
      {:ok, _} = Imports.update_import_status(import_job, "cancelled", %{})

      contact = contact_fixture(account_id)
      pid = self()

      Req.Test.stub(@stub_name, fn conn ->
        send(pid, {:request, conn.request_path})
        Req.Test.json(conn, %{"data" => []})
      end)

      plan = [%{"source_id" => "1", "local_id" => contact.id, "endpoints" => ["calls"]}]

      assert :ok = perform_job(MonicaMiscDataWorker, build_args(import_job, plan))

      assert collect_requests([]) == []
    end

    test "skips contacts whose local row has been soft-deleted",
         %{user: user, account_id: account_id} do
      import_job = api_import(account_id, user.id)
      contact = contact_fixture(account_id)

      Repo.update_all(
        from(c in Kith.Contacts.Contact, where: c.id == ^contact.id),
        set: [deleted_at: DateTime.utc_now() |> DateTime.truncate(:second)]
      )

      pid = self()

      Req.Test.stub(@stub_name, fn conn ->
        send(pid, {:request, conn.request_path})
        Req.Test.json(conn, %{"data" => []})
      end)

      plan = [%{"source_id" => "1", "local_id" => contact.id, "endpoints" => ["calls"]}]

      assert :ok = perform_job(MonicaMiscDataWorker, build_args(import_job, plan))

      assert collect_requests([]) == []
    end

    test "writes per-endpoint counts to import_job.summary['misc']",
         %{user: user, account_id: account_id} do
      contact = contact_fixture(account_id)
      import_job = api_import(account_id, user.id)

      Req.Test.stub(@stub_name, fn conn ->
        case conn.request_path do
          "/api/contacts/1/calls" ->
            Req.Test.json(conn, %{
              "data" => [
                %{"id" => 1, "called_at" => "2025-01-01T10:00:00Z", "contact_called" => true},
                %{"id" => 2, "called_at" => "2025-01-02T10:00:00Z", "contact_called" => false}
              ]
            })

          _ ->
            Req.Test.json(conn, %{"data" => []})
        end
      end)

      plan = [%{"source_id" => "1", "local_id" => contact.id, "endpoints" => ["calls"]}]

      assert :ok = perform_job(MonicaMiscDataWorker, build_args(import_job, plan))

      updated = Imports.get_import!(import_job.id)
      assert is_map(updated.summary["misc"])
      assert updated.summary["misc"]["calls"] >= 0
    end
  end

  describe "reminders import — date handling (issue #5)" do
    setup %{user: user, account_id: account_id} do
      %{import_job: api_import(account_id, user.id)}
    end

    test "object-shaped next_expected_date is parsed to the underlying date", %{
      account_id: account_id,
      import_job: import_job
    } do
      contact = contact_fixture(account_id)

      assert :ok =
               import_reminders(import_job, contact, [
                 %{
                   "id" => 1,
                   "frequency_type" => "one_time",
                   "title" => "Call about the move",
                   "next_expected_date" => %{"date" => "2024-06-01 00:00:00", "timezone" => "UTC"}
                 }
               ])

      assert [reminder] = contact_reminders(account_id, contact.id)
      assert reminder.next_reminder_date == ~D[2024-06-01]
      assert reminder.type == "one_time"
    end

    test "plain ISO string next_expected_date is parsed", %{
      account_id: account_id,
      import_job: import_job
    } do
      contact = contact_fixture(account_id)

      assert :ok =
               import_reminders(import_job, contact, [
                 %{
                   "id" => 2,
                   "frequency_type" => "one_time",
                   "title" => "Follow up",
                   "next_expected_date" => "2024-07-15"
                 }
               ])

      assert [reminder] = contact_reminders(account_id, contact.id)
      assert reminder.next_reminder_date == ~D[2024-07-15]
    end

    test "falls back to a future initial_date when next_expected_date is absent", %{
      account_id: account_id,
      import_job: import_job
    } do
      contact = contact_fixture(account_id)
      future = Date.utc_today() |> Date.add(30) |> Date.to_iso8601()

      assert :ok =
               import_reminders(import_job, contact, [
                 %{
                   "id" => 3,
                   "frequency_type" => "one_time",
                   "title" => "Renew passport",
                   "next_expected_date" => nil,
                   "initial_date" => %{"date" => "#{future} 00:00:00"}
                 }
               ])

      assert [reminder] = contact_reminders(account_id, contact.id)
      assert reminder.next_reminder_date == Date.from_iso8601!(future)
    end

    test "a past initial_date fallback is pulled forward to today with a warning", %{
      account_id: account_id,
      import_job: import_job
    } do
      contact = contact_fixture(account_id)

      log =
        capture_log(fn ->
          assert :ok =
                   import_reminders(import_job, contact, [
                     %{
                       "id" => 4,
                       "frequency_type" => "one_time",
                       "title" => "Renew passport",
                       "next_expected_date" => nil,
                       "initial_date" => %{"date" => "2015-03-09 00:00:00"}
                     }
                   ])
        end)

      assert [reminder] = contact_reminders(account_id, contact.id)
      assert reminder.next_reminder_date == Date.utc_today()
      assert log =~ "reminder 4 initial_date 2015-03-09 is in the past"
    end

    test "an explicit past next_expected_date is kept, not clamped", %{
      account_id: account_id,
      import_job: import_job
    } do
      contact = contact_fixture(account_id)

      assert :ok =
               import_reminders(import_job, contact, [
                 %{
                   "id" => 5,
                   "frequency_type" => "one_time",
                   "title" => "Historical note",
                   "next_expected_date" => "2020-01-01"
                 }
               ])

      assert [reminder] = contact_reminders(account_id, contact.id)
      assert reminder.next_reminder_date == ~D[2020-01-01]
    end

    test "a blank title on a non-birthday reminder gets the default title", %{
      account_id: account_id,
      import_job: import_job
    } do
      contact = contact_fixture(account_id)

      assert :ok =
               import_reminders(import_job, contact, [
                 %{
                   "id" => 6,
                   "frequency_type" => "year",
                   "title" => "",
                   "next_expected_date" => "2030-05-01"
                 }
               ])

      assert [reminder] = contact_reminders(account_id, contact.id)
      assert reminder.type == "recurring"
      assert reminder.title == "Imported reminder"
    end

    test "with no parseable date, uses today and logs a warning", %{
      account_id: account_id,
      import_job: import_job
    } do
      contact = contact_fixture(account_id)

      log =
        capture_log(fn ->
          assert :ok =
                   import_reminders(import_job, contact, [
                     %{"id" => 42, "frequency_type" => "one_time", "title" => "Mystery"}
                   ])
        end)

      assert [reminder] = contact_reminders(account_id, contact.id)
      assert reminder.next_reminder_date == Date.utc_today()
      assert log =~ "reminder 42 has no parseable date"
    end

    test "year frequency + blank title + contact birthdate creates a single birthday reminder", %{
      account_id: account_id,
      import_job: import_job
    } do
      contact = contact_fixture(account_id, %{birthdate: ~D[1990-06-15]})

      assert :ok =
               import_reminders(import_job, contact, [
                 %{
                   "id" => 9,
                   "frequency_type" => "year",
                   "title" => "",
                   "next_expected_date" => %{"date" => "2024-06-15 00:00:00"}
                 }
               ])

      assert [reminder] = contact_reminders(account_id, contact.id)
      assert reminder.type == "birthday"
      assert reminder.next_reminder_date == TimeHelper.next_birthday_date(~D[1990-06-15])
    end

    test "year frequency birthday reminder does not duplicate an existing one", %{
      account_id: account_id,
      import_job: import_job
    } do
      contact = contact_fixture(account_id, %{birthdate: ~D[1990-06-15]})

      payload = [
        %{
          "id" => 9,
          "frequency_type" => "year",
          "title" => "",
          "next_expected_date" => %{"date" => "2024-06-15 00:00:00"}
        }
      ]

      assert :ok = import_reminders(import_job, contact, payload)
      assert :ok = import_reminders(import_job, contact, payload)

      assert [reminder] = contact_reminders(account_id, contact.id)
      assert reminder.type == "birthday"
    end

    test "year frequency with a real title stays a generic recurring reminder", %{
      account_id: account_id,
      import_job: import_job
    } do
      contact = contact_fixture(account_id, %{birthdate: ~D[1990-06-15]})

      assert :ok =
               import_reminders(import_job, contact, [
                 %{
                   "id" => 10,
                   "frequency_type" => "year",
                   "title" => "Wedding anniversary",
                   "next_expected_date" => %{"date" => "2024-09-20 00:00:00"}
                 }
               ])

      assert [reminder] = contact_reminders(account_id, contact.id)
      assert reminder.type == "recurring"
      assert reminder.frequency == "annually"
      assert reminder.next_reminder_date == ~D[2024-09-20]
    end

    test "an untitled annual reminder on a non-birthday date stays generic", %{
      account_id: account_id,
      import_job: import_job
    } do
      contact = contact_fixture(account_id, %{birthdate: ~D[1990-06-15]})

      assert :ok =
               import_reminders(import_job, contact, [
                 %{
                   "id" => 11,
                   "frequency_type" => "year",
                   "title" => "",
                   "next_expected_date" => %{"date" => "2030-09-20 00:00:00"}
                 }
               ])

      assert [reminder] = contact_reminders(account_id, contact.id)
      assert reminder.type == "recurring"
      assert reminder.next_reminder_date == ~D[2030-09-20]
    end

    test "re-importing after a birthdate is added converts the generic reminder in place", %{
      account_id: account_id,
      import_job: import_job
    } do
      contact = contact_fixture(account_id)

      payload = [
        %{
          "id" => 9,
          "frequency_type" => "year",
          "title" => "",
          "next_expected_date" => %{"date" => "2024-06-15 00:00:00"}
        }
      ]

      assert :ok = import_reminders(import_job, contact, payload)
      assert [generic] = contact_reminders(account_id, contact.id)
      assert generic.type == "recurring"

      {:ok, contact} = Kith.Contacts.update_contact(contact, %{birthdate: ~D[1990-06-15]})

      assert :ok = import_reminders(import_job, contact, payload)

      assert [reminder] = contact_reminders(account_id, contact.id)
      assert reminder.id == generic.id
      assert reminder.type == "birthday"
      assert reminder.next_reminder_date == TimeHelper.next_birthday_date(~D[1990-06-15])

      assert Imports.find_import_record(account_id, "monica_api", "reminder", "9").local_entity_id ==
               reminder.id
    end
  end

  defp import_reminders(import_job, contact, reminders) do
    Req.Test.stub(@stub_name, fn conn ->
      case conn.request_path do
        "/api/contacts/7/reminders" -> Req.Test.json(conn, %{"data" => reminders})
        _ -> Req.Test.json(conn, %{"data" => []})
      end
    end)

    plan = [%{"source_id" => "7", "local_id" => contact.id, "endpoints" => ["reminders"]}]
    perform_job(MonicaMiscDataWorker, build_args(import_job, plan))
  end

  defp contact_reminders(account_id, contact_id) do
    Reminder
    |> where([r], r.account_id == ^account_id and r.contact_id == ^contact_id)
    |> Repo.all()
  end

  defp collect_requests(acc) do
    receive do
      {:request, path} -> collect_requests([path | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
