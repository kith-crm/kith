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

    Kith.TestEnv.put_env_restoring(
      :kith,
      :monica_req_options,
      plug: {Req.Test, @stub_name},
      retry: false
    )

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

  describe "perform/1 — extra notes" do
    defp notes_plan(contact, embedded) do
      [
        %{
          "source_id" => "42",
          "local_id" => contact.id,
          "embedded_notes" => embedded,
          "endpoints" => ["notes"]
        }
      ]
    end

    defp note_body(i), do: %{"uuid" => "n#{i}", "body" => "Note #{i}"}

    test "imports notes past the embedded ones, across pages, without duplicates",
         %{user: user, account_id: account_id} do
      contact = contact_fixture(account_id)
      import_job = api_import(account_id, user.id)

      Imports.record_imported_entity(import_job, "contact", "42", "contact", contact.id)
      {:ok, _} = Kith.Contacts.create_note(contact, user.id, %{"body" => "Note 1"})

      Req.Test.stub(@stub_name, fn conn ->
        case conn.query_params["page"] do
          "1" ->
            Req.Test.json(conn, %{
              "data" => Enum.map(1..3, &note_body/1),
              "meta" => %{"last_page" => 2}
            })

          "2" ->
            Req.Test.json(conn, %{
              "data" => Enum.map(4..5, &note_body/1),
              "meta" => %{"last_page" => 2}
            })
        end
      end)

      assert :ok =
               perform_job(MonicaMiscDataWorker, build_args(import_job, notes_plan(contact, 1)))

      bodies =
        Repo.all(
          from(n in Kith.Contacts.Note, where: n.contact_id == ^contact.id, select: n.body)
        )

      # Note 1 was embedded (skipped); Notes 2–5 are new.
      assert Enum.sort(bodies) == ["Note 1", "Note 2", "Note 3", "Note 4", "Note 5"]

      assert Imports.get_import!(import_job.id).summary["misc"]["notes"] == 4

      # A retry creates nothing new.
      assert :ok =
               perform_job(MonicaMiscDataWorker, build_args(import_job, notes_plan(contact, 1)))

      assert Repo.aggregate(
               from(n in Kith.Contacts.Note, where: n.contact_id == ^contact.id),
               :count
             ) == 5
    end

    test "attaches notes to the surviving contact when the planned one was merged away",
         %{user: user, account_id: account_id} do
      loser = contact_fixture(account_id)
      survivor = contact_fixture(account_id)
      import_job = api_import(account_id, user.id)

      Imports.record_imported_entity(import_job, "contact", "42", "contact", survivor.id)

      loser
      |> Ecto.Changeset.change(deleted_at: DateTime.utc_now() |> DateTime.truncate(:second))
      |> Repo.update!()

      Req.Test.stub(@stub_name, fn conn ->
        Req.Test.json(conn, %{"data" => [note_body(1)], "meta" => %{"last_page" => 1}})
      end)

      assert :ok = perform_job(MonicaMiscDataWorker, build_args(import_job, notes_plan(loser, 0)))

      assert Repo.aggregate(
               from(n in Kith.Contacts.Note, where: n.contact_id == ^survivor.id),
               :count
             ) == 1
    end
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

      assert %{"reminders" => 1, "reminders_skipped" => 0, "reminders_warnings" => 1} =
               misc_summary(ctx.import_job)
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

    test "a retry of the same import updates the mapped reminder instead of duplicating it",
         ctx do
      contact = contact_fixture(ctx.account_id)

      payload = [
        monica(3, %{
          "title" => "Wedding anniversary",
          "frequency_type" => "year",
          "initial_date" => "2015-03-09T00:00:00Z"
        })
      ]

      import_reminders(ctx.import_job, contact, payload)
      [first] = contact_reminders(ctx.account_id, contact.id)

      import_reminders(ctx.import_job, contact, payload)
      assert [again] = contact_reminders(ctx.account_id, contact.id)
      assert again.id == first.id
    end

    test "a first-met opt-in is visible to later reminders of the same contact", ctx do
      contact = contact_fixture(ctx.account_id, %{first_met_at: ~D[2012-09-01]})

      import_reminders(ctx.import_job, contact, [
        monica(12, %{"frequency_type" => "year", "initial_date" => "2012-09-01T00:00:00Z"}),
        monica(13, %{
          "frequency_type" => "week",
          "frequency_number" => 2,
          "initial_date" => "2026-01-05T00:00:00Z"
        })
      ])

      assert Enum.sort(Enum.map(contact_reminders(ctx.account_id, contact.id), & &1.type)) ==
               ["first_met", "recurring"]
    end

    test "a missing frequency_number imports one-time and counts as a warning", ctx do
      contact = contact_fixture(ctx.account_id)

      capture_log(fn ->
        import_reminders(ctx.import_job, contact, [
          monica(31, %{
            "frequency_type" => "month",
            "frequency_number" => nil,
            "initial_date" => "2099-01-01T00:00:00Z"
          })
        ])
      end)

      assert [%{type: "one_time"}] = contact_reminders(ctx.account_id, contact.id)
      assert %{"reminders" => 1, "reminders_warnings" => 1} = misc_summary(ctx.import_job)
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

      assert %{"reminders" => 0, "reminders_skipped" => 1, "reminders_warnings" => 0} =
               misc_summary(ctx.import_job)
    end

    test "an unparseable date is counted as skipped in the import summary", ctx do
      contact = contact_fixture(ctx.account_id)

      capture_log(fn ->
        import_reminders(ctx.import_job, contact, [
          monica(98, %{"frequency_type" => "year", "initial_date" => "not-a-date"}),
          monica(97, %{"frequency_type" => "fortnight", "initial_date" => "2026-01-01T00:00:00Z"})
        ])
      end)

      assert %{"reminders" => 0, "reminders_skipped" => 2} = misc_summary(ctx.import_job)
    end
  end

  describe "conversations" do
    test "a retry of the same import does not duplicate conversations or messages",
         %{user: user, account_id: account_id} do
      contact = contact_fixture(account_id)
      import_job = api_import(account_id, user.id)

      Req.Test.stub(@stub_name, fn conn ->
        case conn.request_path do
          "/api/contacts/1/conversations" ->
            Req.Test.json(conn, %{
              "data" => [
                %{
                  "id" => 10,
                  "contact_field_type" => %{"name" => "Email"},
                  "messages" => [
                    %{"id" => 100, "content" => "hi", "written_at" => "2025-01-01T10:00:00Z"},
                    %{
                      "id" => 101,
                      "content" => "yo",
                      "written_by_me" => true,
                      "written_at" => "2025-01-01T11:00:00Z"
                    }
                  ]
                }
              ]
            })

          _ ->
            Req.Test.json(conn, %{"data" => []})
        end
      end)

      plan = [%{"source_id" => "1", "local_id" => contact.id, "endpoints" => ["conversations"]}]

      for _ <- 1..2,
          do: assert(:ok = perform_job(MonicaMiscDataWorker, build_args(import_job, plan)))

      assert Repo.aggregate(Kith.Conversations.Conversation, :count) == 1
      assert Repo.aggregate(Kith.Conversations.Message, :count) == 2
    end
  end

  describe "retry idempotence" do
    @retry_cases [
      {"calls", Kith.Activities.Call,
       %{"id" => 20, "called_at" => "2025-01-01T10:00:00Z", "content" => "hello", "duration" => 5}},
      {"activities", Kith.Activities.Activity,
       %{"id" => 21, "summary" => "Lunch", "happened_at" => "2025-01-01T10:00:00Z"}},
      {"gifts", Kith.Contacts.Gift, %{"id" => 22, "name" => "Book", "is_for" => "contact"}},
      {"debts", Kith.Contacts.Debt,
       %{"id" => 23, "reason" => "Dinner", "amount" => "10", "in_debt" => "yes"}},
      {"tasks", Kith.Tasks.Task, %{"id" => 24, "title" => "Call back", "completed" => false}}
    ]

    for {endpoint, schema, item} <- @retry_cases do
      test "a retry of the same import does not duplicate #{endpoint}",
           %{user: user, account_id: account_id} do
        contact = contact_fixture(account_id)
        import_job = api_import(account_id, user.id)
        endpoint = unquote(endpoint)

        Req.Test.stub(@stub_name, fn conn ->
          if conn.request_path == "/api/contacts/1/#{endpoint}",
            do: Req.Test.json(conn, %{"data" => [unquote(Macro.escape(item))]}),
            else: Req.Test.json(conn, %{"data" => []})
        end)

        plan = [%{"source_id" => "1", "local_id" => contact.id, "endpoints" => [endpoint]}]

        for _ <- 1..2,
            do: assert(:ok = perform_job(MonicaMiscDataWorker, build_args(import_job, plan)))

        assert Repo.aggregate(unquote(schema), :count) == 1
      end
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

  defp misc_summary(import_job),
    do: Repo.get!(Kith.Imports.Import, import_job.id).summary["misc"]

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
