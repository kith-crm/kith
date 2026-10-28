# Email Development with Mailpit

## Overview

All emails sent in dev are captured by Mailpit — never delivered externally.

- **Mailpit UI:** http://localhost:8025
- **SMTP:** host `localhost`, port `1025`, no auth

## Configuration

Dev Swoosh config (already in `config/dev.exs`):

```elixir
config :kith, Kith.Mailer,
  adapter: Swoosh.Adapters.SMTP,
  relay: "localhost",
  port: 1025,
  ssl: false,
  tls: :never,
  auth: :never
```

## Clearing the Inbox

Open the Mailpit UI and click the trash icon, or:

```bash
curl -X DELETE http://localhost:8025/api/v1/messages
```

## Branded Email Previews

Render all 12 variants from the actual email builders, using fictional data:

```bash
mix kith.email.preview --output /tmp/kith-email-previews
```

Open `/tmp/kith-email-previews/index.html` to review each HTML email and its
plain-text alternative. Browser previews replace the logo's CID reference with
an embedded PNG; delivered emails use an inline PNG attachment.

To inspect the SMTP message, including the embedded logo, in local Mailpit:

```bash
docker compose -f docker-compose.dev.yml up -d mailpit
mix kith.email.preview --output /tmp/kith-email-previews --mailpit
```

The preview task disables background job execution, does not create accounts or
reminders, and never uses the configured delivery adapter. `--mailpit` connects
only to localhost, port 1025 (`--smtp-port` overrides the port). It is available
in dev and test only. Sample reminder dates use 28 October 2026 as the send date.

The approved design collection is in `docs/design/email-templates/index.html`.
Its Python generator produces reference mockups; the Mix task above exercises
the implementation and should be used when reviewing code changes.

### Verify captured messages

After generating and sending previews with `--mailpit`, verify the actual SMTP
messages using Python's standard library:

```bash
python3 docs/design/email-templates/verify_mailpit.py /tmp/kith-email-previews
```

The verifier selects only fictional `preview@example.test` messages. It compares
the delivered HTML and plain-text parts with the generated files, checks the
inline PNG and CID resolution through Mailpit, and validates absolute action
links. It does not clear the inbox or send messages. Evidence is exported to
`/tmp/kith-mailpit-verification` as `.eml`, HTML, and `mime-results.json` files.

Keep run-specific verification results in PR comments rather than committing
generated evidence. When reviewing the captured messages, check narrow and
desktop widths, light/dark browser preference, and images shown/omitted. Check
for overflow, heading/CTA visibility, logo decoding, and the Kith text fallback.
The ExUnit suite additionally covers optional descriptions, escaping, locales,
and account-local date timing.

Dark browser preference preserves the email's explicit light palette. It does
not reproduce Gmail or Outlook's forced color inversion. Removing image sources
simulates unavailable images, rather than each client's image-blocking UI.
Mailpit is the local SMTP mailbox; MinIO provides object storage and is not
needed for these checks.

### Template ownership and behavior

- `Kith.Emails` builds multipart emails and attaches the logo. `Kith.Emails.Template`
  owns the shared layout and inline style helpers, with sRGB equivalents of the
  light theme's amber/copper and stone tokens in `assets/css/app.css`.
- `Kith.Accounts.UserNotifier` delivers confirmation, password reset, email change,
  and invitation emails while preserving their existing subjects and recipients.
- `Kith.Emails.ReminderNotification` renders contact names, events, and the full
  `ReminderInstance.occurrence_date`. Relative labels use the account's local date,
  including when a delayed job delivers after the event. The optional “Your note”
  section comes from `Reminder.description` and is omitted when blank.
- Welcome and export templates remain builders only. This change does not add
  welcome delivery or complete the export download/delivery integration. The export
  design uses 24-hour copy to match the current export cache lifetime; verify it
  against the eventual download handler when connecting delivery.

Before rollout, check actual messages in the target email clients (including
Outlook, Gmail, and Apple Mail), dark mode, and images disabled. The Kith name
remains visible as text when the logo is unavailable. Browser previews do not
certify rendering in those clients.

## Production Adapters

Set `MAILER_ADAPTER` env var: `smtp` (default), `mailgun`, `ses`, or `postmark`.
See `config/runtime.exs` for required env vars per adapter.
