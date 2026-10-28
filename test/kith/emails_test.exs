defmodule Kith.EmailsTest do
  use ExUnit.Case, async: false

  alias Kith.Emails
  alias Kith.Emails.Template
  alias Swoosh.Attachment

  defp test_user, do: %{email: "user@example.com", locale: "en"}

  test "legacy reminder puts the contact, title, and date in both alternatives" do
    email =
      Emails.reminder_notification(test_user(), %{
        contact_name: "Alice Smith",
        reminder_title: "Call her back",
        due_date: ~D[2026-03-20]
      })

    assert email.subject == "Reminder: Alice Smith"
    assert email.to == [{"user@example.com", "user@example.com"}]

    for body <- [email.html_body, email.text_body] do
      assert body =~ "Alice Smith"
      assert body =~ "Call her back"
      assert body =~ "2026"
      assert body =~ "March"
    end
  end

  test "invitation includes its account and optional role without claiming invitee has an account" do
    email =
      Emails.invitation("invitee@example.com", %{
        account_name: "Team Kith",
        inviter_name: "Bob",
        role: "editor",
        accept_url: "https://kith.example.com/accept/abc123"
      })

    assert email.subject == "You've been invited to Team Kith"

    for body <- [email.html_body, email.text_body] do
      assert body =~ "Bob"
      assert body =~ "Team Kith"
      assert body =~ "editor"
      assert body =~ "accept/abc123"
      assert body =~ "7 days"
      refute body =~ "because you have a Kith account"
    end
  end

  test "invitation without a role remains supported" do
    email =
      Emails.invitation("invitee@example.com", %{
        account_name: "Team Kith",
        inviter_name: "Bob",
        accept_url: "/invitations/token"
      })

    refute email.text_body =~ "Role:"
    assert email.text_body =~ KithWeb.Endpoint.url() <> "/invitations/token"
  end

  test "welcome links to this instance and provides getting started steps" do
    email = Emails.welcome(test_user())
    assert email.subject == "Welcome to Kith"
    assert email.html_body =~ "Getting Started"
    assert email.text_body =~ "Getting Started"
    assert email.html_body =~ KithWeb.Endpoint.url() <> "/contacts/new"
  end

  test "confirmation copy agrees with the actual seven-day token lifetime" do
    email = Emails.email_verification(test_user(), "/verify/token123")
    assert email.subject == "Verify your email"

    for body <- [email.html_body, email.text_body] do
      assert body =~ "verify/token123"
      assert body =~ "7 days"
      refute body =~ "24 hours"
    end
  end

  test "password reset includes its link, expiry, and unchanged-password reassurance" do
    email = Emails.password_reset(test_user(), "/reset/token456")
    assert email.subject == "Reset your password"

    for body <- [email.html_body, email.text_body] do
      assert body =~ "reset/token456"
      assert body =~ "1 hour"
      assert body =~ "Your password will stay the same"
    end
  end

  test "email change addresses the new address and explains its expiry" do
    email = Emails.email_change(%{email: "new@example.com"}, "/email/change-token")
    assert email.to == [{"new@example.com", "new@example.com"}]
    assert email.subject == "Update email instructions"

    for body <- [email.html_body, email.text_body] do
      assert body =~ "email/change-token"
      assert body =~ "7 days"
      assert body =~ "Your account email will stay the same"
    end
  end

  test "export design matches the worker cache's 24-hour lifetime" do
    email = Emails.data_export_ready(test_user(), "https://kith.example.com/export/dl/abc")
    assert email.subject == "Your data export is ready"

    for body <- [email.html_body, email.text_body] do
      assert body =~ "export/dl/abc"
      assert body =~ "24 hours"
      refute body =~ "48 hours"
    end
  end

  test "every builder includes a real inline PNG matching the HTML CID" do
    emails = [
      Emails.welcome(test_user()),
      Emails.email_verification(test_user(), "/verify/token"),
      Emails.password_reset(test_user(), "/reset/token"),
      Emails.email_change(test_user(), "/email/token"),
      Emails.data_export_ready(test_user(), "/export/token"),
      Emails.invitation("invitee@example.com", %{
        account_name: "Team",
        inviter_name: "Alex",
        accept_url: "/invite/token"
      }),
      Emails.reminder_notification(test_user(), %{
        contact_name: "Sam",
        reminder_title: "Coffee",
        due_date: ~D[2026-10-28]
      })
    ]

    for email <- emails do
      assert [%Attachment{type: :inline, cid: "kith-logo.png", content_type: "image/png"} = logo] =
               email.attachments

      assert Attachment.get_content(logo) =~ <<137, 80, 78, 71, 13, 10, 26, 10>>
      assert email.html_body =~ "cid:kith-logo.png"
      assert email.html_body =~ "Kith"
      assert email.html_body =~ "#d25900"
      assert email.html_body =~ "#fbfaf7"
      refute email.html_body =~ "data:image"
      refute email.html_body =~ "<style>"
      assert is_binary(email.text_body)
    end
  end

  test "user-controlled text and URL attributes are escaped in HTML" do
    email =
      Emails.invitation("invitee@example.com", %{
        account_name: "<script>alert('xss')</script>",
        inviter_name: "Bob & Alice",
        role: "<b>editor</b>",
        accept_url: "https://kith.example/invite?value=\" onclick=\"evil&other=1"
      })

    refute email.html_body =~ "<script>"
    refute email.html_body =~ "<b>editor</b>"
    refute email.html_body =~ ~s(value=" onclick=")
    assert email.html_body =~ "&lt;script&gt;"
    assert email.html_body =~ "Bob &amp; Alice"
    assert email.html_body =~ "&lt;b&gt;editor&lt;/b&gt;"
    assert email.html_body =~ "&quot; onclick=&quot;evil&amp;other=1"
    assert email.text_body =~ "Bob & Alice"
  end

  test "compose escapes preheader and footer while leaving trusted component content intact" do
    email =
      Emails.compose("user@example.com", "Test", Template.heading("Header"), "Text",
        preheader: "<script>bad</script>",
        footer: "<b>footer</b>"
      )

    assert email.html_body =~ "<h1"
    assert email.html_body =~ "&lt;script&gt;bad&lt;/script&gt;"
    assert email.html_body =~ "&lt;b&gt;footer&lt;/b&gt;"
    assert email.text_body =~ "<b>footer</b>"
  end

  test "long unbroken user content remains intact in every dynamic component" do
    name = String.duplicate("LongContactName", 30)
    url = "https://kith.example/invite/" <> String.duplicate("token", 100)

    content =
      Template.heading(name) <>
        Template.paragraph(name) <>
        Template.panel(name, name, name) <>
        Template.button("View #{name}’s profile", url) <>
        Template.fallback_link(url)

    email = Emails.compose("user@example.com", "Test", content, name, footer: name)

    assert email.html_body =~ "View #{name}’s profile"
    assert email.html_body =~ url
    assert email.text_body =~ name
    assert email.html_body =~ "word-break:break-word;overflow-wrap:anywhere;"
    assert email.html_body =~ "table-layout:fixed;"
  end

  test "configured sender supports both string and named tuple forms" do
    original = Application.get_env(:kith, Kith.Mailer, [])
    on_exit(fn -> Application.put_env(:kith, Kith.Mailer, original) end)

    Application.put_env(:kith, Kith.Mailer, Keyword.put(original, :from, "mail@example.com"))
    assert Emails.welcome(test_user()).from == {"Kith", "mail@example.com"}

    Application.put_env(
      :kith,
      Kith.Mailer,
      Keyword.put(original, :from, {"My Kith", "team@example.com"})
    )

    assert Emails.welcome(test_user()).from == {"My Kith", "team@example.com"}

    Application.put_env(:kith, Kith.Mailer, Keyword.delete(original, :from))
    assert Emails.welcome(test_user()).from == {"Kith", "noreply@localhost"}
  end
end
