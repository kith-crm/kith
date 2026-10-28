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

  describe "perform/1 — progress logging" do
    setup do
      previous = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: previous) end)
    end

    defp two_contact_plan(account_id) do
      for source_id <- ["42", "43"] do
        contact = contact_fixture(account_id)
        %{"source_id" => source_id, "local_id" => contact.id, "endpoints" => ["reminders"]}
      end
    end

    test "logs a start line, progress, and a completion line with durations and counts",
         %{user: user, account_id: account_id} do
      import_job = api_import(account_id, user.id)
      plan = two_contact_plan(account_id)

      Req.Test.stub(@stub_name, fn conn ->
        Req.Test.json(conn, %{"data" => [], "meta" => %{"last_page" => 1}})
      end)

      log =
        capture_log([level: :info], fn ->
          assert :ok = perform_job(MonicaMiscDataWorker, build_args(import_job, plan))
        end)

      assert log =~ "[MonicaMiscData] import #{import_job.id}: starting"
      assert log =~ "2 contacts"
      assert log =~ "up to 2 requests"
      assert log =~ "attempt 1/"
      assert log =~ "[MonicaMiscData] import #{import_job.id}: progress 2/2 contacts (100%)"
      assert log =~ "2 requests"
      assert log =~ "[MonicaMiscData] import #{import_job.id}: complete in"
    end

    test "debug level logs each request before and after the call, and each contact's cost",
         %{user: user, account_id: account_id} do
      import_job = api_import(account_id, user.id)
      plan = two_contact_plan(account_id)
      Logger.configure(level: :debug)

      Req.Test.stub(@stub_name, fn conn ->
        Req.Test.json(conn, %{"data" => [], "meta" => %{"last_page" => 1}})
      end)

      log =
        capture_log([level: :debug], fn ->
          assert :ok = perform_job(MonicaMiscDataWorker, build_args(import_job, plan))
        end)

      # A hung call shows as a "->" with no "<-" after it.
      assert log =~ "-> GET /api/contacts/42/reminders (request #1)"
      assert log =~ ~r{<- /api/contacts/42/reminders HTTP 200 in \d+ms}
      assert log =~ "-> GET /api/contacts/43/reminders (request #2)"
      assert log =~ ~r{contact 1/2 \(monica 42\) \["reminders"\] took \d+ms, 1 requests}
      assert log =~ ~r{contact 2/2 \(monica 43\) \["reminders"\] took \d+ms, 1 requests}
    end

    test "warns when a retry attempt starts, since the previous attempt died silently",
         %{user: user, account_id: account_id} do
      import_job = api_import(account_id, user.id)

      Req.Test.stub(@stub_name, fn conn ->
        Req.Test.json(conn, %{"data" => [], "meta" => %{"last_page" => 1}})
      end)

      log =
        capture_log([level: :info], fn ->
          assert :ok =
                   perform_job(MonicaMiscDataWorker, build_args(import_job, []), attempt: 2)
        end)

      assert log =~ "retrying after an earlier attempt (attempt 2/"
    end

    test "estimate_plan/2 projects the run time from the request budget" do
      plan = [
        %{"endpoints" => ["reminders", "notes"]},
        %{"endpoints" => ["reminders"]},
        %{"endpoints" => nil}
      ]

      assert %{requests: 3, minutes: minutes} = MonicaMiscDataWorker.estimate_plan(plan, 6)
      assert_in_delta minutes, 0.5, 1.0e-9
    end

    test "warns before processing when projected work exceeds the run budget",
         %{user: user, account_id: account_id} do
      import_job = api_import(account_id, user.id)
      contact = contact_fixture(account_id)

      # A zero budget creates a deterministic boundary. Rate-limit timing is
      # covered separately; this test only needs the warning and one request.
      plan =
        for source <- ["42", "43"],
            do: %{"source_id" => source, "local_id" => contact.id, "endpoints" => ["pets"]}

      Kith.TestEnv.put_env_restoring(:kith, :monica_rate_limit, 60_000)
      Kith.TestEnv.put_env_restoring(:kith, :monica_misc_budget_ms, 0)

      Req.Test.expect(@stub_name, fn conn ->
        assert conn.request_path == "/api/contacts/42/pets"
        Req.Test.json(conn, %{"data" => []})
      end)

      log =
        capture_log([level: :info], fn ->
          assert :ok = perform_job(MonicaMiscDataWorker, build_args(import_job, plan))
        end)

      assert log =~ "exceeds the 0ms time budget"
      assert log =~ "follow-up jobs"
      Req.Test.verify!(@stub_name)
    end
  end

  describe "perform/1 — time budget" do
    setup do
      previous = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: previous) end)
    end

    defp pet_plan(account_id, n) do
      for i <- 1..n do
        contact = contact_fixture(account_id)

        %{
          "source_id" => "#{100 + i}",
          "local_id" => contact.id,
          "endpoints" => ["pets"]
        }
      end
    end

    defp stub_one_pet do
      Req.Test.stub(@stub_name, fn conn ->
        Req.Test.json(conn, %{"data" => [%{"id" => 1, "name" => "Rex", "pet_category" => "dog"}]})
      end)
    end

    test "stops at the budget and hands the remaining plan to a follow-up job",
         %{user: user, account_id: account_id} do
      import_job = api_import(account_id, user.id)
      [_first | rest] = plan = pet_plan(account_id, 3)
      stub_one_pet()

      # A zero budget still completes one entry per run, so every run makes progress.
      Kith.TestEnv.put_env_restoring(:kith, :monica_misc_budget_ms, 0)

      log =
        capture_log([level: :info], fn ->
          assert :ok = perform_job(MonicaMiscDataWorker, build_args(import_job, plan))
        end)

      assert log =~ "time budget reached"
      assert log =~ "2 contacts left"

      assert_enqueued(
        worker: MonicaMiscDataWorker,
        args: %{
          "import_id" => import_job.id,
          "plan" => rest,
          "carried" => %{"pets" => 1}
        }
      )

      # The import's misc summary is not final until the last slice, but the slice's
      # work is already visible.
      assert Imports.get_import!(import_job.id).summary["misc"]["pets"] == 1
    end

    test "the last slice adds its counts to those carried from earlier slices",
         %{user: user, account_id: account_id} do
      import_job = api_import(account_id, user.id)
      plan = pet_plan(account_id, 2)
      stub_one_pet()

      args = import_job |> build_args(plan) |> Map.put("carried", %{"pets" => 5, "notes" => 2})

      assert :ok = perform_job(MonicaMiscDataWorker, args)
      refute_enqueued(worker: MonicaMiscDataWorker)

      assert %{"pets" => 7, "notes" => 2} = Imports.get_import!(import_job.id).summary["misc"]
    end

    test "a plan that fits the budget finishes in one run with no follow-up",
         %{user: user, account_id: account_id} do
      import_job = api_import(account_id, user.id)
      plan = pet_plan(account_id, 3)
      stub_one_pet()

      assert :ok = perform_job(MonicaMiscDataWorker, build_args(import_job, plan))
      refute_enqueued(worker: MonicaMiscDataWorker)
      assert Imports.get_import!(import_job.id).summary["misc"]["pets"] == 3
    end
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

    # Monica embeds the 3 *newest* notes in the contact payload but lists /notes
    # oldest first, so "skip the first N of /notes" skips the wrong notes.
    test "imports the oldest notes when the embedded ones are the newest",
         %{user: user, account_id: account_id} do
      contact = contact_fixture(account_id)
      import_job = api_import(account_id, user.id)
      Imports.record_imported_entity(import_job, "contact", "42", "contact", contact.id)

      # The crawl imported the newest three (n3..n5) and recorded their uuids.
      for i <- 3..5 do
        {:ok, note} = Kith.Contacts.create_note(contact, user.id, %{"body" => "Note #{i}"})
        Imports.record_imported_entity(import_job, "note", "n#{i}", "note", note.id)
      end

      Req.Test.stub(@stub_name, fn conn ->
        Req.Test.json(conn, %{
          "data" => Enum.map(1..5, &note_body/1),
          "meta" => %{"last_page" => 1}
        })
      end)

      assert :ok =
               perform_job(MonicaMiscDataWorker, build_args(import_job, notes_plan(contact, 3)))

      bodies =
        Repo.all(
          from(n in Kith.Contacts.Note, where: n.contact_id == ^contact.id, select: n.body)
        )

      assert Enum.sort(bodies) == ["Note 1", "Note 2", "Note 3", "Note 4", "Note 5"]
      assert Imports.get_import!(import_job.id).summary["misc"]["notes"] == 2
    end

    test "a blank-bodied embedded note is matched by uuid and not imported twice",
         %{user: user, account_id: account_id} do
      contact = contact_fixture(account_id)
      import_job = api_import(account_id, user.id)
      Imports.record_imported_entity(import_job, "contact", "42", "contact", contact.id)

      # Blank bodies can't be matched by content, only by the recorded uuid.
      {:ok, blank} = Kith.Contacts.create_note(contact, user.id, %{"body" => "x"})
      Imports.record_imported_entity(import_job, "note", "blank-1", "note", blank.id)

      Req.Test.stub(@stub_name, fn conn ->
        Req.Test.json(conn, %{
          "data" => [%{"uuid" => "blank-1", "body" => ""}],
          "meta" => %{"last_page" => 1}
        })
      end)

      assert :ok =
               perform_job(MonicaMiscDataWorker, build_args(import_job, notes_plan(contact, 1)))

      assert Repo.aggregate(
               from(n in Kith.Contacts.Note, where: n.contact_id == ^contact.id),
               :count
             ) == 1
    end

    test "a stale note mapping does not prevent restoring a missing note",
         %{user: user, account_id: account_id} do
      contact = contact_fixture(account_id)
      import_job = api_import(account_id, user.id)
      Imports.record_imported_entity(import_job, "contact", "42", "contact", contact.id)
      {:ok, note} = Kith.Contacts.create_note(contact, user.id, %{body: "Note 1"})
      Imports.record_imported_entity(import_job, "note", "n1", "note", note.id)
      Repo.delete!(note)

      Req.Test.stub(@stub_name, fn conn ->
        Req.Test.json(conn, %{"data" => [note_body(1)], "meta" => %{"last_page" => 1}})
      end)

      assert :ok =
               perform_job(MonicaMiscDataWorker, build_args(import_job, notes_plan(contact, 0)))

      restored = Repo.one!(from(n in Kith.Contacts.Note, where: n.contact_id == ^contact.id))
      assert restored.body == "Note 1"
      refute restored.id == note.id

      assert Imports.find_import_record(account_id, "monica_api", "note", "n1").local_entity_id ==
               restored.id
    end

    test "purging and reimporting a contact restores all ten notes", %{
      user: user,
      account_id: account_id
    } do
      notes = Enum.map(1..10, &note_body/1)

      api_contact =
        Kith.MonicaApiFixtures.contact_json(
          id: 42,
          first_name: "Mona",
          number_of_notes: 10,
          notes: Enum.take(notes, -3)
        )

      Req.Test.stub(@stub_name, fn conn ->
        case conn.request_path do
          "/api/contacts" ->
            Req.Test.json(conn, Kith.MonicaApiFixtures.contacts_page_json([api_contact]))

          "/api/contacts/42/notes" ->
            Req.Test.json(conn, %{"data" => notes, "meta" => %{"last_page" => 1}})
        end
      end)

      credential = %{
        url: "https://monica.test",
        api_key: "test-key",
        req_options: [plug: {Req.Test, @stub_name}, retry: false]
      }

      imported_ids =
        for _ <- 1..2 do
          job = api_import(account_id, user.id)

          opts =
            Map.new(
              ~w(pets calls activities gifts debts tasks reminders conversations),
              &{&1, false}
            )

          assert {:ok, summary} =
                   Kith.Imports.Sources.MonicaApi.crawl(
                     account_id,
                     user.id,
                     credential,
                     job,
                     opts
                   )

          {:ok, job} = Imports.update_import_status(job, "completed")
          [entry] = summary.misc_data_plan

          assert :ok =
                   perform_job(
                     MonicaMiscDataWorker,
                     build_args(job, [
                       Map.new(entry, fn {k, v} -> {to_string(k), v} end)
                     ])
                   )

          contact = Kith.Contacts.get_contact!(account_id, entry.local_id)

          assert Repo.aggregate(
                   from(n in Kith.Contacts.Note, where: n.contact_id == ^contact.id),
                   :count
                 ) == 10

          {:ok, _} = Kith.Contacts.hard_delete_contact(contact)
          contact.id
        end

      assert length(Enum.uniq(imported_ids)) == 2
    end

    test "extra notes keep Monica created_at", %{user: user, account_id: account_id} do
      contact = contact_fixture(account_id)
      import_job = api_import(account_id, user.id)
      Imports.record_imported_entity(import_job, "contact", "42", "contact", contact.id)

      Req.Test.stub(@stub_name, fn conn ->
        Req.Test.json(conn, %{
          "data" => [
            %{"uuid" => "n1", "body" => "Dated", "created_at" => "2018-07-07T07:07:07Z"}
          ],
          "meta" => %{"last_page" => 1}
        })
      end)

      assert :ok =
               perform_job(MonicaMiscDataWorker, build_args(import_job, notes_plan(contact, 0)))

      note = Repo.one!(from(n in Kith.Contacts.Note, where: n.contact_id == ^contact.id))
      assert note.inserted_at == ~U[2018-07-07 07:07:07Z]
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
      assert updated.summary["misc"]["calls"] == 2

      assert Repo.all(
               from(c in Kith.Activities.Call,
                 where: c.account_id == ^account_id and c.contact_id == ^contact.id,
                 order_by: c.occurred_at,
                 select: c.occurred_at
               )
             ) == [~U[2025-01-01 10:00:00Z], ~U[2025-01-02 10:00:00Z]]
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

  # Auto-merge folds duplicate contacts into a survivor and remaps their import
  # records onto it. Their data must follow, not be dropped, without duplicating
  # what the survivor already has.
  describe "merged-away contacts" do
    setup %{user: user, account_id: account_id} do
      import_job = api_import(account_id, user.id)
      survivor = contact_fixture(account_id)
      loser = contact_fixture(account_id)

      Imports.record_imported_entity(import_job, "contact", "7", "contact", survivor.id)

      loser
      |> Ecto.Changeset.change(deleted_at: DateTime.utc_now() |> DateTime.truncate(:second))
      |> Repo.update!()

      %{import_job: import_job, survivor: survivor, loser: loser, user: user}
    end

    defp run_for(ctx, endpoint, items) do
      Req.Test.stub(@stub_name, fn conn ->
        if conn.request_path == "/api/contacts/7/#{endpoint}",
          do: Req.Test.json(conn, %{"data" => items}),
          else: Req.Test.json(conn, %{"data" => []})
      end)

      plan = [%{"source_id" => "7", "local_id" => ctx.loser.id, "endpoints" => [endpoint]}]
      assert :ok = perform_job(MonicaMiscDataWorker, build_args(ctx.import_job, plan))
    end

    defp recurring_monica(id, title),
      do:
        monica(id, %{
          "title" => title,
          "frequency_type" => "week",
          "frequency_number" => 2,
          "initial_date" => "2026-01-05T00:00:00Z"
        })

    test "reminders are imported onto the survivor", ctx do
      run_for(ctx, "reminders", [recurring_monica(1, "Call mum")])

      assert [%{title: "Call mum", type: "recurring"}] =
               contact_reminders(ctx.account_id, ctx.survivor.id)

      assert contact_reminders(ctx.account_id, ctx.loser.id) == []
      assert %{"reminders" => 1} = misc_summary(ctx.import_job)
    end

    test "a reminder the survivor already has is not duplicated, only the new one is added",
         ctx do
      {:ok, existing} =
        Kith.Reminders.create_reminder(ctx.account_id, ctx.user.id, %{
          type: "recurring",
          title: "  call MUM ",
          anchor_date: ~D[2026-01-05],
          interval_unit: "week",
          interval_count: 2,
          contact_id: ctx.survivor.id
        })

      run_for(ctx, "reminders", [
        recurring_monica(1, "Call mum"),
        recurring_monica(2, "Pay rent")
      ])

      titles = ctx.account_id |> contact_reminders(ctx.survivor.id) |> Enum.map(& &1.title)
      assert Enum.sort(titles) == ["  call MUM ", "Pay rent"]

      assert %{"reminders" => 1, "reminders_duplicate" => 1} = misc_summary(ctx.import_job)

      # The duplicate is mapped to the existing reminder, so a retry stays stable.
      assert %{local_entity_id: id} =
               Imports.find_import_record(ctx.account_id, "monica_api", "reminder", "1")

      assert id == existing.id
    end

    test "the same reminder on two merged duplicates is imported once", ctx do
      run_for(ctx, "reminders", [recurring_monica(1, "Call mum")])

      # The second duplicate carries an identical reminder under its own Monica id.
      second = contact_fixture(ctx.account_id)
      Imports.record_imported_entity(ctx.import_job, "contact", "8", "contact", ctx.survivor.id)

      Req.Test.stub(@stub_name, fn conn ->
        if conn.request_path == "/api/contacts/8/reminders",
          do: Req.Test.json(conn, %{"data" => [recurring_monica(99, "Call mum")]}),
          else: Req.Test.json(conn, %{"data" => []})
      end)

      second
      |> Ecto.Changeset.change(deleted_at: DateTime.utc_now() |> DateTime.truncate(:second))
      |> Repo.update!()

      plan = [%{"source_id" => "8", "local_id" => second.id, "endpoints" => ["reminders"]}]
      assert :ok = perform_job(MonicaMiscDataWorker, build_args(ctx.import_job, plan))

      assert [_one] = contact_reminders(ctx.account_id, ctx.survivor.id)
    end

    test "pets, gifts and calls also land on the survivor", ctx do
      run_for(ctx, "pets", [%{"id" => 5, "name" => "Rex", "pet_category" => "dog"}])
      run_for(ctx, "gifts", [%{"id" => 22, "name" => "Book", "is_for" => "contact"}])

      run_for(ctx, "calls", [
        %{
          "id" => 20,
          "called_at" => "2025-01-01T10:00:00Z",
          "content" => "hello",
          "duration" => 5
        }
      ])

      assert Repo.aggregate(
               from(p in Kith.Contacts.Pet, where: p.contact_id == ^ctx.survivor.id),
               :count
             ) ==
               1

      assert Repo.aggregate(
               from(g in Kith.Contacts.Gift, where: g.contact_id == ^ctx.survivor.id),
               :count
             ) ==
               1

      assert Repo.aggregate(
               from(c in Kith.Activities.Call, where: c.contact_id == ^ctx.survivor.id),
               :count
             ) ==
               1
    end

    test "a gift or call the survivor already has is not duplicated", ctx do
      {:ok, _} =
        Kith.Gifts.create_gift(ctx.account_id, ctx.user.id, %{
          "contact_id" => ctx.survivor.id,
          "name" => "Book",
          "direction" => "given",
          "status" => "idea"
        })

      {:ok, _} =
        Kith.Activities.create_call(
          %{account_id: ctx.account_id, id: ctx.survivor.id},
          %{
            "occurred_at" => ~U[2025-01-01 10:00:00Z],
            "notes" => "hello",
            "duration_mins" => 5
          }
        )

      run_for(ctx, "gifts", [%{"id" => 22, "name" => "Book", "is_for" => "contact"}])

      run_for(ctx, "calls", [
        %{
          "id" => 20,
          "called_at" => "2025-01-01T10:00:00Z",
          "content" => "hello",
          "duration" => 5
        }
      ])

      assert Repo.aggregate(
               from(g in Kith.Contacts.Gift, where: g.contact_id == ^ctx.survivor.id),
               :count
             ) ==
               1

      assert Repo.aggregate(
               from(c in Kith.Activities.Call, where: c.contact_id == ^ctx.survivor.id),
               :count
             ) ==
               1
    end

    test "a merged-away contact with no import record is skipped for non-note endpoints", ctx do
      orphan = contact_fixture(ctx.account_id)

      orphan
      |> Ecto.Changeset.change(deleted_at: DateTime.utc_now() |> DateTime.truncate(:second))
      |> Repo.update!()

      Req.Test.stub(@stub_name, fn conn ->
        Req.Test.json(conn, %{"data" => [recurring_monica(1, "Call mum")]})
      end)

      plan = [%{"source_id" => "999", "local_id" => orphan.id, "endpoints" => ["reminders"]}]
      assert :ok = perform_job(MonicaMiscDataWorker, build_args(ctx.import_job, plan))

      assert contact_reminders(ctx.account_id, orphan.id) == []
      assert contact_reminders(ctx.account_id, ctx.survivor.id) == []
    end
  end

  describe "conversations" do
    test "opposite-direction messages with identical text and time both survive retries", %{
      user: user,
      account_id: account_id
    } do
      contact = contact_fixture(account_id)
      import_job = api_import(account_id, user.id)

      messages =
        for {id, sent?} <- [{100, true}, {101, false}, {102, true}] do
          %{
            "id" => id,
            "content" => "OK",
            "written_by_me" => sent?,
            "written_at" => "2025-01-01T10:30:15Z"
          }
        end

      Req.Test.stub(@stub_name, fn conn ->
        Req.Test.json(conn, %{"data" => [%{"id" => 10, "messages" => messages}]})
      end)

      plan = [%{"source_id" => "1", "local_id" => contact.id, "endpoints" => ["conversations"]}]

      for _ <- 1..2,
          do: assert(:ok = perform_job(MonicaMiscDataWorker, build_args(import_job, plan)))

      assert Repo.all(
               from(m in Kith.Conversations.Message,
                 where: m.account_id == ^account_id,
                 select: m.direction,
                 order_by: m.direction
               )
             ) == ["received", "sent"]

      assert Repo.aggregate(Kith.Conversations.Conversation, :count) == 1
    end

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

        assert :ok = perform_job(MonicaMiscDataWorker, build_args(import_job, plan))
        [before] = Repo.all(unquote(schema))
        assert before.account_id == account_id
        assert_owned_by_contact(before, contact.id)
        assert_imported_fields(before, endpoint)

        type =
          if endpoint == "activities", do: "activity", else: String.trim_trailing(endpoint, "s")

        mapping =
          Imports.find_import_record(
            account_id,
            "monica_api",
            type,
            to_string(unquote(Macro.escape(item))["id"])
          )

        assert mapping.local_entity_id == before.id

        assert :ok = perform_job(MonicaMiscDataWorker, build_args(import_job, plan))

        assert Repo.all(unquote(schema)) == [before]

        assert Imports.find_import_record(
                 account_id,
                 "monica_api",
                 type,
                 mapping.source_entity_id
               ) == mapping
      end
    end
  end

  describe "completion and recovery contracts" do
    test "real continuation jobs finish every contact before releasing credentials", ctx do
      import_job = api_import(ctx.account_id, ctx.user.id)

      plan =
        for source <- ["101", "102", "103"] do
          contact = contact_fixture(ctx.account_id)
          %{"source_id" => source, "local_id" => contact.id, "endpoints" => ["calls"]}
        end

      Req.Test.stub(@stub_name, fn conn ->
        source = conn.request_path |> String.split("/") |> Enum.at(3)

        Req.Test.json(conn, %{
          "data" => [
            %{
              "id" => source,
              "called_at" => "2025-01-01T10:00:00Z",
              "content" => "Call #{source}"
            }
          ]
        })
      end)

      Kith.TestEnv.put_env_restoring(:kith, :monica_misc_budget_ms, 0)
      Phoenix.PubSub.subscribe(Kith.PubSub, "import:#{ctx.account_id}")

      assert :ok = perform_job(MonicaMiscDataWorker, build_args(import_job, plan))
      refute_received {:import_misc_complete, _}
      [continuation] = all_enqueued(worker: MonicaMiscDataWorker)
      assert continuation.args["plan"] == Enum.drop(plan, 1)
      assert continuation.args["carried"]["calls"] == 1

      assert {:snooze, 60} =
               perform_job(Kith.Workers.MonicaApiKeyReleaseWorker, %{import_id: import_job.id})

      assert Imports.get_import!(import_job.id).api_key_encrypted == "test-key"

      assert %{success: 2, failure: 0} = Oban.drain_queue(queue: :imports, with_recursion: true)
      assert_received {:import_misc_complete, %{"calls" => 3}}
      refute_received {:import_misc_complete, _}
      refute_enqueued(worker: MonicaMiscDataWorker)
      assert misc_summary(import_job)["calls"] == 3

      assert Repo.all(
               from(c in Kith.Activities.Call, order_by: c.notes, select: {c.contact_id, c.notes})
             ) ==
               Enum.map(plan, &{&1["local_id"], "Call #{&1["source_id"]}"})

      assert :ok =
               perform_job(Kith.Workers.MonicaApiKeyReleaseWorker, %{import_id: import_job.id})

      assert Imports.get_import!(import_job.id).api_key_encrypted == nil
    end

    test "cancellation before a continuation prevents its requests and preserves cancelled status",
         ctx do
      import_job = api_import(ctx.account_id, ctx.user.id)

      plan =
        for source <- ["1", "2"] do
          contact = contact_fixture(ctx.account_id)
          %{"source_id" => source, "local_id" => contact.id, "endpoints" => ["calls"]}
        end

      Kith.TestEnv.put_env_restoring(:kith, :monica_misc_budget_ms, 0)
      pid = self()

      Req.Test.stub(@stub_name, fn conn ->
        send(pid, {:requested, conn.request_path})
        Req.Test.json(conn, %{"data" => []})
      end)

      Phoenix.PubSub.subscribe(Kith.PubSub, "import:#{ctx.account_id}")
      assert :ok = perform_job(MonicaMiscDataWorker, build_args(import_job, plan))
      assert_received {:requested, "/api/contacts/1/calls"}
      {:ok, _} = Imports.update_import_status(Imports.get_import!(import_job.id), "cancelled")
      assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :imports, with_recursion: true)
      refute_received {:requested, _}
      refute_received {:import_misc_complete, _}
      assert Imports.get_import!(import_job.id).status == "cancelled"
    end

    test "cancellation during a request cannot be overwritten or start a later endpoint", ctx do
      import_job = api_import(ctx.account_id, ctx.user.id)
      contact = contact_fixture(ctx.account_id)
      plan = [%{"source_id" => "1", "local_id" => contact.id, "endpoints" => ["calls", "tasks"]}]
      pid = self()
      # The HTTP boundary is deterministic: cancellation commits after the job's
      # initial eligibility check and before its first response is returned.
      Req.Test.stub(@stub_name, fn conn ->
        send(pid, {:requested, conn.request_path})
        {:ok, _} = Imports.update_import_status(Imports.get_import!(import_job.id), "cancelled")

        Req.Test.json(conn, %{
          "data" => [
            %{"id" => 90, "called_at" => "2025-01-01T10:00:00Z", "content" => "Must not persist"}
          ]
        })
      end)

      Phoenix.PubSub.subscribe(Kith.PubSub, "import:#{ctx.account_id}")
      assert :ok = perform_job(MonicaMiscDataWorker, build_args(import_job, plan))
      assert_received {:requested, "/api/contacts/1/calls"}
      refute_received {:requested, _}
      refute_received {:import_misc_complete, _}
      refute_enqueued(worker: MonicaMiscDataWorker)
      assert Imports.get_import!(import_job.id).status == "cancelled"
      assert Repo.all(Kith.Activities.Call) == []
      assert Imports.find_import_record(ctx.account_id, "monica_api", "call", "90") == nil
    end

    test "a contact deleted while its request is in flight receives no response rows", ctx do
      import_job = api_import(ctx.account_id, ctx.user.id)
      contact = contact_fixture(ctx.account_id)
      Imports.record_imported_entity(import_job, "contact", "1", "contact", contact.id)

      Req.Test.stub(@stub_name, fn conn ->
        {:ok, _} = Kith.Contacts.soft_delete_contact(contact)

        Req.Test.json(conn, %{
          "data" => [
            %{"id" => 90, "called_at" => "2025-01-01T10:00:00Z", "content" => "Deleted target"}
          ]
        })
      end)

      plan = [%{"source_id" => "1", "local_id" => contact.id, "endpoints" => ["calls"]}]
      assert :ok = perform_job(MonicaMiscDataWorker, build_args(import_job, plan))
      assert Repo.all(Kith.Activities.Call) == []
      assert Imports.find_import_record(ctx.account_id, "monica_api", "call", "90") == nil
      assert misc_summary(import_job)["calls"] == 0
    end

    test "a contact merged while its request is in flight imports onto the current survivor",
         ctx do
      import_job = api_import(ctx.account_id, ctx.user.id)
      contact = contact_fixture(ctx.account_id)
      survivor = contact_fixture(ctx.account_id)
      Imports.record_imported_entity(import_job, "contact", "1", "contact", contact.id)

      Req.Test.stub(@stub_name, fn conn ->
        {:ok, _} = Kith.Contacts.merge_contacts(survivor.id, contact.id)

        Req.Test.json(conn, %{
          "data" => [
            %{"id" => 90, "called_at" => "2025-01-01T10:00:00Z", "content" => "Current survivor"}
          ]
        })
      end)

      plan = [%{"source_id" => "1", "local_id" => contact.id, "endpoints" => ["calls"]}]
      assert :ok = perform_job(MonicaMiscDataWorker, build_args(import_job, plan))

      assert [%{contact_id: target, account_id: account, notes: "Current survivor"}] =
               Repo.all(Kith.Activities.Call)

      assert target == survivor.id
      assert account == ctx.account_id

      assert Imports.find_import_record(ctx.account_id, "monica_api", "contact", "1").local_entity_id ==
               survivor.id

      assert misc_summary(import_job)["calls"] == 1
    end

    for response <- [:rate_limited, :server_error, :transport_error, :malformed] do
      test "#{response} fails the job without announcing successful completion", ctx do
        import_job = api_import(ctx.account_id, ctx.user.id)
        contact = contact_fixture(ctx.account_id)
        response = unquote(response)

        Req.Test.stub(@stub_name, &failed_response(&1, response))

        Phoenix.PubSub.subscribe(Kith.PubSub, "import:#{ctx.account_id}")
        plan = [%{"source_id" => "1", "local_id" => contact.id, "endpoints" => ["calls"]}]
        assert {:error, _} = perform_job(MonicaMiscDataWorker, build_args(import_job, plan))
        refute_received {:import_misc_complete, _}
        assert Imports.get_import!(import_job.id).summary["misc"] == nil
        assert Repo.all(Kith.Activities.Call) == []
      end
    end

    test "a later endpoint failure retries already persisted calls without losing or duplicating them",
         ctx do
      import_job = api_import(ctx.account_id, ctx.user.id)
      contact = contact_fixture(ctx.account_id)
      plan = [%{"source_id" => "1", "local_id" => contact.id, "endpoints" => ["calls", "tasks"]}]

      Req.Test.stub(@stub_name, fn conn ->
        if String.ends_with?(conn.request_path, "/calls") do
          Req.Test.json(conn, %{
            "data" => [
              %{
                "id" => 20,
                "called_at" => "2025-01-01T10:00:00Z",
                "content" => "hello",
                "duration" => 5
              }
            ]
          })
        else
          Plug.Conn.send_resp(conn, 503, "unavailable")
        end
      end)

      assert {:error, _} = perform_job(MonicaMiscDataWorker, build_args(import_job, plan))
      [call] = Repo.all(Kith.Activities.Call)
      assert call.notes == "hello"
      assert call.contact_id == contact.id
      assert call.account_id == ctx.account_id

      Req.Test.stub(@stub_name, fn conn ->
        if String.ends_with?(conn.request_path, "/calls") do
          Req.Test.json(conn, %{
            "data" => [
              %{
                "id" => 20,
                "called_at" => "2025-01-01T10:00:00Z",
                "content" => "hello",
                "duration" => 5
              }
            ]
          })
        else
          Req.Test.json(conn, %{
            "data" => [%{"id" => 21, "title" => "Call back", "completed" => false}]
          })
        end
      end)

      assert :ok = perform_job(MonicaMiscDataWorker, build_args(import_job, plan), attempt: 2)
      assert Repo.all(Kith.Activities.Call) == [call]
      assert [%{title: "Call back", contact_id: id}] = Repo.all(Kith.Tasks.Task)
      assert id == contact.id
      assert %{"calls" => 1, "tasks" => 1} = misc_summary(import_job)
    end

    test "a page import and its checkpoint roll back together if processing crashes", ctx do
      import_job = api_import(ctx.account_id, ctx.user.id)
      contact = contact_fixture(ctx.account_id)
      Imports.record_imported_entity(import_job, "contact", "1", "contact", contact.id)
      plan = [%{"source_id" => "1", "local_id" => contact.id, "endpoints" => ["notes"]}]

      Req.Test.stub(@stub_name, fn conn ->
        Req.Test.json(conn, %{
          "data" => [
            %{"uuid" => "n1", "body" => "First"},
            %{"uuid" => %{"invalid" => "identifier"}, "body" => "Second"}
          ],
          "meta" => %{"last_page" => 1}
        })
      end)

      assert_raise Protocol.UndefinedError, fn ->
        perform_job(MonicaMiscDataWorker, build_args(import_job, plan))
      end

      assert Repo.all(Kith.Contacts.Note) == []
      assert Imports.find_import_record(ctx.account_id, "monica_api", "note", "n1") == nil

      assert get_in(Imports.get_import!(import_job.id).summary || %{}, [
               "misc_progress",
               "1",
               "notes:1"
             ]) == nil

      Req.Test.stub(@stub_name, fn conn ->
        Req.Test.json(conn, %{
          "data" => [
            %{"uuid" => "n1", "body" => "First"},
            %{"uuid" => "n2", "body" => "Second"}
          ],
          "meta" => %{"last_page" => 1}
        })
      end)

      assert :ok = perform_job(MonicaMiscDataWorker, build_args(import_job, plan), attempt: 2)

      assert Repo.all(from(n in Kith.Contacts.Note, order_by: n.body, select: n.body)) == [
               "First",
               "Second"
             ]

      assert misc_summary(import_job)["notes"] == 2
    end

    test "a failed continuation insert does not publish partial summary and retries completed work safely",
         ctx do
      import_job = api_import(ctx.account_id, ctx.user.id)

      plan =
        for source <- ["1", "2"] do
          contact = contact_fixture(ctx.account_id)
          %{"source_id" => source, "local_id" => contact.id, "endpoints" => ["pets"]}
        end

      Req.Test.stub(@stub_name, fn conn ->
        source = conn.request_path |> String.split("/") |> Enum.at(3)

        Req.Test.json(conn, %{
          "data" => [%{"id" => source, "name" => "Pet #{source}", "pet_category" => "dog"}]
        })
      end)

      Kith.TestEnv.put_env_restoring(:kith, :monica_misc_budget_ms, 0)
      Phoenix.PubSub.subscribe(Kith.PubSub, "import:#{ctx.account_id}")
      # Failure occurs at the actual continuation insert, after this slice's
      # contact was committed. DDL is confined to this serialized sandbox test.
      Repo.query!(
        "ALTER TABLE oban_jobs ADD CONSTRAINT misc_continuation_failure CHECK (worker <> 'Kith.Workers.MonicaMiscDataWorker') NOT VALID"
      )

      assert_raise Ecto.ConstraintError, fn ->
        perform_job(MonicaMiscDataWorker, build_args(import_job, plan))
      end

      assert Imports.get_import!(import_job.id).summary["misc"] == nil
      refute_received {:import_misc_complete, _}
      [first_pet] = Repo.all(Kith.Contacts.Pet)
      assert first_pet.name == "Pet 1"
      Repo.query!("ALTER TABLE oban_jobs DROP CONSTRAINT misc_continuation_failure")

      assert :ok = perform_job(MonicaMiscDataWorker, build_args(import_job, plan), attempt: 2)
      assert Repo.all(Kith.Contacts.Pet) == [first_pet]
      [next_job] = all_enqueued(worker: MonicaMiscDataWorker)
      assert next_job.args["plan"] == Enum.drop(plan, 1)
      assert next_job.args["carried"]["pets"] == 1
      assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :imports, with_recursion: true)
      assert misc_summary(import_job)["pets"] == 2
      assert_received {:import_misc_complete, %{"pets" => 2}}
    end

    test "a failed later notes page does not report completion and a retry preserves all notes",
         ctx do
      import_job = api_import(ctx.account_id, ctx.user.id)
      contact = contact_fixture(ctx.account_id)
      Imports.record_imported_entity(import_job, "contact", "1", "contact", contact.id)
      plan = [%{"source_id" => "1", "local_id" => contact.id, "endpoints" => ["notes"]}]

      Req.Test.stub(@stub_name, fn conn ->
        if conn.query_params["page"] == "1" do
          Req.Test.json(conn, %{
            "data" => [%{"uuid" => "n1", "body" => "Oldest"}],
            "meta" => %{"last_page" => 2}
          })
        else
          Plug.Conn.send_resp(conn, 503, "unavailable")
        end
      end)

      Phoenix.PubSub.subscribe(Kith.PubSub, "import:#{ctx.account_id}")
      assert {:error, _} = perform_job(MonicaMiscDataWorker, build_args(import_job, plan))
      refute_received {:import_misc_complete, _}
      [oldest] = Repo.all(Kith.Contacts.Note)
      assert oldest.body == "Oldest"

      Req.Test.stub(@stub_name, fn conn ->
        {uuid, body} =
          if conn.query_params["page"] == "1", do: {"n1", "Oldest"}, else: {"n2", "Newest"}

        Req.Test.json(conn, %{
          "data" => [%{"uuid" => uuid, "body" => body}],
          "meta" => %{"last_page" => 2}
        })
      end)

      assert :ok = perform_job(MonicaMiscDataWorker, build_args(import_job, plan), attempt: 2)
      assert Repo.get!(Kith.Contacts.Note, oldest.id) == oldest

      assert Repo.all(
               from(n in Kith.Contacts.Note, order_by: n.body, select: {n.contact_id, n.body})
             ) == [{contact.id, "Newest"}, {contact.id, "Oldest"}]

      assert_received {:import_misc_complete, %{"notes" => 2}}
      assert misc_summary(import_job)["notes"] == 2
    end
  end

  describe "merged survivor deduplication boundaries" do
    test "equivalent debt, task, activity and pet data collapses while meaningful differences survive",
         ctx do
      import_job = api_import(ctx.account_id, ctx.user.id)
      survivor = contact_fixture(ctx.account_id)
      loser = contact_fixture(ctx.account_id)
      Imports.record_imported_entity(import_job, "contact", "1", "contact", survivor.id)
      Imports.record_imported_entity(import_job, "contact", "2", "contact", loser.id)
      assert {:ok, _} = Kith.Contacts.merge_contacts(survivor.id, loser.id)

      Req.Test.stub(@stub_name, fn conn ->
        data =
          case conn.request_path do
            "/api/contacts/1/debts" ->
              [%{"id" => 1, "reason" => "Dinner", "amount" => "10", "in_debt" => "yes"}]

            "/api/contacts/2/debts" ->
              [
                %{"id" => 2, "reason" => " dinner ", "amount" => "10.00", "in_debt" => "yes"},
                %{"id" => 3, "reason" => "Dinner", "amount" => "11", "in_debt" => "yes"},
                %{"id" => 4, "reason" => "Dinner", "amount" => "10", "in_debt" => "no"}
              ]

            "/api/contacts/1/tasks" ->
              [%{"id" => 11, "title" => "Call", "completed" => false}]

            "/api/contacts/2/tasks" ->
              [
                %{"id" => 12, "title" => " call ", "completed" => false},
                %{"id" => 13, "title" => "Call", "completed" => true}
              ]

            "/api/contacts/1/activities" ->
              [%{"id" => 21, "summary" => "Lunch", "happened_at" => "2025-01-01T10:00:00Z"}]

            "/api/contacts/2/activities" ->
              [
                %{"id" => 22, "summary" => " lunch ", "happened_at" => "2025-01-01T10:00:00Z"},
                %{"id" => 23, "summary" => "Lunch", "happened_at" => "2025-01-02T10:00:00Z"}
              ]

            "/api/contacts/1/pets" ->
              [%{"id" => 31, "name" => "Rex", "pet_category" => "dog"}]

            "/api/contacts/2/pets" ->
              [
                %{"id" => 32, "name" => " rex ", "pet_category" => "dog"},
                %{"id" => 33, "name" => "Rex", "pet_category" => "cat"}
              ]
          end

        Req.Test.json(conn, %{"data" => data})
      end)

      plan =
        for {source, id} <- [{"1", survivor.id}, {"2", loser.id}] do
          %{
            "source_id" => source,
            "local_id" => id,
            "endpoints" => ["debts", "tasks", "activities", "pets"]
          }
        end

      assert :ok = perform_job(MonicaMiscDataWorker, build_args(import_job, plan))

      assert Repo.all(
               from(d in Kith.Contacts.Debt,
                 order_by: [d.direction, d.amount],
                 select: {d.contact_id, d.title, d.direction, d.amount}
               )
             ) == [
               {survivor.id, "Dinner", "owed_by_me", Decimal.new("10.00")},
               {survivor.id, "Dinner", "owed_by_me", Decimal.new("11.00")},
               {survivor.id, "Dinner", "owed_to_me", Decimal.new("10.00")}
             ]

      assert Repo.all(
               from(t in Kith.Tasks.Task,
                 order_by: t.status,
                 select: {t.contact_id, t.title, t.status}
               )
             ) == [
               {survivor.id, "Call", "completed"},
               {survivor.id, "Call", "pending"}
             ]

      assert Repo.all(
               from(a in Kith.Activities.Activity,
                 join: ac in "activity_contacts",
                 on: ac.activity_id == a.id,
                 order_by: a.occurred_at,
                 select: {ac.contact_id, a.title, a.occurred_at}
               )
             ) == [
               {survivor.id, "Lunch", ~U[2025-01-01 10:00:00Z]},
               {survivor.id, "Lunch", ~U[2025-01-02 10:00:00Z]}
             ]

      assert Repo.all(
               from(p in Kith.Contacts.Pet,
                 order_by: p.species,
                 select: {p.contact_id, p.name, p.species}
               )
             ) == [
               {survivor.id, "Rex", "cat"},
               {survivor.id, "Rex", "dog"}
             ]

      snapshot = fn ->
        for schema <- [
              Kith.Contacts.Debt,
              Kith.Tasks.Task,
              Kith.Activities.Activity,
              Kith.Contacts.Pet
            ],
            do: Repo.all(from(row in schema, order_by: row.id))
      end

      before_retry = snapshot.()
      assert :ok = perform_job(MonicaMiscDataWorker, build_args(import_job, plan), attempt: 2)
      assert snapshot.() == before_retry
    end

    test "an invalid debt does not prevent a later valid record from importing", ctx do
      import_job = api_import(ctx.account_id, ctx.user.id)
      contact = contact_fixture(ctx.account_id)

      Req.Test.stub(@stub_name, fn conn ->
        Req.Test.json(conn, %{
          "data" => [
            %{"id" => 1, "reason" => "Invalid", "amount" => "-1", "in_debt" => "yes"},
            %{"id" => 2, "reason" => "Dinner", "amount" => "10", "in_debt" => "yes"}
          ]
        })
      end)

      plan = [%{"source_id" => "1", "local_id" => contact.id, "endpoints" => ["debts"]}]
      assert :ok = perform_job(MonicaMiscDataWorker, build_args(import_job, plan))
      assert [%{title: "Dinner", contact_id: id}] = Repo.all(Kith.Contacts.Debt)
      assert id == contact.id
      assert misc_summary(import_job)["debts"] == 1
      assert Imports.find_import_record(ctx.account_id, "monica_api", "debt", "1") == nil

      assert Imports.find_import_record(ctx.account_id, "monica_api", "debt", "2").local_entity_id ==
               Repo.one!(Kith.Contacts.Debt).id
    end
  end

  defp failed_response(conn, :rate_limited), do: Plug.Conn.send_resp(conn, 429, "busy")
  defp failed_response(conn, :server_error), do: Plug.Conn.send_resp(conn, 503, "unavailable")
  defp failed_response(conn, :transport_error), do: Req.Test.transport_error(conn, :timeout)
  defp failed_response(conn, :malformed), do: Req.Test.json(conn, %{"data" => "not a list"})

  defp assert_owned_by_contact(%Kith.Activities.Activity{id: id}, contact_id) do
    assert Repo.all(
             from(ac in "activity_contacts", where: ac.activity_id == ^id, select: ac.contact_id)
           ) == [contact_id]
  end

  defp assert_owned_by_contact(row, contact_id), do: assert(row.contact_id == contact_id)

  defp assert_imported_fields(row, "calls"),
    do:
      assert(
        Map.take(row, [:notes, :duration_mins, :occurred_at]) == %{
          notes: "hello",
          duration_mins: 5,
          occurred_at: ~U[2025-01-01 10:00:00Z]
        }
      )

  defp assert_imported_fields(row, "activities"),
    do:
      assert(
        Map.take(row, [:title, :occurred_at]) == %{
          title: "Lunch",
          occurred_at: ~U[2025-01-01 10:00:00Z]
        }
      )

  defp assert_imported_fields(row, "gifts"),
    do: assert(Map.take(row, [:name, :direction]) == %{name: "Book", direction: "given"})

  defp assert_imported_fields(row, "debts") do
    assert row.title == "Dinner"
    assert row.direction == "owed_by_me"
    assert Decimal.equal?(row.amount, Decimal.new("10"))
  end

  defp assert_imported_fields(row, "tasks"),
    do: assert(Map.take(row, [:title, :status]) == %{title: "Call back", status: "pending"})

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
