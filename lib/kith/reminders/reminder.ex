defmodule Kith.Reminders.Reminder do
  @moduledoc """
  A reminder associated with a contact. Supports four types:
  - `birthday` — auto-created when a contact's birthdate is set
  - `stay_in_touch` — recurring, re-fires after resolution via activity/call
  - `one_time` — fires once on the target date
  - `recurring` — fires on a schedule, auto-advances next_reminder_date
  """

  use Ecto.Schema
  import Ecto.Changeset

  @types ~w(birthday stay_in_touch one_time recurring)
  @frequencies ~w(weekly biweekly monthly 3months 6months annually)

  schema "reminders" do
    field :type, :string
    field :title, :string
    field :frequency, :string
    field :next_reminder_date, :date
    field :enqueued_oban_job_ids, {:array, :integer}, default: []
    field :active, :boolean, default: true

    belongs_to :contact, Kith.Contacts.Contact
    belongs_to :account, Kith.Accounts.Account
    belongs_to :creator, Kith.Accounts.User

    has_many :reminder_instances, Kith.Reminders.ReminderInstance

    timestamps(type: :utc_datetime)
  end

  def types, do: @types
  def frequencies, do: @frequencies

  @doc """
  Frequency interval in days for scheduling calculations.
  """
  def frequency_days("weekly"), do: 7
  def frequency_days("biweekly"), do: 14
  def frequency_days("monthly"), do: 30
  def frequency_days("3months"), do: 90
  def frequency_days("6months"), do: 180
  def frequency_days("annually"), do: 365

  def create_changeset(reminder, attrs) do
    reminder
    |> cast(attrs, [
      :type,
      :title,
      :frequency,
      :next_reminder_date,
      :active,
      :contact_id,
      :account_id,
      :creator_id
    ])
    |> validate_required([:type, :next_reminder_date, :contact_id, :account_id, :creator_id])
    |> validate_inclusion(:type, @types)
    |> validate_frequency()
    |> foreign_key_constraint(:contact_id)
    |> foreign_key_constraint(:account_id)
    |> foreign_key_constraint(:creator_id)
    |> unique_constraint(:contact_id, name: :reminders_birthday_unique_idx)
  end

  def update_changeset(reminder, attrs) do
    reminder
    |> cast(attrs, [:title, :frequency, :next_reminder_date, :active, :enqueued_oban_job_ids])
    |> validate_frequency()
  end

  @doc """
  Turns an existing reminder of any type into a birthday reminder, keeping its
  id. Used by the Monica importer to reclaim a generic reminder it created on
  an earlier run (before the contact had a birthdate) instead of adding a
  second row.
  """
  def convert_to_birthday_changeset(reminder, %Date{} = next_reminder_date) do
    reminder
    |> change(
      type: "birthday",
      title: nil,
      frequency: nil,
      next_reminder_date: next_reminder_date
    )
    |> unique_constraint(:contact_id, name: :reminders_birthday_unique_idx)
  end

  def job_ids_changeset(reminder, job_ids) when is_list(job_ids) do
    change(reminder, enqueued_oban_job_ids: job_ids)
  end

  # Frequency is required for stay_in_touch and recurring, must be nil for one_time
  defp validate_frequency(changeset) do
    type = get_field(changeset, :type)
    frequency = get_field(changeset, :frequency)

    case type do
      t when t in ["stay_in_touch", "recurring"] ->
        changeset
        |> validate_required([:frequency])
        |> validate_inclusion(:frequency, @frequencies)

      "one_time" ->
        if frequency do
          add_error(changeset, :frequency, "must be nil for one-time reminders")
        else
          changeset
        end

      # birthday: frequency is ignored
      _ ->
        changeset
    end
  end
end
