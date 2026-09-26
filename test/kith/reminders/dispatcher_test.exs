defmodule Kith.Reminders.DispatcherTest do
  use Kith.DataCase, async: false
  use Oban.Testing, repo: Kith.Repo

  import Ecto.Query
  import Kith.AccountsFixtures
  import Kith.ContactsFixtures

  alias Kith.Reminders
  alias Kith.Reminders.{Dispatcher, Reminder, ReminderInstance}
  alias Kith.Workers.ReminderEmailWorker

  setup do
    user = user_fixture()
    Reminders.seed_default_rules(user.account_id)
    contact = contact_fixture(user.account_id)
    today = Date.utc_today()

    %{
      user: user,
      account_id: user.account_id,
      contact: contact,
      today: today,
      # Accounts default to Etc/UTC with send_hour 9.
      after_send: DateTime.new!(today, ~T[10:00:00], "Etc/UTC"),
      before_send: DateTime.new!(today, ~T[08:00:00], "Etc/UTC")
    }
  end

  defp create!(ctx, attrs) do
    {:ok, r} =
      Reminders.create_reminder(
        ctx.account_id,
        ctx.user.id,
        Map.merge(%{title: "R", contact_id: ctx.contact.id}, attrs)
      )

    r
  end

  defp instances(reminder),
    do: Repo.all(from i in ReminderInstance, where: i.reminder_id == ^reminder.id, order_by: i.id)

  defp set_next!(reminder, date) do
    Repo.update_all(from(r in Reminder, where: r.id == ^reminder.id),
      set: [next_reminder_date: date]
    )
  end

  test "a recurring reminder due today is sent once and advances", ctx do
    r = create!(ctx, %{type: "recurring", frequency: "weekly", anchor_date: ctx.today})

    assert :ok = Dispatcher.run(ctx.after_send)

    assert [%{kind: "on_day", days_before: 0, status: "pending"} = i] = instances(r)
    assert i.occurrence_date == ctx.today
    assert_enqueued(worker: ReminderEmailWorker, args: %{instance_id: i.id})
    assert Repo.get!(Reminder, r.id).next_reminder_date == Date.add(ctx.today, 7)

    assert :ok = Dispatcher.run(DateTime.add(ctx.after_send, 3600))
    assert length(instances(r)) == 1
  end

  test "nothing is sent before the account's send hour", ctx do
    r = create!(ctx, %{type: "recurring", frequency: "weekly", anchor_date: ctx.today})

    assert :ok = Dispatcher.run(ctx.before_send)

    assert instances(r) == []
    refute_enqueued(worker: ReminderEmailWorker)
  end

  test "missed periods send one notice and jump to the next future occurrence", ctx do
    r =
      create!(ctx, %{
        type: "recurring",
        frequency: "weekly",
        anchor_date: Date.add(ctx.today, -21)
      })

    set_next!(r, Date.add(ctx.today, -21))

    assert :ok = Dispatcher.run(ctx.after_send)

    assert [_one] = instances(r)
    assert Repo.get!(Reminder, r.id).next_reminder_date == Date.add(ctx.today, 7)
  end

  test "a one-time reminder in the past is sent once and never again", ctx do
    r = create!(ctx, %{type: "one_time", anchor_date: Date.add(ctx.today, -10)})

    assert :ok = Dispatcher.run(ctx.after_send)
    assert :ok = Dispatcher.run(DateTime.add(ctx.after_send, 86_400))

    assert [%{kind: "on_day"}] = instances(r)
    assert Repo.get!(Reminder, r.id).next_reminder_date == Date.add(ctx.today, -10)
  end

  test "only the nearest advance-notice window sends (5 days out → the 7-day notice)", ctx do
    r = create!(ctx, %{type: "one_time", anchor_date: Date.add(ctx.today, 5)})

    assert :ok = Dispatcher.run(ctx.after_send)

    assert [%{kind: "advance", days_before: 7}] = instances(r)
  end

  test "20 days out sends the 30-day notice", ctx do
    r = create!(ctx, %{type: "one_time", anchor_date: Date.add(ctx.today, 20)})

    assert :ok = Dispatcher.run(ctx.after_send)

    assert [%{kind: "advance", days_before: 30}] = instances(r)
  end

  test "recurring reminders get no advance notices", ctx do
    r =
      create!(ctx, %{type: "recurring", frequency: "monthly", anchor_date: Date.add(ctx.today, 5)})

    assert :ok = Dispatcher.run(ctx.after_send)

    assert instances(r) == []
  end

  test "a deactivated rule sends no advance notice", ctx do
    seven = Enum.find(Reminders.list_reminder_rules(ctx.account_id), &(&1.days_before == 7))
    {:ok, _} = Reminders.update_reminder_rule(seven, %{active: false})
    r = create!(ctx, %{type: "one_time", anchor_date: Date.add(ctx.today, 5)})

    assert :ok = Dispatcher.run(ctx.after_send)

    assert instances(r) == []
  end

  test "stay-in-touch waits while an instance is pending, and dismiss re-arms it", ctx do
    r = create!(ctx, %{type: "stay_in_touch", frequency: "monthly", anchor_date: ctx.today})

    assert :ok = Dispatcher.run(ctx.after_send)
    assert [pending] = instances(r)
    assert Repo.get!(Reminder, r.id).next_reminder_date == ctx.today

    assert :ok = Dispatcher.run(DateTime.add(ctx.after_send, 86_400))
    assert length(instances(r)) == 1

    {:ok, _} = Reminders.dismiss_instance(pending)
    assert Repo.get!(Reminder, r.id).next_reminder_date == Date.shift(ctx.today, month: 1)
  end

  test "a deceased contact's birthday is dismissed, not emailed, and advanced", ctx do
    {:ok, contact} = Kith.Contacts.update_contact(ctx.contact, %{deceased: true})

    r =
      create!(%{ctx | contact: contact}, %{
        type: "birthday",
        title: nil,
        frequency: "annually",
        anchor_date: ctx.today
      })

    assert :ok = Dispatcher.run(ctx.after_send)

    assert [%{status: "dismissed"}] = instances(r)
    refute_enqueued(worker: ReminderEmailWorker)
    assert Repo.get!(Reminder, r.id).next_reminder_date == Date.shift(ctx.today, year: 1)
  end

  test "soft-deleted and archived contacts are skipped", ctx do
    archived = contact_fixture(ctx.account_id)
    {:ok, archived} = Kith.Contacts.archive_contact(archived)
    deleted = contact_fixture(ctx.account_id)
    {:ok, deleted} = Kith.Contacts.soft_delete_contact(deleted)

    a = create!(%{ctx | contact: archived}, %{type: "one_time", anchor_date: ctx.today})
    d = create!(%{ctx | contact: deleted}, %{type: "one_time", anchor_date: ctx.today})

    assert :ok = Dispatcher.run(ctx.after_send)

    assert instances(a) == []
    assert instances(d) == []
  end

  test "an ended snooze sends again and returns to pending", ctx do
    r = create!(ctx, %{type: "one_time", anchor_date: ctx.today})
    assert :ok = Dispatcher.run(ctx.after_send)
    [i] = instances(r)

    Repo.update_all(from(x in ReminderInstance, where: x.id == ^i.id),
      set: [status: "snoozed", snoozed_until: DateTime.add(ctx.after_send, 60)]
    )

    Repo.delete_all(Oban.Job)
    assert :ok = Dispatcher.run(DateTime.add(ctx.after_send, 120))

    assert %{status: "pending", snoozed_until: nil} = Repo.get!(ReminderInstance, i.id)
    assert_enqueued(worker: ReminderEmailWorker, args: %{instance_id: i.id})
  end

  test "uses the account's local date in a timezone ahead of UTC", ctx do
    Repo.update_all(from(a in Kith.Accounts.Account, where: a.id == ^ctx.account_id),
      set: [timezone: "Pacific/Kiritimati"]
    )

    tomorrow = Date.add(ctx.today, 1)
    r = create!(ctx, %{type: "one_time", anchor_date: tomorrow})

    # 20:00 UTC today is 10:00 tomorrow in Kiritimati (UTC+14): due there.
    assert :ok = Dispatcher.run(DateTime.new!(ctx.today, ~T[20:00:00], "Etc/UTC"))

    assert [%{occurrence_date: ^tomorrow, kind: "on_day"}] = instances(r)
  end

  test "editing a reminder after today's notice does not send it again", ctx do
    r = create!(ctx, %{type: "one_time", anchor_date: ctx.today})
    assert :ok = Dispatcher.run(ctx.after_send)

    {:ok, _} = Reminders.update_reminder(Repo.get!(Reminder, r.id), %{title: "Renamed"})
    assert :ok = Dispatcher.run(DateTime.add(ctx.after_send, 3600))

    assert length(instances(r)) == 1
  end

  describe "advance_days_before/3" do
    test "picks the rule whose window contains today" do
      next = ~D[2026-10-31]
      assert Dispatcher.advance_days_before(next, ~D[2026-10-26], [30, 7]) == 7
      assert Dispatcher.advance_days_before(next, ~D[2026-10-24], [30, 7]) == 7
      assert Dispatcher.advance_days_before(next, ~D[2026-10-23], [30, 7]) == 30
      assert Dispatcher.advance_days_before(next, ~D[2026-10-01], [30, 7]) == 30
      assert Dispatcher.advance_days_before(next, ~D[2026-09-30], [30, 7]) == nil
      assert Dispatcher.advance_days_before(next, ~D[2026-10-31], [30, 7]) == nil
      assert Dispatcher.advance_days_before(next, ~D[2026-10-26], []) == nil
    end
  end
end
