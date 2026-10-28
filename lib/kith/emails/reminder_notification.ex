defmodule Kith.Emails.ReminderNotification do
  @moduledoc """
  Contact-focused reminder emails. Requires the instance's account and
  reminder/contact associations to be preloaded; rendering performs no queries.
  """

  alias Kith.Emails
  alias Kith.Emails.Template
  alias Kith.TimeHelper

  @doc "Builds a reminder email using its occurrence date and the account's local day."
  def build(user, instance, opts \\ []) do
    reminder = instance.reminder
    name = contact_name(reminder.contact)
    today = local_today(instance.account.timezone, Keyword.get(opts, :now, DateTime.utc_now()))
    locale = Map.get(user, :locale) || "en"
    date = formatted_date(instance.occurrence_date, locale, :long)
    weekday = formatted_date(instance.occurrence_date, locale, "EEEE")
    relative = relative_date(instance.occurrence_date, today)
    event = event(reminder.type, reminder.title)
    url = KithWeb.Endpoint.url() <> "/contacts/#{reminder.contact.id}"
    subject = subject(reminder.type, instance.kind, instance.days_before, name, reminder.title)
    note = nonblank(reminder.description)

    content =
      content(%{
        name: name,
        event: event,
        date: date,
        weekday: weekday,
        relative: relative,
        date_label: date_label(reminder.type),
        note: note,
        url: url
      })

    text = """
    #{subject}

    Contact: #{name}
    #{event}
    #{date_label(reminder.type)}: #{date}
    #{weekday} · #{relative}
    #{text_note(note)}
    View #{name}'s profile:
    #{url}
    """

    Emails.compose(user, subject, content, text,
      preheader: "#{name} · #{event} · #{date} · #{relative}.",
      footer: "You set this reminder in Kith."
    )
  end

  defp content(assigns) do
    colors = Template.colors()

    """
    <p style="margin:0 0 20px;color:#{colors.tertiary};font-size:11px;
      font-weight:600;letter-spacing:1px;">REMINDER</p>
    <table role="presentation" width="100%" cellspacing="0" cellpadding="0"
      style="table-layout:fixed;"><tr>
      <td width="62" valign="top">
        <table role="presentation" cellspacing="0" cellpadding="0"><tr>
          <td width="46" height="46" align="center" style="background:#{colors.accent_subtle};
            border:1px solid #{colors.subtle_border};border-radius:23px;
            color:#{colors.accent};font-size:14px;font-weight:700;">
            #{Template.escape(initials(assigns.name))}
          </td>
        </tr></table>
      </td>
      <td style="word-break:break-word;overflow-wrap:anywhere;">
        <h1 style="margin:0;color:#{colors.text};font-size:28px;line-height:1.25;
          font-weight:600;letter-spacing:-0.8px;word-break:break-word;overflow-wrap:anywhere;">
          #{Template.escape(assigns.name)}
        </h1>
        <p style="margin:7px 0 0;color:#{colors.secondary};font-size:16px;line-height:1.5;
          word-break:break-word;overflow-wrap:anywhere;">
          #{Template.escape(assigns.event)}
        </p>
      </td>
    </tr></table>
    <table role="presentation" width="100%" cellspacing="0" cellpadding="0"
      style="margin-top:24px;background:#{colors.accent_subtle};border-radius:6px;
        table-layout:fixed;"><tr>
      <td style="padding:20px;border-left:3px solid #{colors.accent};">
        <p style="margin:0 0 10px;color:#{colors.secondary};font-size:11px;font-weight:600;">
          #{Template.escape(String.upcase(assigns.date_label))}
        </p>
        <p style="margin:0;color:#{colors.text};font-size:23px;font-weight:600;line-height:1.35;
          word-break:break-word;overflow-wrap:anywhere;">
          #{Template.escape(assigns.date)}
        </p>
        <p style="margin:8px 0 0;color:#{colors.secondary};font-size:13px;line-height:1.6;">
          #{Template.escape(assigns.weekday)} &nbsp;·&nbsp;
          <strong>#{Template.escape(assigns.relative)}</strong>
        </p>
      </td>
    </tr></table>
    #{html_note(assigns.note, colors)}
    #{Template.button("View #{assigns.name}’s profile", assigns.url)}
    """
  end

  defp html_note(nil, _colors), do: ""

  defp html_note(note, colors) do
    escaped_note = note |> Template.escape() |> String.replace("\n", "<br>")

    """
    <div style="margin-top:24px;word-break:break-word;overflow-wrap:anywhere;">
      <p style="margin:0 0 7px;font-size:11px;color:#{colors.tertiary};font-weight:600;">YOUR NOTE</p>
      <p style="margin:0;font-size:14px;color:#{colors.secondary};line-height:1.7;
        word-break:break-word;overflow-wrap:anywhere;">#{escaped_note}</p>
    </div>
    """
  end

  defp text_note(nil), do: ""
  defp text_note(note), do: "\nYour note:\n#{note}\n"

  defp local_today(timezone, now) do
    {today, _hour} = TimeHelper.local_date_hour(now, timezone)
    today
  end

  defp relative_date(date, today) do
    case Date.diff(date, today) do
      0 -> "Today"
      1 -> "In 1 day"
      days when days > 1 -> "In #{days} days"
      -1 -> "Overdue by 1 day"
      days -> "Overdue by #{abs(days)} days"
    end
  end

  defp formatted_date(date, locale, format) do
    case Kith.Cldr.Date.to_string(date, locale: locale, format: format) do
      {:ok, formatted} -> formatted
      _ -> Date.to_iso8601(date)
    end
  end

  defp contact_name(contact) do
    nonblank(contact.display_name) || nonblank(contact.first_name) || "Your contact"
  end

  defp nonblank(nil), do: nil

  defp nonblank(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp initials(name) do
    parts = String.split(name)

    parts
    |> initial_parts()
    |> Enum.map_join(&String.first/1)
    |> String.upcase()
  end

  defp initial_parts([single]), do: [single]
  defp initial_parts(parts), do: [List.first(parts), List.last(parts)]

  defp event("birthday", _title), do: "Birthday"
  defp event("first_met", _title), do: "First-met anniversary"
  defp event("stay_in_touch", _title), do: "Stay in touch"
  defp event(_type, title), do: nonblank(title) || "Untitled reminder"

  defp date_label("birthday"), do: "Birthday date"
  defp date_label("first_met"), do: "Anniversary date"
  defp date_label("stay_in_touch"), do: "Reach out by"
  defp date_label(_type), do: "Due date"

  defp subject("birthday", "on_day", _days, name, _title), do: "#{name}'s birthday is today"

  defp subject("birthday", "advance", days, name, _title),
    do: "#{name}'s birthday is in #{days} days"

  defp subject("first_met", _kind, _days, name, _title), do: "Anniversary of meeting #{name}"
  defp subject("stay_in_touch", _kind, _days, name, _title), do: "Time to reach out to #{name}"

  defp subject("one_time", "advance", days, _name, title),
    do: "Reminder in #{days} days: #{title}"

  defp subject(_type, _kind, _days, _name, title), do: "Reminder: #{title || "Untitled"}"
end
