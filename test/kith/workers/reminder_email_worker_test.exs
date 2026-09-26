defmodule Kith.Workers.ReminderEmailWorkerTest do
  use Kith.DataCase, async: false
  use Oban.Testing, repo: Kith.Repo

  import Ecto.Query
  import Swoosh.TestAssertions
  import Kith.AccountsFixtures
  import Kith.ContactsFixtures

  alias Kith.Reminders
  alias Kith.Reminders.{Dispatcher, ReminderInstance}
  alias Kith.Workers.ReminderEmailWorker

  setup do
    user = user_fixture()
    contact = contact_fixture(user.account_id, %{first_name: "Mona", display_name: "Mona Vale"})

    {:ok, reminder} =
      Reminders.create_reminder(user.account_id, user.id, %{
        type: "one_time",
        title: "Call Mona",
        anchor_date: Date.utc_today(),
        contact_id: contact.id
      })

    :ok = Dispatcher.run(DateTime.new!(Date.utc_today(), ~T[10:00:00], "Etc/UTC"))
    [instance] = Repo.all(from i in ReminderInstance, where: i.reminder_id == ^reminder.id)

    %{user: user, instance: instance}
  end

  test "emails the reminder's creator", %{user: user, instance: instance} do
    assert :ok = perform_job(ReminderEmailWorker, %{instance_id: instance.id})

    assert_email_sent(fn email ->
      assert email.to == [{user.email, user.email}]
      assert email.subject == "Reminder: Call Mona"
    end)
  end

  test "a retried job never creates another instance", %{instance: instance} do
    assert :ok = perform_job(ReminderEmailWorker, %{instance_id: instance.id})
    assert :ok = perform_job(ReminderEmailWorker, %{instance_id: instance.id}, attempt: 2)

    assert Repo.aggregate(
             from(i in ReminderInstance, where: i.reminder_id == ^instance.reminder_id),
             :count
           ) ==
             1
  end

  test "discards a job whose instance is gone", %{instance: instance} do
    Repo.delete!(instance)
    assert {:discard, _} = perform_job(ReminderEmailWorker, %{instance_id: instance.id})
  end
end
