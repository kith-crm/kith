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
        anchor_date: Reminders.account_today(user.account_id),
        contact_id: contact.id
      })

    :ok = dispatch_today(user.account_id)
    [instance] = Repo.all(from(i in ReminderInstance, where: i.reminder_id == ^reminder.id))

    %{user: user, contact: contact, instance: instance}
  end

  # Runs the dispatcher at a late hour of the account-local "today", so the
  # run is never before send_hour and never straddles local midnight.
  defp dispatch_today(account_id) do
    account = Kith.Accounts.get_account!(account_id)
    today = Reminders.account_today(account_id)
    Dispatcher.run(DateTime.new!(today, ~T[23:00:00], account.timezone))
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

  describe "queued notices superseded by snoozing" do
    defp snooze_and_wake(instance) do
      {:ok, snoozed} = Reminders.snooze_instance(Repo.reload!(instance), "one_hour")
      :ok = Dispatcher.run(DateTime.add(snoozed.snoozed_until, 1, :second))
      Repo.reload!(snoozed)
    end

    defp assert_one_delivery do
      assert_email_sent(subject: "Reminder: Call Mona")
      refute_email_sent()
    end

    test "a delayed original job is discarded when a snooze wakes the same instance", ctx do
      [original] = all_enqueued(worker: ReminderEmailWorker)
      assert original.args["snooze_count"] == 0
      instance = snooze_and_wake(ctx.instance)
      assert instance.status == "pending"
      assert instance.snooze_count == 1

      # Drain the real queue, including both the original delayed job and the
      # newly inserted wake job. A direct perform of only the wake job would
      # miss the duplicate-delivery regression.
      assert %{discard: 1, success: 1, failure: 0} = Oban.drain_queue(queue: :reminders)
      assert Repo.reload!(original).state == "discarded"
      assert_one_delivery()
    end

    test "a retryable original job cannot send after a later snooze wakes", ctx do
      [original] = all_enqueued(worker: ReminderEmailWorker)
      original_mailer = Application.get_env(:kith, Kith.Mailer)
      :ok = fail_mail(ctx)

      assert %{failure: 1, success: 0} = Oban.drain_queue(queue: :reminders)
      assert Repo.reload!(original).state == "retryable"
      Application.put_env(:kith, Kith.Mailer, original_mailer)

      snooze_and_wake(ctx.instance)

      assert %{discard: 1, success: 1, failure: 0} =
               Oban.drain_queue(queue: :reminders, with_scheduled: true)

      assert %{state: "discarded", attempt: 2} = Repo.reload!(original)
      assert_one_delivery()
    end

    test "only the latest notice can send after two snoozes", ctx do
      snooze_and_wake(ctx.instance)
      instance = snooze_and_wake(ctx.instance)
      assert instance.snooze_count == 2

      assert all_enqueued(worker: ReminderEmailWorker)
             |> Enum.map(& &1.args["snooze_count"])
             |> Enum.sort() == [0, 1, 2]

      assert %{discard: 2, success: 1, failure: 0} = Oban.drain_queue(queue: :reminders)
      assert_one_delivery()
    end

    test "legacy jobs without a snooze count become stale after the first snooze", ctx do
      [original] = all_enqueued(worker: ReminderEmailWorker)

      original
      |> Ecto.Changeset.change(args: Map.delete(original.args, "snooze_count"))
      |> Repo.update!()

      snooze_and_wake(ctx.instance)

      assert %{discard: 1, success: 1, failure: 0} = Oban.drain_queue(queue: :reminders)
      assert Repo.reload!(original).state == "discarded"
      assert_one_delivery()
    end
  end

  describe "delivery eligibility" do
    for blocked <- [:inactive, :deleted, :archived, :resolved, :dismissed, :snoozed, :failed] do
      test "discards a queued email after #{blocked}", ctx do
        block_delivery(ctx, unquote(blocked))

        assert {:discard, _} = perform_job(ReminderEmailWorker, %{instance_id: ctx.instance.id})
        refute_email_sent()
      end
    end

    test "discards a queued email after its contact is permanently deleted", ctx do
      Repo.delete!(ctx.contact)

      assert {:discard, _} = perform_job(ReminderEmailWorker, %{instance_id: ctx.instance.id})
      refute_email_sent()
    end

    test "deceased status does not stop a queued email", ctx do
      {:ok, _} = Kith.Contacts.update_contact(ctx.contact, %{deceased: true})

      assert :ok = perform_job(ReminderEmailWorker, %{instance_id: ctx.instance.id})
      assert_email_sent(subject: "Reminder: Call Mona")
    end
  end

  describe "eligibility changes between delivery attempts" do
    setup :fail_mail

    for blocked <- [:inactive, :deleted, :archived, :resolved, :dismissed, :snoozed, :failed] do
      test "does not retry delivery after #{blocked}", ctx do
        assert {:error, :boom} =
                 perform_job(ReminderEmailWorker, %{instance_id: ctx.instance.id}, attempt: 1)

        block_delivery(ctx, unquote(blocked))
        before = Repo.get!(ReminderInstance, ctx.instance.id)

        assert {:discard, _} =
                 perform_job(ReminderEmailWorker, %{instance_id: ctx.instance.id}, attempt: 3)

        assert Repo.get!(ReminderInstance, ctx.instance.id) == before
      end
    end
  end

  defp block_delivery(ctx, :inactive) do
    ctx.instance.reminder_id
    |> then(&Repo.get!(Reminder, &1))
    |> Reminders.update_reminder(%{active: false})
  end

  defp block_delivery(ctx, :deleted), do: Kith.Contacts.soft_delete_contact(ctx.contact)
  defp block_delivery(ctx, :archived), do: Kith.Contacts.archive_contact(ctx.contact)

  defp block_delivery(ctx, status) do
    ctx.instance
    |> Ecto.Changeset.change(status: Atom.to_string(status))
    |> Repo.update!()
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
      today = Reminders.account_today(ctx.user.account_id)

      {:ok, reminder} =
        Reminders.create_reminder(ctx.user.account_id, ctx.user.id, %{
          type: "stay_in_touch",
          frequency: "monthly",
          anchor_date: today,
          contact_id: ctx.contact.id
        })

      :ok = dispatch_today(ctx.user.account_id)
      [instance] = Repo.all(from(i in ReminderInstance, where: i.reminder_id == ^reminder.id))

      assert {:error, :boom} =
               perform_job(ReminderEmailWorker, %{instance_id: instance.id}, attempt: 3)

      assert Repo.get!(ReminderInstance, instance.id).status == "failed"
      assert Repo.get!(Reminder, reminder.id).next_reminder_date == Date.shift(today, month: 1)
    end
  end

  describe "subjects and bodies" do
    defp fire!(user, contact, attrs) do
      {:ok, r} =
        Reminders.create_reminder(
          user.account_id,
          user.id,
          Map.merge(
            %{anchor_date: Reminders.account_today(user.account_id), contact_id: contact.id},
            attrs
          )
        )

      :ok = dispatch_today(user.account_id)
      [i] = Repo.all(from(i in ReminderInstance, where: i.reminder_id == ^r.id))
      perform_job(ReminderEmailWorker, %{instance_id: i.id})
    end

    test "a first-met anniversary has its own subject", %{user: user, contact: contact} do
      fire!(user, contact, %{
        type: "first_met",
        title: nil,
        interval_unit: "year",
        interval_count: 1
      })

      name = Repo.reload!(contact).display_name
      assert_email_sent(subject: "Anniversary of meeting #{name}")
    end

    test "the description is included in the body", %{user: user, contact: contact} do
      fire!(user, contact, %{type: "one_time", title: "Party", description: "Bring the cake"})
      assert_email_sent(fn email -> email.text_body =~ "Bring the cake" end)
    end
  end
end
