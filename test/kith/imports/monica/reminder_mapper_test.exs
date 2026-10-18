defmodule Kith.Imports.Monica.ReminderMapperTest do
  use ExUnit.Case, async: true

  alias Kith.Imports.Monica.ReminderMapper

  @today ~D[2026-10-14]
  @fixture Path.expand("../../../support/fixtures/monica/4.1.2/reminders.json", __DIR__)

  setup_all do
    data = @fixture |> File.read!() |> Jason.decode!()

    contacts =
      Map.new(data["contacts"], fn c ->
        {c["id"],
         %{
           birthdate:
             ReminderMapper.parse_date(get_in(c, ["information", "dates", "birthdate", "date"])),
           first_met_at:
             ReminderMapper.parse_date(
               get_in(c, ["information", "how_you_met", "first_met_date", "date"])
             )
         }}
      end)

    %{reminders: Map.new(data["reminders"], &{&1["id"], &1}), contacts: contacts, raw: data}
  end

  defp decide(ctx, id) do
    r = ctx.reminders[id]
    ReminderMapper.map(r, ctx.contacts[r["contact_id"]], @today)
  end

  defp recurring(unit, count, anchor),
    do: %{
      "type" => "recurring",
      "interval_unit" => unit,
      "interval_count" => count,
      "anchor_date" => anchor,
      "active" => true
    }

  defp one_time(anchor, active),
    do: %{
      "type" => "one_time",
      "interval_unit" => nil,
      "interval_count" => nil,
      "anchor_date" => anchor,
      "active" => active
    }

  # Monica reminder id => expected decision (spec §4 R1–R6, §8)
  @expected %{
    # API-edited, delible: true (M3)
    1 => :birthday,
    # 29 Feb
    2 => :birthday,
    3 => {:recurring, "year", 1, ~D[2015-03-09]},
    4 => {:recurring, "week", 2, ~D[2026-01-05]},
    5 => {:recurring, "month", 1, ~D[2024-02-01]},
    6 => {:one_time, ~D[2020-01-01], false},
    7 => {:one_time, ~D[2027-01-10], true},
    # year-unknown (M6)
    8 => :birthday,
    # deceased title (M5)
    9 => :birthday,
    # death anniversary
    10 => {:recurring, "year", 1, ~D[2020-08-01]},
    11 => :birthday,
    12 => :first_met,
    13 => {:recurring, "week", 2, ~D[2026-01-05]},
    14 => {:recurring, "month", 1, ~D[2025-01-31]},
    15 => {:recurring, "month", 3, ~D[2025-11-30]},
    16 => {:recurring, "year", 2, ~D[2016-02-29]},
    # today counts as due (D6)
    17 => {:one_time, ~D[2026-10-14], true},
    18 => {:one_time, ~D[2025-03-01], false},
    # already sent in Monica (M10)
    19 => {:one_time, ~D[2026-10-12], false},
    20 => {:one_time, ~D[2027-02-14], true},
    # frequency_number 0 (D7)
    21 => {:one_time, ~D[2027-06-01], true},
    # "Fiona birthday party" (D1 cost)
    22 => :birthday,
    # life event
    23 => {:recurring, "year", 1, ~D[2019-05-10]}
  }

  test "every captured Monica 4.1.2 reminder maps as the spec says", ctx do
    for {id, expected} <- @expected do
      got = decide(ctx, id)

      case expected do
        atom when is_atom(atom) ->
          assert got == atom, "reminder #{id}: #{inspect(got)}"

        {:recurring, unit, count, anchor} ->
          assert {:create, attrs, []} = got, "reminder #{id}: #{inspect(got)}"

          assert Map.take(attrs, Map.keys(recurring(unit, count, anchor))) ==
                   recurring(unit, count, anchor)

        {:one_time, anchor, active} ->
          assert {:create, attrs, _notes} = got, "reminder #{id}: #{inspect(got)}"

          assert Map.take(attrs, Map.keys(one_time(anchor, active))) ==
                   one_time(anchor, active)
      end
    end
  end

  test "titles and descriptions are copied", ctx do
    assert {:create, %{"title" => "One-time future", "description" => "Has a description"}, _} =
             decide(ctx, 20)
  end

  test "frequency_number 0 is noted", ctx do
    assert {:create, _, [:non_positive_interval]} = decide(ctx, 21)
  end

  test "unknown frequency types and unparseable dates are skipped" do
    contact = %{birthdate: nil, first_met_at: nil}

    assert {:skip, :unknown_frequency} =
             ReminderMapper.map(
               %{"frequency_type" => "fortnight", "initial_date" => "2026-01-01T00:00:00Z"},
               contact,
               @today
             )

    assert {:skip, :unparseable_date} =
             ReminderMapper.map(
               %{"frequency_type" => "week", "frequency_number" => 1, "initial_date" => "soon"},
               contact,
               @today
             )
  end

  test "a blank title falls back to Imported reminder" do
    contact = %{birthdate: nil, first_met_at: nil}

    assert {:create, %{"title" => "Imported reminder"}, _} =
             ReminderMapper.map(
               %{
                 "frequency_type" => "one_time",
                 "frequency_number" => 1,
                 "title" => " ",
                 "initial_date" => "2027-01-01T00:00:00Z"
               },
               contact,
               @today
             )
  end

  test "stay_in_touch/2 maps Monica's days onto a day interval", ctx do
    gina = Enum.find(ctx.raw["contacts"], &(&1["first_name"] == "Gina"))

    assert {:create,
            %{
              "type" => "stay_in_touch",
              "interval_unit" => "day",
              "interval_count" => 14,
              "anchor_date" => ~D[2026-10-28],
              "active" => true
            }, []} = ReminderMapper.stay_in_touch(gina, @today)

    assert ReminderMapper.stay_in_touch(%{"stay_in_touch_frequency" => nil}, @today) == :none
    assert ReminderMapper.stay_in_touch(%{"stay_in_touch_frequency" => 0}, @today) == :none

    assert {:create, %{"anchor_date" => ~D[2026-10-21]}, []} =
             ReminderMapper.stay_in_touch(
               %{"stay_in_touch_frequency" => 7, "stay_in_touch_trigger_date" => nil},
               @today
             )
  end

  test "parse_date/1 accepts every shape Monica has sent" do
    assert ReminderMapper.parse_date("2026-07-04T00:00:00Z") == ~D[2026-07-04]
    assert ReminderMapper.parse_date("2026-07-04") == ~D[2026-07-04]
    assert ReminderMapper.parse_date("2026-07-04 00:00:00") == ~D[2026-07-04]

    assert ReminderMapper.parse_date(%{"date" => "2026-07-04 00:00:00", "timezone" => "UTC"}) ==
             ~D[2026-07-04]

    assert ReminderMapper.parse_date(nil) == nil
    assert ReminderMapper.parse_date("soon") == nil
  end
end
