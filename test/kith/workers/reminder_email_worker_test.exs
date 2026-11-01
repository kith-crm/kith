defmodule Kith.Workers.ReminderEmailWorkerTest do
  use Kith.DataCase, async: true
  use Oban.Testing, repo: Kith.Repo

  import Ecto.Query
  import Swoosh.TestAssertions

  alias Kith.Reminders
  alias Kith.Reminders.{Dispatcher, ReminderInstance}
  alias Kith.Workers.ReminderEmailWorker

  import Kith.ReminderEmailFixtures

  setup do
    setup_fixture()
  end

  test "only the creator receives the email, not another account member", ctx do
    other = Kith.Factory.insert(:user, account: Kith.Accounts.get_account!(ctx.user.account_id))
    assert other.account_id == ctx.user.account_id
    assert :ok = perform_job(ReminderEmailWorker, %{instance_id: ctx.instance.id})

    assert_email_sent(fn email ->
      assert email.to == [{ctx.user.email, ctx.user.email}]
      assert email.cc == []
      assert email.bcc == []
      assert email.subject == "Reminder: Call Mona"
    end)

    refute_email_sent()
  end

  for {type, kind, days, title, subject} <- [
        {"birthday", "on_day", 0, nil, "Mona Vale's birthday is today"},
        {"birthday", "advance", 7, nil, "Mona Vale's birthday is in 7 days"},
        {"one_time", "advance", 30, "Renew passport", "Reminder in 30 days: Renew passport"},
        {"stay_in_touch", "on_day", 0, "Reach out", "Time to reach out to Mona Vale"}
      ] do
    test "#{type} #{kind} email contains its subject and contact", ctx do
      type = unquote(type)

      attrs = %{
        type: type,
        title: unquote(title),
        anchor_date: ~D[2026-10-29],
        contact_id: ctx.contact.id
      }

      attrs =
        if type == "one_time",
          do: attrs,
          else: Map.merge(attrs, %{interval_unit: "year", interval_count: 1})

      {:ok, reminder} = Reminders.create_reminder(ctx.user.account_id, ctx.user.id, attrs)

      instance =
        %ReminderInstance{}
        |> ReminderInstance.create_changeset(%{
          reminder_id: reminder.id,
          account_id: ctx.user.account_id,
          contact_id: ctx.contact.id,
          occurrence_date: ~D[2026-10-29],
          scheduled_for: ~U[2026-10-29 09:00:00Z],
          kind: unquote(kind),
          days_before: unquote(days)
        })
        |> Repo.insert!()

      assert :ok = perform_job(ReminderEmailWorker, %{instance_id: instance.id, snooze_count: 0})

      assert_email_sent(fn email ->
        assert email.to == [{ctx.user.email, ctx.user.email}]
        assert email.subject == unquote(subject)
        assert email.text_body == unquote(subject) <> "\n\nContact: Mona Vale"
      end)

      refute_email_sent()
    end
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
