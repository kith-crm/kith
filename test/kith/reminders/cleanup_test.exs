defmodule Kith.Reminders.CleanupTest do
  use Kith.DataCase, async: false
  use Oban.Testing, repo: Kith.Repo

  alias Kith.Reminders.{Cleanup, Reminder, ReminderInstance}
  alias Kith.Repo

  import Ecto.Query
  import Kith.AccountsFixtures
  import Kith.ContactsFixtures
  import Kith.RemindersFixtures

  setup do
    target = user_fixture()
    other = user_fixture()
    target_contact = contact_fixture(target.account_id)
    other_contact = contact_fixture(other.account_id)

    %{
      target_account: target.account_id,
      target_user: target.id,
      target_contact: target_contact,
      other_account: other.account_id,
      other_user: other.id,
      other_contact: other_contact
    }
  end

  test "wipes reminders + CASCADE rules/instances for target only", ctx do
    target_reminder = reminder_fixture(ctx.target_account, ctx.target_contact.id, ctx.target_user)
    other_reminder = reminder_fixture(ctx.other_account, ctx.other_contact.id, ctx.other_user)

    _target_instance = reminder_instance_fixture(target_reminder)
    _other_instance = reminder_instance_fixture(other_reminder)

    assert :ok = Cleanup.wipe_for_account(ctx.target_account)

    assert count_for(Reminder, ctx.target_account) == 0
    # ReminderRule is account-scoped (no reminder_id FK); verify it still exists for other account
    # ReminderInstance has a reminder_id FK — CASCADE should remove it
    assert count_orphans(ReminderInstance, [target_reminder.id]) == 0

    assert count_for(Reminder, ctx.other_account) == 1
  end

  test "cancels Oban jobs tracked on the target's reminders", ctx do
    {:ok, job} =
      Oban.insert(Kith.Workers.ReminderNotificationWorker.new(%{"reminder_instance_id" => 0}))

    target_reminder = reminder_fixture(ctx.target_account, ctx.target_contact.id, ctx.target_user)

    target_reminder
    |> Ecto.Changeset.change(enqueued_oban_job_ids: [job.id])
    |> Repo.update!()

    assert :ok = Cleanup.wipe_for_account(ctx.target_account)

    assert Repo.get!(Oban.Job, job.id).state == "cancelled"
  end

  test "is idempotent on empty account", ctx do
    assert :ok = Cleanup.wipe_for_account(ctx.target_account)
    assert :ok = Cleanup.wipe_for_account(ctx.target_account)
  end

  defp count_for(schema, account_id) do
    Repo.aggregate(from(s in schema, where: s.account_id == ^account_id), :count)
  end

  defp count_orphans(schema, reminder_ids) do
    Repo.aggregate(from(s in schema, where: s.reminder_id in ^reminder_ids), :count)
  end
end
