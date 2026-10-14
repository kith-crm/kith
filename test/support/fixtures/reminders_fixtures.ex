defmodule Kith.RemindersFixtures do
  @moduledoc """
  Test helpers for creating entities via the `Kith.Reminders` context.
  """

  alias Kith.Repo
  alias Kith.Reminders
  alias Kith.Reminders.{Reminder, ReminderInstance}

  def reminder_fixture(account_id, contact_id, creator_id, attrs \\ %{}) do
    attrs =
      Enum.into(attrs, %{
        type: "one_time",
        title: "Test reminder #{System.unique_integer([:positive])}",
        next_reminder_date: Date.add(Date.utc_today(), 7),
        contact_id: contact_id,
        account_id: account_id,
        creator_id: creator_id
      })

    %Reminder{}
    |> Reminder.create_changeset(attrs)
    |> Repo.insert!()
  end

  def birthday_reminder_fixture(account_id, contact_id, creator_id, next_date \\ nil) do
    reminder_fixture(account_id, contact_id, creator_id, %{
      type: "birthday",
      title: nil,
      interval_unit: "year",
      interval_count: 1,
      next_reminder_date: next_date || Date.add(Date.utc_today(), 30)
    })
  end

  def stay_in_touch_reminder_fixture(account_id, contact_id, creator_id, frequency \\ "monthly") do
    reminder_fixture(account_id, contact_id, creator_id, %{
      type: "stay_in_touch",
      title: nil,
      frequency: frequency,
      next_reminder_date: Date.add(Date.utc_today(), 30)
    })
  end

  def recurring_reminder_fixture(account_id, contact_id, creator_id, frequency \\ "weekly") do
    reminder_fixture(account_id, contact_id, creator_id, %{
      type: "recurring",
      title: "Weekly check-in",
      frequency: frequency,
      next_reminder_date: Date.add(Date.utc_today(), 7)
    })
  end

  def reminder_instance_fixture(reminder, attrs \\ %{}) do
    attrs =
      Enum.into(attrs, %{
        reminder_id: reminder.id,
        account_id: reminder.account_id,
        contact_id: reminder.contact_id,
        scheduled_for: DateTime.utc_now() |> DateTime.truncate(:second),
        fired_at: DateTime.utc_now() |> DateTime.truncate(:second),
        status: "pending",
        # Distinct per call so a test can insert several instances for one
        # reminder without hitting the (reminder, occurrence, days_before) index.
        occurrence_date:
          Date.add(Date.utc_today(), -System.unique_integer([:positive, :monotonic])),
        kind: "on_day",
        days_before: 0
      })

    %ReminderInstance{}
    |> ReminderInstance.create_changeset(attrs)
    |> Repo.insert!()
  end

  def seed_reminder_rules!(account_id) do
    Reminders.seed_default_rules(account_id)

    Reminders.list_reminder_rules(account_id)
  end
end
