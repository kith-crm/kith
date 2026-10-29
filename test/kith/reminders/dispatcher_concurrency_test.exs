defmodule Kith.Reminders.DispatcherConcurrencyTest do
  # These tests commit fixtures so independently checked-out connections can
  # race. They must run after sandboxed async tests, and clean up their rows.
  use ExUnit.Case, async: false

  import Ecto.Query
  import ExUnit.CaptureLog
  import Kith.AccountsFixtures
  import Kith.ContactsFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Kith.Reminders.{Dispatcher, ReminderInstance}
  alias Kith.{Reminders, Repo}

  setup do
    fixture =
      unboxed(fn ->
        user = user_fixture()
        contact = contact_fixture(user.account_id)
        today = Date.utc_today()

        {:ok, reminder} =
          Reminders.create_reminder(user.account_id, user.id, %{
            type: "recurring",
            interval_unit: "week",
            interval_count: 1,
            title: "Call",
            anchor_date: today,
            contact_id: contact.id
          })

        %{
          user: user,
          contact: contact,
          reminder: reminder,
          now: DateTime.new!(today, ~T[10:00:00], "Etc/UTC"),
          today: today
        }
      end)

    handler = {__MODULE__, make_ref()}
    :ok = :telemetry.attach(handler, [:kith, :repo, :query], &__MODULE__.barrier/4, nil)

    on_exit(fn ->
      :telemetry.detach(handler)

      unboxed(fn ->
        # Oban args have no foreign key; remove only this fixture's jobs.
        ids =
          Repo.all(
            from(i in ReminderInstance,
              where: i.account_id == ^fixture.user.account_id,
              select: i.id
            )
          )

        Repo.delete_all(
          from(j in Oban.Job, where: fragment("(?->>'instance_id')::bigint", j.args) in ^ids)
        )

        Repo.delete_all(from(a in Kith.Accounts.Account, where: a.id == ^fixture.user.account_id))
      end)
    end)

    fixture
  end

  # Ecto emits this after the SELECT has returned but before the dispatcher
  # consumes its result. Both workers therefore hold the same stale selection.
  # The gate is test-process-local; unrelated queries are never intercepted.
  def barrier(_event, _measurements, %{query: query}, _config) do
    case Process.get(:dispatcher_test_gate) do
      {owner, phase} ->
        selected? =
          String.starts_with?(query, "SELECT") and
            case phase do
              :due ->
                String.contains?(query, ~s(FROM "reminders" AS r0 INNER JOIN "contacts"))

              :wake ->
                String.contains?(
                  query,
                  ~s(FROM "reminder_instances" AS r0 INNER JOIN "reminders")
                )
            end

        if selected? do
          Process.delete(:dispatcher_test_gate)
          send(owner, {:selected, self()})

          receive do
            :continue_dispatch -> :ok
          after
            5_000 -> raise "dispatcher test gate was not released"
          end
        end

      nil ->
        :ok
    end
  end

  test "overlapping dispatches use separate transactions but enqueue one notice", ctx do
    overlap(ctx.now, :due)

    unboxed(fn ->
      assert [%{occurrence_date: date, snooze_count: 0} = instance] = instances(ctx.reminder)
      assert date == ctx.today

      assert jobs(instance) |> Enum.map(& &1.args) == [
               %{"instance_id" => instance.id, "snooze_count" => 0}
             ]

      assert Repo.reload!(ctx.reminder).next_reminder_date == Date.add(ctx.today, 7)
    end)
  end

  test "overlapping wake-ups enqueue only the current snooze generation", ctx do
    instance = snooze_due(ctx)
    overlap(ctx.now, :wake)

    unboxed(fn ->
      assert %{status: "pending", snoozed_until: nil, snooze_count: 2} = Repo.reload!(instance)

      assert jobs(instance) |> Enum.map(& &1.args) == [
               %{"instance_id" => instance.id, "snooze_count" => 2}
             ]
    end)
  end

  for block <- [:archived, :inactive, :deleted] do
    test "a contact/reminder made #{block} after selection stays snoozed", ctx do
      instance = snooze_due(ctx)
      task = gated_dispatch(ctx.now, :wake)
      assert_receive {:selected, pid}, 5_000

      unboxed(fn ->
        case unquote(block) do
          :archived -> Kith.Contacts.archive_contact(ctx.contact)
          :deleted -> Kith.Contacts.soft_delete_contact(ctx.contact)
          :inactive -> Reminders.update_reminder(ctx.reminder, %{active: false})
        end
      end)

      send(pid, :continue_dispatch)
      assert :ok = Task.await(task, 5_000)

      unboxed(fn ->
        assert %{status: "snoozed", snooze_count: 2} = Repo.reload!(instance)
        assert jobs(instance) == []
      end)
    end
  end

  test "a failed enqueue rolls back its ledger and advance while other reminders proceed", ctx do
    unboxed(fn ->
      {:ok, healthy} =
        Reminders.create_reminder(ctx.user.account_id, ctx.user.id, %{
          type: "one_time",
          title: "Healthy",
          anchor_date: ctx.today,
          contact_id: ctx.contact.id
        })

      # Fail the actual INSERT after the ledger and schedule update, rather
      # than mocking the transaction or calling Repo.rollback from the test.
      Repo.query!("""
      CREATE FUNCTION qa_reject_reminder_email() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF NEW.worker = 'Kith.Workers.ReminderEmailWorker' AND EXISTS (
          SELECT 1 FROM reminder_instances WHERE id = (NEW.args->>'instance_id')::bigint
          AND reminder_id = #{ctx.reminder.id}
        ) THEN NEW.max_attempts := 0; END IF;
        RETURN NEW;
      END $$
      """)

      Repo.query!(
        "CREATE TRIGGER qa_reject_reminder_email BEFORE INSERT ON oban_jobs FOR EACH ROW EXECUTE FUNCTION qa_reject_reminder_email()"
      )

      try do
        capture_log(fn -> assert :ok = Dispatcher.run(ctx.now) end)
        assert instances(ctx.reminder) == []
        assert Repo.reload!(ctx.reminder).next_reminder_date == ctx.today
        assert [instance] = instances(healthy)
        assert [_job] = jobs(instance)
      after
        Repo.query!("DROP TRIGGER qa_reject_reminder_email ON oban_jobs")
        Repo.query!("DROP FUNCTION qa_reject_reminder_email()")
      end
    end)
  end

  defp overlap(now, phase) do
    tasks = for _ <- 1..2, do: gated_dispatch(now, phase)

    pids =
      for _ <- 1..2 do
        assert_receive {:selected, pid}, 5_000
        pid
      end

    # Both SELECTs finished before either transaction mutates the selected row.
    Enum.each(pids, &send(&1, :continue_dispatch))
    Enum.each(tasks, fn task -> assert :ok = Task.await(task, 5_000) end)

    backend_pids =
      for _ <- 1..2 do
        assert_receive {:backend, backend_pid}, 5_000
        backend_pid
      end

    assert length(Enum.uniq(backend_pids)) == 2
  end

  defp gated_dispatch(now, phase) do
    owner = self()

    Task.async(fn ->
      unboxed(fn ->
        %{rows: [[backend_pid]]} = Repo.query!("SELECT pg_backend_pid()")
        send(owner, {:backend, backend_pid})
        Process.put(:dispatcher_test_gate, {owner, phase})
        Dispatcher.run(now)
      end)
    end)
  end

  defp snooze_due(ctx) do
    unboxed(fn ->
      :ok = Dispatcher.run(ctx.now)
      [instance] = instances(ctx.reminder)

      Repo.delete_all(
        from(j in Oban.Job,
          where: fragment("?->>'instance_id'", j.args) == ^to_string(instance.id)
        )
      )

      instance
      |> Ecto.Changeset.change(
        status: "snoozed",
        snoozed_until: DateTime.add(ctx.now, -1),
        snooze_count: 2
      )
      |> Repo.update!()
    end)
  end

  defp instances(reminder),
    do: Repo.all(from(i in ReminderInstance, where: i.reminder_id == ^reminder.id))

  defp jobs(instance),
    do:
      Repo.all(
        from(j in Oban.Job,
          where:
            j.worker == "Kith.Workers.ReminderEmailWorker" and
              fragment("?->>'instance_id'", j.args) == ^to_string(instance.id)
        )
      )

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)
end
