defmodule Kith.Imports.Monica.ReminderMapper do
  @moduledoc """
  Decides what a Monica 4.1.2 reminder becomes in Kith. Pure: no Repo access.

  Rules (design spec 2026-10-14 §4), checked in order:

    * unknown `frequency_type` or unparseable `initial_date` → `{:skip, reason}`
    * yearly, every 1 year, on the contact's birthday (month-day) → `:birthday`
    * yearly, every 1 year, on the contact's first-met day → `:first_met`
    * week/month/year every N ≥ 1 → a `recurring` reminder anchored on `initial_date`
    * one-time, or N ≤ 0 → a `one_time` reminder on `initial_date`, inactive when
      that date is before `today`

  Monica 4.1.2 sends no `next_expected_date` and no birthday flag, so the
  schedule is rebuilt from `initial_date` and Kith's own calendar maths.
  """

  @frequency_types ~w(one_time week month year)

  @type decision ::
          :birthday
          | :first_met
          | {:create, map(), [atom()]}
          | {:skip, :unknown_frequency | :unparseable_date}

  @spec map(map(), map(), Date.t()) :: decision()
  def map(reminder, contact, %Date{} = today) do
    type = reminder["frequency_type"]
    count = to_int(reminder["frequency_number"])
    date = parse_date(reminder["initial_date"])

    cond do
      type not in @frequency_types ->
        {:skip, :unknown_frequency}

      is_nil(date) ->
        {:skip, :unparseable_date}

      yearly_on?(type, count, date, contact[:birthdate]) ->
        :birthday

      yearly_on?(type, count, date, contact[:first_met_at]) ->
        :first_met

      type != "one_time" and is_integer(count) and count >= 1 ->
        recurring(reminder, type, count, date)

      true ->
        one_time(reminder, type, date, today)
    end
  end

  @doc "Monica's per-contact stay-in-touch setting (days) as a Kith reminder."
  @spec stay_in_touch(map(), Date.t()) :: :none | {:create, map(), []}
  def stay_in_touch(api_contact, %Date{} = today) do
    case to_int(api_contact["stay_in_touch_frequency"]) do
      days when is_integer(days) and days > 0 ->
        anchor = parse_date(api_contact["stay_in_touch_trigger_date"]) || Date.add(today, days)

        {:create,
         %{
           "type" => "stay_in_touch",
           "title" => nil,
           "description" => nil,
           "anchor_date" => anchor,
           "interval_unit" => "day",
           "interval_count" => days,
           "active" => true
         }, []}

      _ ->
        :none
    end
  end

  @doc "Parses every date shape Monica has been seen to send; nil otherwise."
  @spec parse_date(term()) :: Date.t() | nil
  def parse_date(%{"date" => d}), do: parse_date(d)

  def parse_date(str) when is_binary(str) do
    with :error <- from_iso_date(str),
         :error <- from_iso_datetime(str),
         :error <- from_naive_datetime(str),
         do: nil
  end

  def parse_date(_), do: nil

  defp from_iso_date(str) do
    case Date.from_iso8601(str) do
      {:ok, d} -> d
      _ -> :error
    end
  end

  defp from_iso_datetime(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} -> DateTime.to_date(dt)
      _ -> :error
    end
  end

  defp from_naive_datetime(str) do
    case NaiveDateTime.from_iso8601(str) do
      {:ok, ndt} -> NaiveDateTime.to_date(ndt)
      _ -> :error
    end
  end

  defp yearly_on?("year", 1, %Date{} = date, %Date{} = target),
    do: {date.month, date.day} == {target.month, target.day}

  defp yearly_on?(_type, _count, _date, _target), do: false

  defp recurring(reminder, unit, count, date) do
    attrs =
      Map.merge(base(reminder, date), %{
        "type" => "recurring",
        "interval_unit" => unit,
        "interval_count" => count,
        "active" => true
      })

    {:create, attrs, []}
  end

  defp one_time(reminder, type, date, today) do
    notes = if type == "one_time", do: [], else: [:non_positive_interval]

    attrs =
      Map.merge(base(reminder, date), %{
        "type" => "one_time",
        "interval_unit" => nil,
        "interval_count" => nil,
        "active" => Date.compare(date, today) != :lt
      })

    {:create, attrs, notes}
  end

  defp base(reminder, date) do
    %{
      "title" => title(reminder["title"]),
      "description" => blank_to_nil(reminder["description"]),
      "anchor_date" => date
    }
  end

  defp title(t) when is_binary(t), do: if(String.trim(t) == "", do: "Imported reminder", else: t)
  defp title(_), do: "Imported reminder"

  defp blank_to_nil(s) when is_binary(s), do: if(String.trim(s) == "", do: nil, else: s)
  defp blank_to_nil(_), do: nil

  defp to_int(n) when is_integer(n), do: n

  defp to_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp to_int(_), do: nil
end
