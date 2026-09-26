defmodule Kith.Reminders.OccurrencesTest do
  use ExUnit.Case, async: true

  alias Kith.Reminders.Occurrences

  defp s(anchor, unit \\ nil, count \\ nil),
    do: %{anchor_date: anchor, interval_unit: unit, interval_count: count}

  describe "next_on_or_after/2" do
    test "one-time: the anchor when on or after the date, else nil" do
      assert Occurrences.next_on_or_after(s(~D[2026-05-01]), ~D[2026-04-01]) == ~D[2026-05-01]
      assert Occurrences.next_on_or_after(s(~D[2026-05-01]), ~D[2026-05-01]) == ~D[2026-05-01]
      assert Occurrences.next_on_or_after(s(~D[2026-05-01]), ~D[2026-05-02]) == nil
    end

    test "a repeating schedule returns its anchor while the anchor is still ahead" do
      assert Occurrences.next_on_or_after(s(~D[2026-05-01], "month", 1), ~D[2026-01-01]) ==
               ~D[2026-05-01]
    end

    test "repeating schedules land on the calendar occurrence (table)" do
      for {unit, count, anchor, date, expected} <- [
            {"week", 1, ~D[2026-01-05], ~D[2026-01-05], ~D[2026-01-05]},
            {"week", 1, ~D[2026-01-05], ~D[2026-01-06], ~D[2026-01-12]},
            {"week", 2, ~D[2026-01-05], ~D[2026-09-26], ~D[2026-09-28]},
            {"week", 3, ~D[2026-01-05], ~D[2026-01-27], ~D[2026-02-16]},
            {"month", 1, ~D[2024-02-01], ~D[2026-09-26], ~D[2026-10-01]},
            {"month", 3, ~D[2026-01-15], ~D[2026-04-16], ~D[2026-07-15]},
            {"month", 6, ~D[2025-03-31], ~D[2026-09-01], ~D[2026-09-30]},
            {"year", 1, ~D[2015-03-09], ~D[2026-09-26], ~D[2027-03-09]},
            {"year", 2, ~D[2020-06-01], ~D[2026-09-26], ~D[2028-06-01]},
            {"year", 1, ~D[1990-06-15], ~D[2026-06-15], ~D[2026-06-15]}
          ] do
        assert Occurrences.next_on_or_after(s(anchor, unit, count), date) == expected,
               "#{unit}×#{count} from #{anchor} on/after #{date}"
      end
    end

    test "a 31st anchor falls back in short months and returns to the 31st (no drift)" do
      sched = s(~D[2026-01-31], "month", 1)
      assert Occurrences.next_on_or_after(sched, ~D[2026-02-01]) == ~D[2026-02-28]
      assert Occurrences.next_on_or_after(sched, ~D[2026-03-01]) == ~D[2026-03-31]
    end

    test "a Feb 29 anchor falls back to Feb 28 in non-leap years and returns to Feb 29" do
      sched = s(~D[1992-02-29], "year", 1)
      assert Occurrences.next_on_or_after(sched, ~D[2027-01-01]) == ~D[2027-02-28]
      assert Occurrences.next_on_or_after(sched, ~D[2028-01-01]) == ~D[2028-02-29]
    end

    test "an anchor far in the past resolves directly" do
      assert Occurrences.next_on_or_after(s(~D[1900-01-01], "week", 1), ~D[2026-09-26]) ==
               ~D[2026-09-28]
    end
  end

  describe "advance_after/2" do
    test "returns the occurrence strictly after the given date" do
      sched = s(~D[2026-01-05], "week", 1)
      assert Occurrences.advance_after(sched, ~D[2026-01-05]) == ~D[2026-01-12]
      assert Occurrences.advance_after(sched, ~D[2026-01-07]) == ~D[2026-01-12]
    end

    test "is nil for one-time schedules" do
      assert Occurrences.advance_after(s(~D[2026-01-05]), ~D[2026-01-05]) == nil
    end
  end
end
