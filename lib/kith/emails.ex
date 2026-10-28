defmodule Kith.Emails do
  @moduledoc """
  Branded transactional email builders with HTML and plain-text alternatives.

  Delivery stays with the account notifier and reminder worker. Welcome and
  export builders are available for integrations but do not enable new sends.
  """

  import Swoosh.Email

  alias Kith.Emails.Template
  alias Swoosh.Attachment

  @default_footer "Sent by Kith for your account."

  @doc "Builds an email around trusted component HTML and attaches the inline logo."
  def compose(recipient, subject, content, text, opts \\ []) do
    footer = Keyword.get(opts, :footer, @default_footer)

    new()
    |> to(recipient_address(recipient))
    |> from(from_address())
    |> subject(subject)
    |> html_body(Template.render(content, opts))
    |> text_body(String.trim(text) <> "\n\n" <> footer)
    |> attachment(logo_attachment())
  end

  @doc "Legacy reminder builder for callers supplying a contact, title, and due date."
  def reminder_notification(user, %{
        contact_name: name,
        reminder_title: title,
        due_date: due_date
      }) do
    formatted_date = format_date(due_date, user)
    url = absolute_url("/reminders/upcoming")

    content =
      Template.eyebrow("REMINDER") <>
        Template.heading(name) <>
        Template.paragraph(title) <>
        Template.panel("DUE DATE", formatted_date, "") <>
        Template.button("View reminder", url)

    compose(
      user,
      "Reminder: #{name}",
      content,
      """
      Reminder for #{name}

      #{title}
      Due: #{formatted_date}

      View reminder: #{url}
      """,
      preheader: "#{name} · #{title} · #{formatted_date}",
      footer: "You set this reminder in Kith."
    )
  end

  @doc "Invitation to an account, including the optional assigned role."
  def invitation(
        invitee_email,
        %{
          account_name: account_name,
          inviter_name: inviter_name,
          accept_url: accept_url
        } = attrs
      ) do
    role = Map.get(attrs, :role)
    role_detail = if role, do: " · Role: #{role}", else: ""
    footer = "You received this invitation from #{inviter_name} via Kith."

    note =
      "This invitation expires in 7 days. If you weren’t expecting it, you can ignore this email."

    action_email(invitee_email, %{
      subject: "You've been invited to #{account_name}",
      eyebrow: "YOU’RE INVITED",
      title: "You’re invited to join",
      body: "#{inviter_name} has invited you to join #{account_name} on Kith.",
      panel: {"YOUR INVITATION", account_name, "Invited by #{inviter_name}#{role_detail}"},
      action: "Accept invitation",
      url: accept_url,
      note: note,
      footer: footer,
      preheader: "#{inviter_name} invited you to #{account_name}#{role_detail}."
    })
  end

  @doc "Welcome design; no registration delivery trigger is enabled by this builder."
  def welcome(user) do
    url = absolute_url("/contacts/new")

    content =
      Template.eyebrow("WELCOME TO KITH") <>
        Template.heading("Welcome to Kith") <>
        Template.paragraph(
          "Keep track of the people who matter, your conversations, and when to get back in touch."
        ) <>
        Template.steps([
          {"Add a contact", "Save the details you want to remember."},
          {"Set a reminder", "Choose when to get back in touch."},
          {"Save a note", "Keep track of your conversations."}
        ]) <>
        Template.button("Add your first contact", url)

    compose(
      user,
      "Welcome to Kith",
      content,
      """
      Welcome to Kith

      Getting Started:
      1. Add a contact. Save the details you want to remember.
      2. Set a reminder. Choose when to get back in touch.
      3. Save a note. Keep track of your conversations.

      Add your first contact: #{url}
      """,
      preheader: "Add your first contact and set a reminder."
    )
  end

  @doc "Account confirmation, matching the seven-day confirmation token lifetime."
  def email_verification(user, url) do
    action_email(user, %{
      subject: "Verify your email",
      eyebrow: "EMAIL CONFIRMATION",
      title: "Confirm your email address",
      body: "Thanks for creating your Kith account. Confirm your email address to get started.",
      action: "Confirm email address",
      url: url,
      note:
        "This link is valid for 7 days. If you didn’t create a Kith account, you can ignore this email.",
      preheader: "Confirm your email address to get started with Kith."
    })
  end

  @doc "Password reset with the enforced one-hour token lifetime."
  def password_reset(user, url) do
    action_email(user, %{
      subject: "Reset your password",
      eyebrow: "ACCOUNT SECURITY",
      title: "Reset your password",
      body:
        "We received a request to reset your Kith password. Choose a new password using the button below.",
      action: "Reset password",
      url: url,
      note:
        "This link expires in 1 hour. If you didn’t request a reset, ignore this email. Your password will stay the same.",
      preheader: "Reset your Kith password. This link expires in 1 hour."
    })
  end

  @doc "Confirmation sent to a proposed new email address."
  def email_change(user, url) do
    action_email(user, %{
      subject: "Update email instructions",
      eyebrow: "ACCOUNT SECURITY",
      title: "Confirm your new email address",
      body:
        "You asked to use this email address for your Kith account. Confirm the change below to finish updating your account.",
      action: "Confirm new email",
      url: url,
      note:
        "This link is valid for 7 days. If you didn’t request this change, ignore this email. Your account email will stay the same.",
      preheader: "One more step to update your Kith email address."
    })
  end

  @doc "Export design; download delivery remains an integration responsibility."
  def data_export_ready(user, url) do
    action_email(user, %{
      subject: "Your data export is ready",
      eyebrow: "DATA EXPORT",
      title: "Your export is ready",
      body: "Your Kith data export is ready to download. Keep a copy for your records.",
      panel:
        {"YOUR EXPORT", "Kith account data", "JSON format · Keep your download somewhere safe"},
      action: "Download export",
      url: url,
      note:
        "This download is available for 24 hours. After that, request a new export from your account settings.",
      preheader: "Your Kith data export is ready. Download your copy."
    })
  end

  @doc "Resolves application-relative URLs against this instance's configured endpoint."
  def absolute_url("/" <> path) do
    KithWeb.Endpoint.url() <> "/" <> path
  end

  def absolute_url(url), do: url

  defp action_email(recipient, attrs) do
    url = absolute_url(attrs.url)
    panel = Map.get(attrs, :panel)
    panel_html = if panel, do: apply(Template, :panel, Tuple.to_list(panel)), else: ""
    panel_text = if panel, do: panel |> Tuple.to_list() |> Enum.join("\n"), else: ""

    content =
      Template.eyebrow(attrs.eyebrow) <>
        Template.heading(attrs.title) <>
        Template.paragraph(attrs.body) <>
        panel_html <>
        Template.button(attrs.action, url) <>
        Template.note(attrs.note) <>
        Template.fallback_link(url)

    compose(
      recipient,
      attrs.subject,
      content,
      """
      #{attrs.title}

      #{attrs.body}

      #{panel_text}

      #{attrs.action}: #{url}

      #{attrs.note}
      """,
      preheader: attrs.preheader,
      footer: Map.get(attrs, :footer, @default_footer)
    )
  end

  defp recipient_address(%{email: email}), do: {email, email}
  defp recipient_address(email), do: email

  defp from_address do
    case Application.get_env(:kith, Kith.Mailer, []) |> Keyword.get(:from) do
      nil -> {"Kith", "noreply@localhost"}
      address when is_binary(address) -> {"Kith", address}
      {name, address} -> {name, address}
    end
  end

  defp logo_attachment do
    :kith
    |> Application.app_dir("priv/static/images/email-logo.png")
    |> Attachment.new(
      filename: "kith-logo.png",
      content_type: "image/png",
      type: :inline,
      cid: "kith-logo.png"
    )
  end

  defp format_date(date, user) do
    locale = Map.get(user, :locale, "en") || "en"

    case Kith.Cldr.Date.to_string(date, locale: locale, format: :long) do
      {:ok, formatted} -> formatted
      _ -> to_string(date)
    end
  end
end
