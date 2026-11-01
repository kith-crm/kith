defmodule Kith.Reminders.ReminderInstance do
  @moduledoc """
  A notice sent for one occurrence of a reminder. Created by
  `Kith.Reminders.Dispatcher`; the unique index on (reminder_id,
  occurrence_date, days_before) makes each notice send once.
  Tracks the lifecycle from pending → resolved/dismissed/failed.

  Uses `fired_at` (Decision A) for the timestamp when the notification was sent.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(pending resolved dismissed failed snoozed)
  @kinds ~w(on_day advance)

  schema "reminder_instances" do
    field :status, :string, default: "pending"
    field :scheduled_for, :utc_datetime
    field :fired_at, :utc_datetime
    field :resolved_at, :utc_datetime
    field :snoozed_until, :utc_datetime
    field :snooze_count, :integer, default: 0
    field :occurrence_date, :date
    field :kind, :string
    field :days_before, :integer

    belongs_to :reminder, Kith.Reminders.Reminder
    belongs_to :account, Kith.Accounts.Account
    belongs_to :contact, Kith.Contacts.Contact

    timestamps(type: :utc_datetime)
  end

  def statuses, do: @statuses

  def create_changeset(instance, attrs) do
    instance
    |> cast(attrs, [
      :status,
      :scheduled_for,
      :fired_at,
      :snoozed_until,
      :snooze_count,
      :occurrence_date,
      :kind,
      :days_before,
      :reminder_id,
      :account_id,
      :contact_id
    ])
    |> validate_required([
      :scheduled_for,
      :occurrence_date,
      :kind,
      :days_before,
      :reminder_id,
      :account_id,
      :contact_id
    ])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:kind, @kinds)
    |> foreign_key_constraint(:reminder_id)
    |> foreign_key_constraint(:account_id)
    |> foreign_key_constraint(:contact_id)
    |> unique_constraint([:reminder_id, :occurrence_date, :days_before],
      name: :reminder_instances_occurrence_idx
    )
  end

  def resolve_changeset(instance) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    change(instance, status: "resolved", resolved_at: now)
  end

  def dismiss_changeset(instance) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    change(instance, status: "dismissed", resolved_at: now)
  end

  def fail_changeset(instance) do
    change(instance, status: "failed")
  end

  @snooze_durations %{
    "fifteen_minutes" => 15,
    "one_hour" => 60,
    "one_day" => 1440,
    "three_days" => 4320
  }

  def snooze_durations, do: Map.keys(@snooze_durations)

  def snooze_changeset(instance, duration) when is_binary(duration) do
    minutes = Map.fetch!(@snooze_durations, duration)
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    snoozed_until = DateTime.add(now, minutes, :minute)

    instance
    |> change(
      status: "snoozed",
      snoozed_until: snoozed_until,
      snooze_count: (instance.snooze_count || 0) + 1
    )
  end
end
