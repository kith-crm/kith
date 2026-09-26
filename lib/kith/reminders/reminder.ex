defmodule Kith.Reminders.Reminder do
  @moduledoc """
  A reminder associated with a contact.

  The schedule is `anchor_date` (the first occurrence) plus an optional
  interval (`interval_unit` × `interval_count`). `next_reminder_date` caches
  the next occurrence; it is computed here and advanced by
  `Kith.Reminders.Dispatcher`, never set by clients.

  Types:
  - `birthday` — derived from the contact's birthdate (`Kith.Reminders.sync_birthday/1`)
  - `stay_in_touch` — re-armed one interval after it is resolved or dismissed
  - `one_time` — a single date, no interval
  - `recurring` — repeats every interval
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Kith.Reminders.Occurrences

  @types ~w(birthday stay_in_touch one_time recurring)
  @units ~w(week month year)
  @frequencies ~w(weekly biweekly monthly 3months 6months annually)
  @presets %{
    "weekly" => {"week", 1},
    "biweekly" => {"week", 2},
    "monthly" => {"month", 1},
    "3months" => {"month", 3},
    "6months" => {"month", 6},
    "annually" => {"year", 1}
  }

  schema "reminders" do
    field :type, :string
    field :title, :string
    field :anchor_date, :date
    field :interval_unit, :string
    field :interval_count, :integer
    field :next_reminder_date, :date
    field :active, :boolean, default: true
    # Preset name ("weekly", …) accepted on input and mapped to unit + count.
    field :frequency, :string, virtual: true

    belongs_to :contact, Kith.Contacts.Contact
    belongs_to :account, Kith.Accounts.Account
    belongs_to :creator, Kith.Accounts.User

    has_many :reminder_instances, Kith.Reminders.ReminderInstance

    timestamps(type: :utc_datetime)
  end

  def types, do: @types
  def units, do: @units
  def frequencies, do: @frequencies

  @doc "The reminder's schedule, in the shape `Kith.Reminders.Occurrences` takes."
  @spec schedule(%__MODULE__{}) :: Occurrences.schedule()
  def schedule(%__MODULE__{} = reminder),
    do: Map.take(reminder, [:anchor_date, :interval_unit, :interval_count])

  @doc "The preset name for this interval, or nil when it matches no preset."
  @spec frequency_preset(map()) :: String.t() | nil
  def frequency_preset(%{interval_unit: unit, interval_count: count}) do
    Enum.find_value(@presets, fn {name, pair} -> if pair == {unit, count}, do: name end)
  end

  @doc "Human label for the interval (\"Weekly\", \"Every 3 weeks\"), or nil for one-time."
  @spec interval_label(map()) :: String.t() | nil
  def interval_label(%{interval_unit: nil}), do: nil
  def interval_label(%{interval_unit: "week", interval_count: 1}), do: "Weekly"
  def interval_label(%{interval_unit: "month", interval_count: 1}), do: "Monthly"
  def interval_label(%{interval_unit: "year", interval_count: 1}), do: "Annually"
  def interval_label(%{interval_unit: unit, interval_count: n}), do: "Every #{n} #{unit}s"

  def create_changeset(reminder, attrs, %Date{} = today \\ Date.utc_today()) do
    reminder
    |> cast(attrs, [
      :type,
      :title,
      :frequency,
      :anchor_date,
      :interval_unit,
      :interval_count,
      :next_reminder_date,
      :active,
      :contact_id,
      :account_id,
      :creator_id
    ])
    |> anchor_from_legacy_next_date()
    |> apply_frequency_preset()
    |> validate_required([:type, :anchor_date, :contact_id, :account_id, :creator_id])
    |> validate_inclusion(:type, @types)
    |> validate_schedule()
    |> put_next_reminder_date(today)
    |> foreign_key_constraint(:contact_id)
    |> foreign_key_constraint(:account_id)
    |> foreign_key_constraint(:creator_id)
    |> unique_constraint(:contact_id, name: :reminders_birthday_unique_idx)
  end

  @doc "Updates title/schedule/active. `next_reminder_date` in attrs is ignored."
  def update_changeset(reminder, attrs, %Date{} = today \\ Date.utc_today()) do
    reminder
    |> cast(attrs, [:title, :frequency, :anchor_date, :interval_unit, :interval_count, :active])
    |> apply_frequency_preset()
    |> validate_required([:anchor_date])
    |> validate_schedule()
    |> recompute_next_if_schedule_changed(today)
  end

  @doc "Stay-in-touch: next date is one interval after `today` (from the last contact)."
  def rearm_changeset(%__MODULE__{} = reminder, %Date{} = today) do
    next = Occurrences.advance_after(%{schedule(reminder) | anchor_date: today}, today)
    change(reminder, next_reminder_date: next)
  end

  @doc "Sets the cached next occurrence (used by the dispatcher)."
  def advance_changeset(%__MODULE__{} = reminder, %Date{} = next_date),
    do: change(reminder, next_reminder_date: next_date)

  # A create request naming `next_reminder_date` but no `anchor_date` (older
  # API clients, fixtures) means "first occurrence on this date".
  defp anchor_from_legacy_next_date(changeset) do
    case {get_field(changeset, :anchor_date), get_change(changeset, :next_reminder_date)} do
      {nil, %Date{} = date} -> put_change(changeset, :anchor_date, date)
      _ -> changeset
    end
  end

  defp apply_frequency_preset(changeset) do
    case get_change(changeset, :frequency) do
      nil ->
        changeset

      name ->
        case Map.fetch(@presets, name) do
          {:ok, {unit, count}} ->
            changeset |> put_change(:interval_unit, unit) |> put_change(:interval_count, count)

          :error ->
            add_error(changeset, :frequency, "is invalid",
              validation: :inclusion,
              enum: @frequencies
            )
        end
    end
  end

  defp validate_schedule(changeset) do
    case get_field(changeset, :type) do
      "one_time" ->
        cond do
          get_change(changeset, :frequency) ->
            add_error(changeset, :frequency, "must be nil for one-time reminders")

          get_field(changeset, :interval_unit) || get_field(changeset, :interval_count) ->
            add_error(changeset, :interval_unit, "must be empty for one-time reminders")

          true ->
            changeset
        end

      _repeating ->
        if is_nil(get_field(changeset, :interval_unit)) and
             is_nil(get_change(changeset, :frequency)) do
          add_error(changeset, :frequency, "can't be blank", validation: :required)
        else
          changeset
          |> validate_required([:interval_unit, :interval_count])
          |> validate_inclusion(:interval_unit, @units)
          |> validate_number(:interval_count, greater_than_or_equal_to: 1)
        end
    end
  end

  defp put_next_reminder_date(%Ecto.Changeset{valid?: false} = changeset, _today), do: changeset

  defp put_next_reminder_date(changeset, today) do
    schedule = %{
      anchor_date: get_field(changeset, :anchor_date),
      interval_unit: get_field(changeset, :interval_unit),
      interval_count: get_field(changeset, :interval_count)
    }

    # A one-time reminder keeps its own date even when it is already past.
    next = Occurrences.next_on_or_after(schedule, today) || schedule.anchor_date
    put_change(changeset, :next_reminder_date, next)
  end

  defp recompute_next_if_schedule_changed(changeset, today) do
    if Enum.any?(
         [:anchor_date, :interval_unit, :interval_count],
         &Map.has_key?(changeset.changes, &1)
       ),
       do: put_next_reminder_date(changeset, today),
       else: changeset
  end
end
