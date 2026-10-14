defmodule Kith.Reminders.Occurrences do
  @moduledoc """
  Pure date arithmetic for reminder schedules.

  A schedule is an anchor date (the first occurrence) plus an optional
  interval of `interval_unit` × `interval_count`. Occurrence *n* is always
  derived from the anchor, never from the previous occurrence, so month-end
  and Feb 29 anchors fall back in short months/years without drifting.
  """

  @type schedule :: %{
          required(:anchor_date) => Date.t(),
          required(:interval_unit) => String.t() | nil,
          required(:interval_count) => pos_integer() | nil
        }

  @doc "The first occurrence on or after `date`, or nil (a one-time schedule whose date has passed)."
  @spec next_on_or_after(schedule(), Date.t()) :: Date.t() | nil
  def next_on_or_after(%{anchor_date: anchor, interval_unit: nil}, %Date{} = date) do
    if Date.compare(anchor, date) == :lt, do: nil, else: anchor
  end

  def next_on_or_after(%{anchor_date: anchor} = schedule, %Date{} = date) do
    if Date.compare(anchor, date) == :lt do
      schedule
      |> lower_bound_index(date)
      |> first_on_or_after(schedule, date)
    else
      anchor
    end
  end

  @doc "The occurrence strictly after `date`; nil for one-time schedules."
  @spec advance_after(schedule(), Date.t()) :: Date.t() | nil
  def advance_after(%{interval_unit: nil}, _date), do: nil
  def advance_after(schedule, %Date{} = date), do: next_on_or_after(schedule, Date.add(date, 1))

  @doc "Occurrence number `n` (0 = the anchor)."
  @spec nth(schedule(), non_neg_integer()) :: Date.t()
  def nth(%{anchor_date: anchor, interval_unit: "week", interval_count: count}, n),
    do: Date.add(anchor, 7 * count * n)

  def nth(%{anchor_date: anchor, interval_unit: "month", interval_count: count}, n),
    do: Date.shift(anchor, month: count * n)

  def nth(%{anchor_date: anchor, interval_unit: "year", interval_count: count}, n),
    do: Date.shift(anchor, year: count * n)

  # An index whose occurrence is not after `date`; month/year clamping can
  # leave it a few days short, so `first_on_or_after/3` steps forward.
  defp lower_bound_index(%{anchor_date: anchor, interval_unit: "week", interval_count: c}, date),
    do: div(Date.diff(date, anchor), 7 * c)

  defp lower_bound_index(%{anchor_date: anchor, interval_unit: "month", interval_count: c}, date) do
    months = (date.year - anchor.year) * 12 + (date.month - anchor.month)
    max(div(months, c) - 1, 0)
  end

  defp lower_bound_index(%{anchor_date: anchor, interval_unit: "year", interval_count: c}, date),
    do: max(div(date.year - anchor.year, c) - 1, 0)

  defp first_on_or_after(n, schedule, date) do
    candidate = nth(schedule, n)

    if Date.compare(candidate, date) == :lt,
      do: first_on_or_after(n + 1, schedule, date),
      else: candidate
  end
end
