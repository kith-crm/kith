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

  describe "API key" do
    test "authenticates with the key from the Import row, not job args",
         %{user: user, account_id: account_id} do
      contact = contact_fixture(account_id)
      import_job = api_import(account_id, user.id)
      pid = self()

      Req.Test.stub(@stub_name, fn conn ->
        send(pid, {:auth, Plug.Conn.get_req_header(conn, "authorization")})
        Req.Test.json(conn, %{"data" => []})
      end)

      plan = [%{"source_id" => "1", "local_id" => contact.id, "endpoints" => ["calls"]}]
      args = build_args(import_job, plan)
      refute Map.has_key?(args, "credential_api_key")

      assert :ok = perform_job(MonicaMiscDataWorker, args)
      assert_received {:auth, ["Bearer test-key"]}
    end

    test "cancels without calling Monica when the key has been wiped",
         %{user: user, account_id: account_id} do
      contact = contact_fixture(account_id)
      import_job = api_import(account_id, user.id)
      {:ok, _} = Imports.wipe_api_key(import_job)
      pid = self()

      Req.Test.stub(@stub_name, fn conn ->
        send(pid, {:request, conn.request_path})
        Req.Test.json(conn, %{"data" => []})
      end)

      plan = [%{"source_id" => "1", "local_id" => contact.id, "endpoints" => ["calls"]}]

      assert {:cancel, :api_key_wiped} =
               perform_job(MonicaMiscDataWorker, build_args(import_job, plan))

      refute_received {:request, _}
    end
  end

  describe "reminders import (Monica 4.1.2)" do
    setup %{user: user, account_id: account_id} do
      %{
        import_job: api_import(account_id, user.id),
        today: Kith.Reminders.account_today(account_id)
      }
    end

    test "a titled Monica birthday reminder maps onto the derived birthday reminder", ctx do
      contact = contact_fixture(ctx.account_id, %{birthdate: ~D[1990-06-15]})

      assert :ok =
               import_reminders(ctx.import_job, contact, [
                 monica(1, %{
                   "title" => "Wish happy birthday to Mona",
                   "frequency_type" => "year",
                   "initial_date" => "1990-06-15T00:00:00Z",
                   "delible" => false
                 })
               ])

      assert [%{type: "birthday"} = r] = contact_reminders(ctx.account_id, contact.id)

      assert Imports.find_import_record(ctx.account_id, "monica_api", "reminder", "1").local_entity_id ==
               r.id
    end

    test "an API-edited birthday reminder (delible: true, custom title) still maps", ctx do
      contact = contact_fixture(ctx.account_id, %{birthdate: ~D[1990-06-15]})

      import_reminders(ctx.import_job, contact, [
        monica(1, %{
          "title" => "Wish happy birthday to Mona!",
          "frequency_type" => "year",
          "initial_date" => "1990-06-15T00:00:00Z"
        })
      ])

      assert [%{type: "birthday"}] = contact_reminders(ctx.account_id, contact.id)
    end

    test "a first-met anniversary opts the contact in and maps onto first_met", ctx do
      contact = contact_fixture(ctx.account_id, %{first_met_at: ~D[2012-09-01]})

      import_reminders(ctx.import_job, contact, [
        monica(12, %{
          "title" => "Anniversary of the day you first met",
          "frequency_type" => "year",
          "initial_date" => "2012-09-01T00:00:00Z",
          "delible" => false
        })
      ])

      assert Repo.get!(Kith.Contacts.Contact, contact.id).first_met_reminder

      assert [%{type: "first_met", anchor_date: ~D[2012-09-01]} = r] =
               contact_reminders(ctx.account_id, contact.id)

      assert Imports.find_import_record(ctx.account_id, "monica_api", "reminder", "12").local_entity_id ==
               r.id
    end

    test "a recurring reminder keeps Monica's anchor and interval", ctx do
      contact = contact_fixture(ctx.account_id)

      import_reminders(ctx.import_job, contact, [
        monica(4, %{
          "frequency_type" => "week",
          "frequency_number" => 2,
          "initial_date" => "2026-01-05T00:00:00Z"
        })
      ])

      assert [r] = contact_reminders(ctx.account_id, contact.id)

      assert %{
               type: "recurring",
               interval_unit: "week",
               interval_count: 2,
               anchor_date: ~D[2026-01-05],
               active: true
             } = r

      assert r.next_reminder_date ==
               Kith.Reminders.Occurrences.next_on_or_after(Reminder.schedule(r), ctx.today)
    end

    test "a past one-time reminder is imported inactive with its own date", ctx do
      contact = contact_fixture(ctx.account_id)

      import_reminders(ctx.import_job, contact, [
        monica(6, %{"frequency_type" => "one_time", "initial_date" => "2020-01-01T00:00:00Z"})
      ])

      assert [%{type: "one_time", anchor_date: ~D[2020-01-01], active: false}] =
               contact_reminders(ctx.account_id, contact.id)
    end

    test "frequency_number 0 imports as one-time and logs a warning", ctx do
      contact = contact_fixture(ctx.account_id)
      future = ctx.today |> Date.add(60) |> Date.to_iso8601()

      log =
        capture_log(fn ->
          import_reminders(ctx.import_job, contact, [
            monica(21, %{
              "frequency_type" => "month",
              "frequency_number" => 0,
              "initial_date" => "#{future}T00:00:00Z"
            })
          ])
        end)

      assert log =~ "non_positive_interval"
      assert [%{type: "one_time", active: true}] = contact_reminders(ctx.account_id, contact.id)
    end

    test "the description is imported", ctx do
      contact = contact_fixture(ctx.account_id)

      import_reminders(ctx.import_job, contact, [
        monica(20, %{
          "frequency_type" => "one_time",
          "initial_date" => "2099-02-14T00:00:00Z",
          "description" => "Has a description"
        })
      ])

      assert [%{description: "Has a description"}] = contact_reminders(ctx.account_id, contact.id)
    end

    test "re-importing updates the mapped reminder in place", ctx do
      contact = contact_fixture(ctx.account_id)

      payload = fn title ->
        [
          monica(3, %{
            "title" => title,
            "frequency_type" => "year",
            "initial_date" => "2015-03-09T00:00:00Z"
          })
        ]
      end

      import_reminders(ctx.import_job, contact, payload.("Wedding"))
      [first] = contact_reminders(ctx.account_id, contact.id)

      import_reminders(ctx.import_job, contact, payload.("Wedding anniversary"))
      assert [again] = contact_reminders(ctx.account_id, contact.id)
      assert again.id == first.id
      assert again.title == "Wedding anniversary"
    end

    test "a changed frequency type replaces the row and re-points the mapping", ctx do
      contact = contact_fixture(ctx.account_id)

      import_reminders(ctx.import_job, contact, [
        monica(5, %{"frequency_type" => "one_time", "initial_date" => "2099-01-01T00:00:00Z"})
      ])

      [old] = contact_reminders(ctx.account_id, contact.id)

      import_reminders(ctx.import_job, contact, [
        monica(5, %{"frequency_type" => "month", "initial_date" => "2099-01-01T00:00:00Z"})
      ])

      assert [%{type: "recurring"} = new] = contact_reminders(ctx.account_id, contact.id)
      refute new.id == old.id

      assert Imports.find_import_record(ctx.account_id, "monica_api", "reminder", "5").local_entity_id ==
               new.id
    end

    test "re-importing after the user deleted the mapped reminder recreates it", ctx do
      contact = contact_fixture(ctx.account_id)

      payload = [
        monica(7, %{"frequency_type" => "one_time", "initial_date" => "2099-01-10T00:00:00Z"})
      ]

      import_reminders(ctx.import_job, contact, payload)
      [r] = contact_reminders(ctx.account_id, contact.id)
      {:ok, _} = Kith.Reminders.delete_reminder(r)

      assert :ok = import_reminders(ctx.import_job, contact, payload)
      assert [new] = contact_reminders(ctx.account_id, contact.id)

      assert Imports.find_import_record(ctx.account_id, "monica_api", "reminder", "7").local_entity_id ==
               new.id
    end

    test "an unknown frequency type is skipped with a warning", ctx do
      contact = contact_fixture(ctx.account_id)

      log =
        capture_log(fn ->
          import_reminders(ctx.import_job, contact, [
            monica(99, %{
              "frequency_type" => "fortnight",
              "initial_date" => "2026-01-01T00:00:00Z"
            })
          ])
        end)

      assert log =~ "unknown_frequency"
      assert contact_reminders(ctx.account_id, contact.id) == []
    end

    test "a generic row from an earlier import is replaced once the contact has a birthdate",
         ctx do
      contact = contact_fixture(ctx.account_id)

      payload = [
        monica(9, %{
          "title" => "Wish happy birthday to Mona",
          "frequency_type" => "year",
          "initial_date" => "1990-06-15T00:00:00Z"
        })
      ]

      import_reminders(ctx.import_job, contact, payload)
      assert [%{type: "recurring"} = generic] = contact_reminders(ctx.account_id, contact.id)

      {:ok, contact} = Kith.Contacts.update_contact(contact, %{birthdate: ~D[1990-06-15]})
      import_reminders(ctx.import_job, contact, payload)

      assert [%{type: "birthday"} = r] = contact_reminders(ctx.account_id, contact.id)
      refute r.id == generic.id

      assert Imports.find_import_record(ctx.account_id, "monica_api", "reminder", "9").local_entity_id ==
               r.id
    end
  end

  defp monica(id, attrs) do
    Map.merge(
      %{
        "id" => id,
        "title" => "R#{id}",
        "description" => nil,
        "frequency_number" => 1,
        "delible" => true
      },
      attrs
    )
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
