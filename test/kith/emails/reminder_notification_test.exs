defmodule Kith.Emails.ReminderNotificationTest do
  use ExUnit.Case, async: true

  alias Kith.Emails.ReminderNotification

  @now ~U[2026-10-28 00:30:00Z]

  defp user(locale \\ "en"), do: %{email: "owner@example.com", locale: locale}

  defp instance(attrs \\ %{}) do
    Map.merge(
      %{
        account: %{timezone: "Etc/UTC"},
        occurrence_date: ~D[2026-10-28],
        scheduled_for: ~U[2026-10-28 09:00:00Z],
        kind: "on_day",
        days_before: 0,
        reminder: %{
          type: "one_time",
          title: "Catch up over coffee",
          description: nil,
          contact: %{id: 42, display_name: "Sam Rivera", first_name: "Sam"}
        }
      },
      attrs
    )
  end

  test "all reminder variants preserve subjects and include contact, event and occurrence date" do
    variants = [
      {"birthday", "on_day", 0, "Sam Rivera's birthday is today", "Birthday"},
      {"birthday", "advance", 7, "Sam Rivera's birthday is in 7 days", "Birthday"},
      {"first_met", "on_day", 0, "Anniversary of meeting Sam Rivera", "First-met anniversary"},
      {"stay_in_touch", "on_day", 0, "Time to reach out to Sam Rivera", "Stay in touch"},
      {"one_time", "advance", 3, "Reminder in 3 days: Catch up over coffee",
       "Catch up over coffee"},
      {"one_time", "on_day", 0, "Reminder: Catch up over coffee", "Catch up over coffee"}
    ]

    for {type, kind, days, subject, event} <- variants do
      base = instance()

      email =
        ReminderNotification.build(
          user(),
          %{base | kind: kind, days_before: days, reminder: %{base.reminder | type: type}},
          now: @now
        )

      assert email.subject == subject
      assert email.html_body =~ "Sam Rivera"
      assert email.html_body =~ event
      assert email.html_body =~ "October 28, 2026"
      assert email.html_body =~ "Wednesday"
      assert email.text_body =~ "Contact: Sam Rivera"
      assert email.text_body =~ event
      assert email.text_body =~ "October 28, 2026"
      assert email.html_body =~ KithWeb.Endpoint.url() <> "/contacts/42"
      assert email.text_body =~ KithWeb.Endpoint.url() <> "/contacts/42"
      assert length(String.split(email.text_body, "You set this reminder in Kith.")) == 2
    end
  end

  test "advance notices show the occurrence date rather than the earlier scheduled send" do
    email =
      ReminderNotification.build(
        user(),
        instance(%{occurrence_date: ~D[2026-11-04], kind: "advance", days_before: 7}),
        now: @now
      )

    assert email.html_body =~ "November 4, 2026"
    assert email.html_body =~ "In 7 days"
    assert email.text_body =~ "November 4, 2026"
    refute email.html_body =~ "October 28, 2026"
  end

  test "relative labels use the account-local day near UTC midnight" do
    local_instance = instance(%{account: %{timezone: "America/Los_Angeles"}})
    email = ReminderNotification.build(user(), local_instance, now: @now)
    assert email.html_body =~ "In 1 day"
    assert email.text_body =~ "In 1 day"

    utc_email = ReminderNotification.build(user(), instance(), now: @now)
    assert utc_email.html_body =~ "Today"
  end

  test "a missing account timezone falls back to UTC" do
    email =
      ReminderNotification.build(user(), instance(%{account: %{timezone: nil}}), now: @now)

    assert email.html_body =~ "Today"
    refute email.html_body =~ "In 1 day"
  end

  test "a late retry shows overdue timing rather than claiming the event is today" do
    email = ReminderNotification.build(user(), instance(), now: ~U[2026-10-30 12:00:00Z])
    assert email.html_body =~ "Overdue by 2 days"
    assert email.text_body =~ "Overdue by 2 days"
    refute email.html_body =~ ">Today<"
  end

  test "a description is escaped, preserves line breaks and stays available as plain text" do
    base = instance()
    description = "Call <Sam> & ask about work.\nBring the book."

    email =
      ReminderNotification.build(
        user(),
        %{base | reminder: %{base.reminder | description: description}},
        now: @now
      )

    assert email.html_body =~ "YOUR NOTE"
    assert email.html_body =~ "Call &lt;Sam&gt; &amp; ask about work.<br>Bring the book."
    assert email.text_body =~ description
    refute email.html_body =~ "Call <Sam>"
  end

  test "nil, empty and whitespace-only descriptions omit the note section" do
    for description <- [nil, "", " \n\t "] do
      base = instance()

      email =
        ReminderNotification.build(
          user(),
          %{base | reminder: %{base.reminder | description: description}},
          now: @now
        )

      refute email.html_body =~ "YOUR NOTE"
      refute email.text_body =~ "Your note:"
    end
  end

  test "contact names and reminder titles cannot introduce HTML" do
    base = instance()

    reminder = %{
      base.reminder
      | title: "<img src=x onerror=alert(1)>",
        contact: %{base.reminder.contact | display_name: "<script>Sam</script>"}
    }

    email = ReminderNotification.build(user(), %{base | reminder: reminder}, now: @now)
    assert email.html_body =~ "&lt;script&gt;Sam&lt;/script&gt;"
    assert email.html_body =~ "&lt;img src=x onerror=alert(1)&gt;"
    refute email.html_body =~ "<script>"
    refute email.html_body =~ "<img src=x"
  end

  test "blank names and titles have useful fallbacks" do
    base = instance()

    reminder = %{
      base.reminder
      | title: nil,
        contact: %{base.reminder.contact | display_name: " ", first_name: nil}
    }

    email = ReminderNotification.build(user(), %{base | reminder: reminder}, now: @now)
    assert email.subject == "Reminder: Untitled"
    assert email.html_body =~ "Your contact"
    assert email.html_body =~ "Untitled reminder"
  end

  test "dates use the recipient locale" do
    email = ReminderNotification.build(user("fr"), instance(), now: @now)
    assert email.html_body =~ "28 octobre 2026"
    assert email.text_body =~ "28 octobre 2026"
  end
end
