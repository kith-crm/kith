# Phone Display Format Fix — Design

**Date:** 2026-05-16
**Status:** Draft
**Branch base:** `feat/v0.x-multi-area-improvements` (PR #23)

## Problem

The account-level `phone_format` setting (`e164` / `national` / `international` / `raw`,
default `e164`) is read at render time in
`KithWeb.ContactLive.ContactFieldsComponent`, which delegates display formatting
to `Kith.Contacts.PhoneFormatter.format/2`. The current implementation of
`format/2` only formats numbers in the NANP region (country code `+1`) via a
hand-rolled binary pattern at `lib/kith/contacts/phone_formatter.ex:176-192`.
Every non-NANP phone (French `+33…`, German `+49…`, Saudi `+966…`, Japanese
`+81…`, etc.) silently falls through the catch-all clause and renders unchanged
as raw E.164.

User-visible symptom (the reported one): after importing French/EU contacts
from Monica, a user sets *Phone Number Format → National* in Account Settings
and still sees `+33123456789` everywhere instead of `01 23 45 67 89`. From the
user's perspective the account setting is silently ignored.

## Goal

Make `account.phone_format` honor the user's preference for **every parseable
stored phone**, regardless of country, using the `ExPhoneNumber` library
(libphonenumber port) that the codebase already depends on.

## Non-Goals

- No changes to storage. E.164 remains the canonical storage form.
- No changes to write paths. vCard import, CardDAV PUT, REST API
  `ContactFieldController`, and manual-edit normalization gaps are real
  but tracked separately.
- No new account schema fields. No promotion of "phone default region" to a
  first-class setting.
- No changes to the Account Settings UI copy.
- No re-normalization or backfill of existing data — this is a pure display
  change.

## Design

### Single change point

`Kith.Contacts.PhoneFormatter.format/2` in
`lib/kith/contacts/phone_formatter.ex`.

The hand-rolled NANP pattern matches at lines 176-192 (`format_national/1`,
`format_international/1`) are deleted. All four format heads remain as
public clauses with new behavior:

```
format(nil, _)              -> nil
format("",  _)              -> nil          # new — currently undefined
format(v,   "raw")          -> v             # unchanged
format(v,   "e164")         -> v             # unchanged
format(v,   "national")     -> render(v, :national)
format(v,   "international")-> render(v, :international)
format(v,   _other)         -> v             # unchanged — defensive catch-all
```

`render/2` (private):

```elixir
defp render(value, library_format) do
  case ExPhoneNumber.parse(value, nil) do
    {:ok, parsed} -> ExPhoneNumber.format(parsed, library_format)
    {:error, _}   -> value
  end
end
```

- `ExPhoneNumber.parse(value, nil)` passes `nil` as the default region. Stored
  values are E.164 with a `+` prefix, so the parser uses the carried country
  code and produces a `PhoneNumber` struct that knows its own country. No
  account-level region is consulted at display time.
- `ExPhoneNumber.format/2` accepts the format-type atoms `:e164`, `:national`,
  `:international`, `:rfc3966`. We use `:national` and `:international`.
- On parse failure (legacy bare numbers like `"5551234567"` written before
  the normalization work in PR #23, or truly garbage input), return the
  stored value unchanged. This matches the existing
  `PhoneFormatter.normalize/2` philosophy of never destroying user data.

### What gets deleted

- `defp format_national/1` head with the NANP-only binary pattern
- `defp format_national(phone), do: phone` fallback
- `defp format_international/1` head with the NANP-only binary pattern
- `defp format_international(phone), do: phone` fallback

Total: ~16 lines removed.

### What stays

- `PhoneFormatter.normalize/1`, `normalize/2` — storage canonicalization. Untouched.
- `PhoneFormatter.region_for_locale/1` — locale→region mapping used by Monica
  wizard and `PhoneRenormalizeWorker`. Untouched.
- `PhoneFormatter.supported_regions/1` — wizard dropdown source. Untouched.
- The `"raw"` and `"e164"` heads of `format/2` — pass-through. Untouched.

### Surface-area audit

A repo-wide `grep` confirms that phone display goes through exactly one path:

```
lib/kith_web/live/contact_live/contact_fields_component.ex:101
  PhoneFormatter.format(field.value, phone_format)
```

invoked from `show.html.heex:288` and `show.html.heex:417` (contact-show page,
both desktop and mobile layouts). No other LiveView or controller renders a
phone number through human-facing UI today.

The REST API (`contact_json.ex:113`) returns `cf.value` raw — this is correct
behavior for an API contract and is **not** changed.

A moduledoc note will be added to `PhoneFormatter` warning future contributors
that any new UI surface displaying a phone must call `format/2` with the
account's `phone_format`.

## Test Plan

**File:** `test/kith/contacts/phone_formatter_test.exs` (exists; has a
`describe "format/2"` block at lines 136-164).

**Tests to replace** (these currently encode the bug as expected behavior):

- Line 153-155 — `"national falls back for non-US numbers"` asserts
  `format("+442079460958", "national") == "+442079460958"`. Replace with an
  assertion that the GB national format is produced (exact string verified
  against `ExPhoneNumber.format/2` output during implementation).
- Line 157-159 — `"international falls back for non-US numbers"` asserts
  unchanged output. Replace with the proper international rendering.

**Tests to add:** the full coverage matrix below.

**Test to keep:** lines 137-150 (US national/international, e164, raw) — they
remain correct.

Coverage matrix:

| Input value     | `e164`          | `national`        | `international`      | `raw`           |
|-----------------|-----------------|-------------------|----------------------|-----------------|
| `+12025550100`  | `+12025550100`  | `(202) 555-0100`  | `+1 202-555-0100`    | `+12025550100`  |
| `+33123456789`  | `+33123456789`  | `01 23 45 67 89`  | `+33 1 23 45 67 89`  | `+33123456789`  |
| `+493012345678` | `+493012345678` | `030 12345678`    | `+49 30 12345678`    | `+493012345678` |
| `+819012345678` | `+819012345678` | `090-1234-5678`   | `+81 90-1234-5678`   | `+819012345678` |
| `+966501234567` | `+966501234567` | `050 123 4567`    | `+966 50 123 4567`   | `+966501234567` |
| `5551234567`    | `5551234567`    | `5551234567`      | `5551234567`         | `5551234567`    |
| `garbage`       | `garbage`       | `garbage`         | `garbage`            | `garbage`       |
| `nil`           | `nil`           | `nil`             | `nil`                | `nil`           |
| `""`            | `nil`           | `nil`             | `nil`                | `nil`           |

Exact rendered strings for non-US cases will be verified against libphonenumber
output during implementation (libphonenumber's formatting may use NBSP or
different separators per locale; the tests should match what the library
actually produces, not what the spec author guessed).

A regression test will assert that the `ContactFieldsComponent.display_value/2`
private helper returns a properly-formatted national string when given a
French phone and `phone_format: "national"` (component-level test using
ExUnit + LiveView test helpers).

## Risks

- **None to data.** Pure rendering change; storage untouched.
- **Library behavior drift.** If a future version of `ex_phone_number` changes
  its national-format output for any tested locale, the matrix tests will
  catch it. The tests pin behavior.
- **Library raises on edge input.** If `ExPhoneNumber.format/2` ever raises
  (it shouldn't on a successfully-parsed number, but defensive coding helps),
  a `try/rescue` around the library call returning the stored value would be
  added. Initial implementation will not include the rescue; it will be added
  only if a failing case surfaces in test or production telemetry.

## Acceptance Criteria

1. The test matrix above passes.
2. The four-line NANP-only binary-pattern helpers are removed from
   `phone_formatter.ex`.
3. `mix quality` (compile + format + credo + sobelow + dialyzer) passes.
4. Manual smoke check: log in with a test account holding French and US
   phones, switch *Phone Number Format* between `national` and
   `international` in Account Settings, confirm both numbers re-render
   correctly on the contact-show page.
5. PR description references this spec by path.
