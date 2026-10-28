defmodule Mix.Tasks.Kith.Email.Preview do
  @shortdoc "Renders all 12 email variants with fictional data; optionally sends to local Mailpit"
  @moduledoc """
  Generates previews from the production email builders without creating accounts or reminders.

      mix kith.email.preview
      mix kith.email.preview --output /tmp/kith-emails --mailpit

  Output defaults to the system temporary directory's `kith-email-previews` folder.
  `--mailpit` delivers only to localhost SMTP (port 1025 by default, or `--smtp-port`).
  The configured production mail adapter is never used. Run only in dev or test.
  """
  use Mix.Task

  alias Kith.Emails
  alias Kith.Emails.ReminderNotification
  alias Phoenix.HTML
  alias Swoosh.Adapters.SMTP
  alias Swoosh.Attachment

  @impl Mix.Task
  def run(argv) do
    if Mix.env() == :prod, do: Mix.raise("Email previews are available only in dev or test")

    {opts, _} =
      OptionParser.parse!(argv, strict: [output: :string, mailpit: :boolean, smtp_port: :integer])

    # Previewing must not dispatch existing background jobs from the development database.
    Application.put_env(
      :kith,
      Oban,
      Keyword.put(Application.get_env(:kith, Oban, []), :testing, :manual)
    )

    Mix.Task.run("app.start")

    directory = opts[:output] || Path.join(System.tmp_dir!(), "kith-email-previews")
    File.mkdir_p!(directory)
    emails = samples()
    Enum.each(emails, &write_preview(&1, directory, opts))
    write_index(emails, directory)
    Mix.shell().info("Rendered #{length(emails)} emails: #{Path.join(directory, "index.html")}")
  end

  defp samples do
    user = %{email: "preview@example.test", locale: "en"}
    base_url = KithWeb.Endpoint.url()

    account_emails = [
      {"confirmation",
       Emails.email_verification(user, base_url <> "/users/confirm/sample-token")},
      {"password-reset",
       Emails.password_reset(user, base_url <> "/users/reset-password/sample-token")},
      {"email-change",
       Emails.email_change(user, base_url <> "/users/settings/confirm-email/sample-token")},
      {"invitation",
       Emails.invitation(user.email, %{
         account_name: "The Morgan Family",
         inviter_name: "Alex Morgan",
         role: "editor",
         accept_url: base_url <> "/invitations/sample-token"
       })}
    ]

    library_emails = [
      {"welcome", Emails.welcome(user)},
      {"export", Emails.data_export_ready(user, base_url <> "/export/sample-download-token")}
    ]

    account_emails ++ reminder_samples(user) ++ library_emails
  end

  defp reminder_samples(user) do
    variants = [
      {"birthday-today", "birthday", "on_day", 0, ~D[2026-10-28], nil, "Call after work."},
      {"birthday-upcoming", "birthday", "advance", 7, ~D[2026-11-04], nil,
       "Find a book they’ll love."},
      {"first-met", "first_met", "on_day", 0, ~D[2026-10-28], nil, "We met at Maya’s dinner."},
      {"stay-in-touch", "stay_in_touch", "on_day", 0, ~D[2026-10-28], nil,
       "Ask how the new job is going."},
      {"reminder-upcoming", "one_time", "advance", 3, ~D[2026-10-31], "Catch up over coffee",
       "Try Oak Street."},
      {"reminder-due", "one_time", "on_day", 0, ~D[2026-10-28], "Catch up over coffee",
       "Try Oak Street."}
    ]

    Enum.map(variants, fn {id, type, kind, days, date, title, description} ->
      instance = %{
        occurrence_date: date,
        kind: kind,
        days_before: days,
        account: %{timezone: "Etc/UTC"},
        reminder: %{
          type: type,
          title: title,
          description: description,
          contact: %{id: 42, first_name: "Sam", display_name: "Sam Rivera"}
        }
      }

      {id, ReminderNotification.build(user, instance, now: ~U[2026-10-28 12:00:00Z])}
    end)
  end

  defp write_preview({id, email}, directory, opts) do
    html =
      Enum.reduce(email.attachments, email.html_body, fn attachment, html ->
        image =
          "data:#{attachment.content_type};base64,#{Base.encode64(Attachment.get_content(attachment))}"

        String.replace(html, "cid:#{attachment.cid}", image)
      end)

    File.write!(Path.join(directory, "#{id}.html"), html)
    File.write!(Path.join(directory, "#{id}.txt"), email.text_body)

    if opts[:mailpit] do
      config = [
        relay: "localhost",
        port: opts[:smtp_port] || 1025,
        ssl: false,
        tls: :never,
        auth: :never
      ]

      case SMTP.deliver(email, config) do
        {:ok, _} -> :ok
        {:error, reason} -> Mix.raise("Local Mailpit delivery failed: #{inspect(reason)}")
      end
    end
  end

  defp write_index(emails, directory) do
    links =
      Enum.map_join(emails, "\n", fn {id, email} ->
        subject = HTML.html_escape(email.subject) |> HTML.safe_to_string()
        ~s(<li><a href="#{id}.html">#{subject}</a> · <a href="#{id}.txt">Plain text</a></li>)
      end)

    File.write!(Path.join(directory, "index.html"), """
    <!doctype html><html lang="en"><meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1">
    <title>Kith email previews</title>
    <body style="font-family:Arial,sans-serif;max-width:760px;margin:32px auto;padding:0 16px;color:#1c1917;">
    <h1>Kith email previews</h1>
    <p>Production builders with fictional data. Sample reminder send date: 28 October 2026.</p>
    <ul style="line-height:2;">#{links}</ul></body></html>
    """)
  end
end
