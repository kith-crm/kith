defmodule Kith.TimeHelperTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Kith.TimeHelper

  describe "to_utc_scheduled_at/3" do
    test "converts winter EST correctly (UTC-5)" do
      result = TimeHelper.to_utc_scheduled_at(~D[2026-01-15], 14, "America/New_York")
      assert result.hour == 19
      assert result.minute == 0
    end

    test "converts summer EDT correctly (UTC-4)" do
      result = TimeHelper.to_utc_scheduled_at(~D[2026-07-15], 14, "America/New_York")
      assert result.hour == 18
      assert result.minute == 0
    end

    test "handles UTC timezone (no offset)" do
      result = TimeHelper.to_utc_scheduled_at(~D[2026-03-15], 9, "Etc/UTC")
      assert result.hour == 9
    end

    test "truncates to second precision" do
      result = TimeHelper.to_utc_scheduled_at(~D[2026-01-15], 14, "America/New_York")
      assert result.microsecond == {0, 0}
    end
  end

  describe "valid_timezone?/1" do
    test "accepts valid IANA timezone" do
      assert TimeHelper.valid_timezone?("America/New_York")
      assert TimeHelper.valid_timezone?("Europe/London")
      assert TimeHelper.valid_timezone?("Etc/UTC")
    end

    test "rejects invalid timezone" do
      refute TimeHelper.valid_timezone?("Invalid/Timezone")
      refute TimeHelper.valid_timezone?("NotA/RealZone")
    end
  end

  describe "next_birthday_date/1" do
    test "returns this year if birthday hasn't passed" do
      # Set birthday far in the future month
      birthday = %Date{year: 1990, month: 12, day: 25}
      result = TimeHelper.next_birthday_date(birthday)
      today = Date.utc_today()

      if today.month < 12 or (today.month == 12 and today.day <= 25) do
        assert result.year == today.year
        assert result.month == 12
        assert result.day == 25
      else
        assert result.year == today.year + 1
      end
    end

    test "returns next year if birthday already passed" do
      # Set birthday to January 1
      birthday = %Date{year: 1990, month: 1, day: 1}
      result = TimeHelper.next_birthday_date(birthday)
      today = Date.utc_today()

      if today.month == 1 and today.day == 1 do
        assert result.year == today.year
      else
        assert result.year == today.year + 1
      end
    end

    test "Feb 29 birthday in non-leap year falls back to Feb 28" do
      birthday = %Date{year: 1996, month: 2, day: 29}
      result = TimeHelper.next_birthday_date(birthday)

      if Calendar.ISO.leap_year?(result.year) do
        assert result.day == 29
      else
        assert result.day == 28
      end

      assert result.month == 2
    end
  end

  describe "safe_date/3" do
    test "Feb 29 in leap year" do
      assert TimeHelper.safe_date(2024, 2, 29) == ~D[2024-02-29]
    end

    test "Feb 29 in non-leap year falls back to Feb 28" do
      assert TimeHelper.safe_date(2025, 2, 29) == ~D[2025-02-28]
    end

    test "regular dates pass through" do
      assert TimeHelper.safe_date(2026, 3, 15) == ~D[2026-03-15]
    end
  end

  describe "advance_by_frequency/2" do
    test "weekly advances by 7 days" do
      assert TimeHelper.advance_by_frequency(~D[2026-01-01], "weekly") == ~D[2026-01-08]
    end

    test "biweekly advances by 14 days" do
      assert TimeHelper.advance_by_frequency(~D[2026-01-01], "biweekly") == ~D[2026-01-15]
    end

    test "monthly advances by 30 days" do
      assert TimeHelper.advance_by_frequency(~D[2026-01-01], "monthly") == ~D[2026-01-31]
    end

    test "annually advances by 365 days" do
      assert TimeHelper.advance_by_frequency(~D[2026-01-01], "annually") == ~D[2027-01-01]
    end
  end

  describe "local_date_hour/2" do
    test "converts UTC to the timezone's local date and hour" do
      assert TimeHelper.local_date_hour(~U[2026-09-26 20:30:00Z], "Asia/Tokyo") ==
               {~D[2026-09-27], 5}

      assert TimeHelper.local_date_hour(~U[2026-01-15 03:00:00Z], "America/New_York") ==
               {~D[2026-01-14], 22}
    end

    test "falls back to UTC for an invalid or missing timezone" do
      assert TimeHelper.local_date_hour(~U[2026-09-26 20:30:00Z], "Mars/Olympus") ==
               {~D[2026-09-26], 20}

      assert TimeHelper.local_date_hour(~U[2026-09-26 20:30:00Z], nil) == {~D[2026-09-26], 20}
    end

    test "logs a warning for invalid timezone but not for nil" do
      log =
        capture_log(fn ->
          TimeHelper.local_date_hour(~U[2026-09-26 20:30:00Z], "Mars/Olympus")
        end)

      assert log =~ "invalid timezone"

      log_nil =
        capture_log(fn ->
          TimeHelper.local_date_hour(~U[2026-09-26 20:30:00Z], nil)
        end)

      refute log_nil =~ "invalid timezone"
    end
  end

  describe "local_today/1" do
    test "returns a date" do
      assert %Date{} = TimeHelper.local_today("Etc/UTC")
    end
  end
end
