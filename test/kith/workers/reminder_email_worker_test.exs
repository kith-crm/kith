defmodule Kith.Workers.ReminderEmailWorkerTest do
  use Kith.DataCase, async: false
  use Oban.Testing, repo: Kith.Repo

  import Ecto.Query
  import Swoosh.TestAssertions
  import Kith.AccountsFixtures
  import Kith.ContactsFixtures

  alias Kith.Reminders
  alias Kith.Reminders.{Dispatcher, Reminder, ReminderInstance}
  alias Kith.Workers.ReminderEmailWorker

  defmodule FailingAdapter do
    @moduledoc false
    use Swoosh.Adapter

    @impl Swoosh.Adapter
    def deliver(_email, _config), do: {:error, :boom}
  end

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

    %{user: user, contact: contact, instance: instance}
  end

  defp fail_mail(_ctx) do
    original = Application.get_env(:kith, Kith.Mailer)
    Application.put_env(:kith, Kith.Mailer, Keyword.put(original, :adapter, FailingAdapter))
    on_exit(fn -> Application.put_env(:kith, Kith.Mailer, original) end)
    :ok
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

  describe "when delivery fails on the final attempt" do
    setup :fail_mail

    test "the instance is marked failed", %{instance: instance} do
      assert {:error, :boom} =
               perform_job(ReminderEmailWorker, %{instance_id: instance.id}, attempt: 3)

      assert Repo.get!(ReminderInstance, instance.id).status == "failed"
    end

    test "an earlier attempt leaves the instance pending", %{instance: instance} do
      assert {:error, :boom} =
               perform_job(ReminderEmailWorker, %{instance_id: instance.id}, attempt: 1)

      assert Repo.get!(ReminderInstance, instance.id).status == "pending"
    end

    test "a stay-in-touch reminder is re-armed one interval from today", ctx do
      today = Date.utc_today()

      {:ok, reminder} =
        Reminders.create_reminder(ctx.user.account_id, ctx.user.id, %{
          type: "stay_in_touch",
          frequency: "monthly",
          anchor_date: today,
          contact_id: ctx.contact.id
        })

      :ok = Dispatcher.run(DateTime.new!(today, ~T[11:00:00], "Etc/UTC"))
      [instance] = Repo.all(from i in ReminderInstance, where: i.reminder_id == ^reminder.id)

      assert {:error, :boom} =
               perform_job(ReminderEmailWorker, %{instance_id: instance.id}, attempt: 3)

      assert Repo.get!(ReminderInstance, instance.id).status == "failed"
      assert Repo.get!(Reminder, reminder.id).next_reminder_date == Date.shift(today, month: 1)
    end
  end
end
