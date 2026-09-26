defmodule Kith.TimeHelper do
  @moduledoc """
  Timezone-aware scheduling helpers for the Reminders system.

  All conversions use IANA timezone names (e.g., "America/New_York") and
  the Elixir stdlib `DateTime` with `Tz` database. Never stores or caches
  UTC offsets — always recomputes from IANA name at scheduling time.
  """

  alias Kith.Reminders.Reminder
  require Logger

  @doc """
  Converts a date + hour + IANA timezone to a UTC DateTime for Oban scheduling.

  ## Examples

      iex> to_utc_scheduled_at(~D[2026-01-15], 14, "America/New_York")
      ~U[2026-01-15 19:00:00Z]  # EST = UTC-5

      iex> to_utc_scheduled_at(~D[2026-07-15], 14, "America/New_York")
      ~U[2026-07-15 18:00:00Z]  # EDT = UTC-4
  """
  @spec to_utc_scheduled_at(Date.t(), 0..23, String.t()) :: DateTime.t()
  def to_utc_scheduled_at(%Date{} = date, hour, timezone) when hour in 0..23 do
    naive = NaiveDateTime.new!(date, Time.new!(hour, 0, 0))

    naive
    |> DateTime.from_naive!(timezone)
    |> DateTime.shift_zone!("Etc/UTC")
    |> DateTime.truncate(:second)
  end

  @doc """
  Validates that a timezone string is a known IANA timezone.
  """
  @spec valid_timezone?(String.t()) :: boolean()
  def valid_timezone?(timezone) do
    case DateTime.from_naive(~N[2000-01-01 00:00:00], timezone) do
      {:ok, _} -> true
      _ -> false
    end
  end

  @doc """
  Computes the next occurrence of a birthday given a birth date.
  If the birthday hasn't occurred yet this year, returns this year's date.
  If it has already passed, returns next year's date.

  Handles Feb 29 → Feb 28 in non-leap years.
  """
  @spec next_birthday_date(Date.t()) :: Date.t()
  def next_birthday_date(%Date{month: month, day: day}) do
    today = Date.utc_today()
    this_year = safe_date(today.year, month, day)

    if Date.compare(this_year, today) in [:gt, :eq] do
      this_year
    else
      safe_date(today.year + 1, month, day)
    end
  end

  @doc """
  Builds a date, handling Feb 29 → Feb 28 for non-leap years.
  """
  @spec safe_date(integer(), pos_integer(), pos_integer()) :: Date.t()
  def safe_date(year, 2, 29) do
    if Calendar.ISO.leap_year?(year) do
      Date.new!(year, 2, 29)
    else
      Date.new!(year, 2, 28)
    end
  end

  def safe_date(year, month, day), do: Date.new!(year, month, day)

  @doc """
  The local date and hour of `now` in `timezone`. A missing (nil) timezone
  is treated as UTC; an invalid one also falls back to UTC and logs a warning,
  so one bad account setting can't stop reminder dispatch.
  """
  @spec local_date_hour(DateTime.t(), String.t() | nil) :: {Date.t(), 0..23}
  def local_date_hour(%DateTime{} = now, timezone) do
    local =
      case DateTime.shift_zone(now, timezone || "Etc/UTC") do
        {:ok, shifted} ->
          shifted

        {:error, _reason} ->
          Logger.warning("[TimeHelper] invalid timezone #{inspect(timezone)}; using UTC")
          now
      end

    {DateTime.to_date(local), local.hour}
  end

  @doc "Today's date in `timezone` (same fallback as `local_date_hour/2`)."
  @spec local_today(String.t() | nil) :: Date.t()
  def local_today(timezone) do
    {date, _hour} = local_date_hour(DateTime.utc_now(), timezone)
    date
  end

  @doc """
  Advances a date by the given frequency interval.
  """
  @spec advance_by_frequency(Date.t(), String.t()) :: Date.t()
  def advance_by_frequency(%Date{} = date, frequency) do
    days = Reminder.frequency_days(frequency)
    Date.add(date, days)
  end
end
