# Phone Display Format Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `account.phone_format` honor the user's preference for every parseable stored phone, regardless of country, by replacing the hand-rolled NANP-only renderer with `ExPhoneNumber` library calls.

**Architecture:** Pure rendering change to `Kith.Contacts.PhoneFormatter.format/2`. Parses the stored E.164 value (which carries its own country code), then asks `ExPhoneNumber` for the requested format. On parse failure, returns the stored value unchanged so user data is never destroyed. No storage changes, no schema changes, no new account fields.

**Tech Stack:** Elixir, Phoenix LiveView, ExUnit, ExPhoneNumber (libphonenumber port, already a dependency in this branch via `mix.exs`).

**Design spec:** `docs/superpowers/specs/2026-05-16-phone-display-format-fix-design.md`

---

## Pre-flight

These steps assume you are working in the existing `.worktrees/pr-23-review/` worktree on branch `pr-23-review`. If you are landing this as a separate follow-up PR rather than stacked on PR #23, branch off `main` and cherry-pick the design-spec commit first.

- [ ] **Step 0a: Confirm you are in the right worktree**

```bash
pwd
# Expected: /Users/basharqassis/projects/kith/.worktrees/pr-23-review
git branch --show-current
# Expected: pr-23-review (or your fix branch)
```

- [ ] **Step 0b: Fetch dependencies if not already present**

```bash
mix deps.get
```

Expected: `* Getting ex_phone_number (Hex package)` or "All dependencies are up to date" if already fetched.

- [ ] **Step 0c: Verify baseline tests pass for the file you're about to change**

```bash
mix test test/kith/contacts/phone_formatter_test.exs
```

Expected: all current tests pass (including the two that pin the bug — that's the baseline).

---

## Task 1: Discover the exact library output strings for the test matrix

**Why this task exists:** libphonenumber's national/international format strings can include non-breaking spaces (` `), different separator characters, and per-locale conventions. The spec's matrix lists *illustrative* output. Real test assertions must match what `ExPhoneNumber.format/2` actually produces on this version of the library, otherwise tests will fail on string mismatch even when the implementation is correct.

**Files:**
- Read: `lib/kith/contacts/phone_formatter.ex:65-74` (the existing `parse_to_e164` helper — confirms `ExPhoneNumber.parse/2` API)

- [ ] **Step 1.1: Open IEx with the project loaded**

```bash
iex -S mix
```

- [ ] **Step 1.2: Probe each row of the matrix and record exact library output**

Run each of the following at the IEx prompt and **write the actual returned strings into a scratchpad** (a sticky note, a comment in your editor, whatever). You will paste them into the tests in Task 3.

```elixir
alias ExPhoneNumber

# Helper to run both formats for one E.164 input
probe = fn e164 ->
  {:ok, p} = ExPhoneNumber.parse(e164, nil)
  %{
    national: ExPhoneNumber.format(p, :national),
    international: ExPhoneNumber.format(p, :international)
  }
end

probe.("+12025550100")    # US
probe.("+12345678901")    # US (used in existing tests at line 137-150)
probe.("+33123456789")    # FR
probe.("+493012345678")   # DE
probe.("+819012345678")   # JP
probe.("+966501234567")   # SA
probe.("+442079460958")   # GB (used in existing bug-pinning tests at line 153-159)
```

Expected: each call returns `%{national: "...", international: "..."}` with formatted strings. Some strings may include ` ` (NBSP) — copy them **byte-exact**, not "what they look like printed".

- [ ] **Step 1.3: Exit IEx**

```elixir
:init.stop()
```

---

## Task 2: Rewrite `PhoneFormatter.format/2` to use the library

**Files:**
- Modify: `lib/kith/contacts/phone_formatter.ex:169-192`

The current code (lines 169-192) ends like this — these are the lines you replace:

```elixir
def format(nil, _format), do: nil
def format(phone, "raw"), do: phone
def format(phone, "e164"), do: phone
def format(phone, "national"), do: format_national(phone)
def format(phone, "international"), do: format_international(phone)
def format(phone, _), do: phone

defp format_national(
       <<"+"::utf8, ?1, area::binary-size(3), prefix::binary-size(3), line::binary-size(4)>>
     )
     when byte_size(area) == 3 do
  "(#{area}) #{prefix}-#{line}"
end

defp format_national(phone), do: phone

defp format_international(
       <<"+"::utf8, ?1, area::binary-size(3), prefix::binary-size(3), line::binary-size(4)>>
     )
     when byte_size(area) == 3 do
  "+1 #{area}-#{prefix}-#{line}"
end

defp format_international(phone), do: phone
```

- [ ] **Step 2.1: Read the file to anchor the Edit tool**

Open `lib/kith/contacts/phone_formatter.ex` and locate line 169.

- [ ] **Step 2.2: Replace the `format/2` heads and helper privates**

Replace the block at lines 169-192 with this exact code:

```elixir
def format(nil, _format), do: nil
def format("", _format), do: nil
def format(phone, "raw"), do: phone
def format(phone, "e164"), do: phone
def format(phone, "national"), do: render(phone, :national)
def format(phone, "international"), do: render(phone, :international)
def format(phone, _), do: phone

defp render(value, library_format) do
  case ExPhoneNumber.parse(value, nil) do
    {:ok, parsed} -> ExPhoneNumber.format(parsed, library_format)
    {:error, _} -> value
  end
end
```

Notes for the implementer:
- The `format("", _format), do: nil` clause is new. It makes empty input behave like `nil` input, matching the existing `normalize/2` behavior at lines 42-43.
- The `format(phone, _), do: phone` catch-all stays — it covers unknown format strings (defensive against typos/migrations of the `phone_format` field).
- Do **not** rescue exceptions from `ExPhoneNumber.format/2`. The library returns a string for any parsed phone; raising would be a library bug we want to surface, not hide. If telemetry later shows a real production case, add a rescue then.

- [ ] **Step 2.3: Confirm the file still compiles**

```bash
mix compile --warnings-as-errors
```

Expected: clean compile, no warnings.

- [ ] **Step 2.4: Confirm `mix format` produces no diff**

```bash
mix format
git diff --stat lib/kith/contacts/phone_formatter.ex
```

Expected: still only your edit on the diff — no auto-format noise.

---

## Task 3: Replace the bug-pinning tests with correct ones

**Files:**
- Modify: `test/kith/contacts/phone_formatter_test.exs:153-159` (delete; replace with full non-NANP coverage)
- Modify: `test/kith/contacts/phone_formatter_test.exs:161-163` (extend `nil` test; add `""` test)

The current `describe "format/2"` block (lines 136-164) has two tests that encode the bug as expected behavior. They must be **deleted**, not added to.

- [ ] **Step 3.1: Delete the two bug-pinning tests**

Use `Edit` on `test/kith/contacts/phone_formatter_test.exs` to remove this block exactly:

```elixir
    test "national falls back for non-US numbers" do
      assert "+442079460958" = PhoneFormatter.format("+442079460958", "national")
    end

    test "international falls back for non-US numbers" do
      assert "+442079460958" = PhoneFormatter.format("+442079460958", "international")
    end
```

- [ ] **Step 3.2: Run the test file to confirm baseline state**

```bash
mix test test/kith/contacts/phone_formatter_test.exs
```

Expected: all remaining tests pass. The two deleted tests are gone.

- [ ] **Step 3.3: Add the failing test for GB national formatting**

Insert the following at the same position the deleted tests occupied (still inside `describe "format/2"`). Use the exact GB national string you recorded from Task 1.2 — replace the `<GB_NATIONAL>` placeholder below with that string.

```elixir
    test "national formats GB number" do
      assert "<GB_NATIONAL>" =
               PhoneFormatter.format("+442079460958", "national")
    end
```

- [ ] **Step 3.4: Run only the new test and confirm it FAILS first if you skipped Task 2**

If you are doing strict TDD and inserted this test before Task 2, run:

```bash
mix test test/kith/contacts/phone_formatter_test.exs --only line:<line_number>
```

Expected (pre-Task-2): FAIL with `match (=) failed` showing the actual mismatch.
Expected (post-Task-2): PASS.

If you already did Task 2, run the test and expect PASS:

```bash
mix test test/kith/contacts/phone_formatter_test.exs
```

- [ ] **Step 3.5: Add the GB international test**

Insert next to the GB national test. Replace `<GB_INTERNATIONAL>` with your Task 1.2 output for `+442079460958` in international.

```elixir
    test "international formats GB number" do
      assert "<GB_INTERNATIONAL>" =
               PhoneFormatter.format("+442079460958", "international")
    end
```

- [ ] **Step 3.6: Add French, German, Japanese, Saudi national + international tests**

Use Task 1.2 outputs. Insert all eight tests inside `describe "format/2"`:

```elixir
    test "national formats FR number" do
      assert "<FR_NATIONAL>" = PhoneFormatter.format("+33123456789", "national")
    end

    test "international formats FR number" do
      assert "<FR_INTERNATIONAL>" =
               PhoneFormatter.format("+33123456789", "international")
    end

    test "national formats DE number" do
      assert "<DE_NATIONAL>" =
               PhoneFormatter.format("+493012345678", "national")
    end

    test "international formats DE number" do
      assert "<DE_INTERNATIONAL>" =
               PhoneFormatter.format("+493012345678", "international")
    end

    test "national formats JP number" do
      assert "<JP_NATIONAL>" =
               PhoneFormatter.format("+819012345678", "national")
    end

    test "international formats JP number" do
      assert "<JP_INTERNATIONAL>" =
               PhoneFormatter.format("+819012345678", "international")
    end

    test "national formats SA number" do
      assert "<SA_NATIONAL>" =
               PhoneFormatter.format("+966501234567", "national")
    end

    test "international formats SA number" do
      assert "<SA_INTERNATIONAL>" =
               PhoneFormatter.format("+966501234567", "international")
    end
```

- [ ] **Step 3.7: Add unparseable-input tests (`"5551234567"` and `"garbage"`)**

These guard the "never destroy user data" contract on parse failure:

```elixir
    test "national leaves bare-number legacy value unchanged" do
      assert "5551234567" = PhoneFormatter.format("5551234567", "national")
    end

    test "international leaves bare-number legacy value unchanged" do
      assert "5551234567" = PhoneFormatter.format("5551234567", "international")
    end

    test "national leaves unparseable input unchanged" do
      assert "garbage" = PhoneFormatter.format("garbage", "national")
    end

    test "international leaves unparseable input unchanged" do
      assert "garbage" = PhoneFormatter.format("garbage", "international")
    end
```

- [ ] **Step 3.8: Extend the empty-string and nil coverage**

Replace the existing single nil-test (lines 161-163 in the original file) with the full nil/empty matrix:

```elixir
    test "nil returns nil for every format" do
      for fmt <- ["e164", "national", "international", "raw"] do
        assert is_nil(PhoneFormatter.format(nil, fmt)), "expected nil for format=#{fmt}"
      end
    end

    test "empty string returns nil for every format" do
      for fmt <- ["e164", "national", "international", "raw"] do
        assert is_nil(PhoneFormatter.format("", fmt)), "expected nil for format=#{fmt}"
      end
    end
```

- [ ] **Step 3.9: Run the full test file and confirm green**

```bash
mix test test/kith/contacts/phone_formatter_test.exs
```

Expected: all tests pass (existing US tests + 8 new non-NANP tests + 4 unparseable tests + nil/empty matrix tests).

If any assertion fails because the recorded library string doesn't match: re-check your Task 1.2 capture — most likely you copied a printed representation rather than the raw bytes (NBSP vs space). Re-probe in IEx and use `IO.inspect(s, binaries: :as_binaries)` to see the byte sequence.

---

## Task 4: Update the moduledoc

**Files:**
- Modify: `lib/kith/contacts/phone_formatter.ex:1-13`

The current moduledoc claims `format/2` "renders the stored E.164 value as national/international/raw" — which was misleading because non-NANP rendering was broken. Tighten the language and add a brief contributor note.

- [ ] **Step 4.1: Replace the moduledoc**

Replace lines 1-13 with:

```elixir
defmodule Kith.Contacts.PhoneFormatter do
  @moduledoc """
  Phone number normalization (E.164 for storage) and display formatting.

  Storage form is E.164 when the value can be parsed as a valid international
  number — either because it carries a `+` country-code prefix, or because the
  caller supplies a `default_region` (ISO 3166-1 alpha-2) for bare numbers.
  Unparseable input is returned trimmed-but-otherwise-unchanged so user data
  is never silently destroyed.

  Display formatting (`format/2`) reads the account's `phone_format`
  preference and renders the stored value via the `ExPhoneNumber`
  (libphonenumber) library. The phone's country code (carried in the stored
  E.164 value) determines national-format conventions; the account's region
  is not consulted at display time. Unparseable stored values pass through
  unchanged.

  **Contributors:** any UI surface that displays a phone number for a human
  must call `format/2` with the account's `phone_format` setting, otherwise
  the user's display preference is silently ignored. API/JSON responses are
  exempt — those return the canonical E.164 storage value.
  """
```

- [ ] **Step 4.2: Confirm compile + format still clean**

```bash
mix compile --warnings-as-errors && mix format
git diff --stat
```

Expected: only your edits in the diff.

---

## Task 5: Extend the existing Playwright spec with a non-NANP case

**Files:**
- Modify: `test/playwright/phone-format.spec.ts`

The existing spec covers NANP `(234) 567-8901` and `+1 234-567-8901` — i.e., exactly the country where the broken implementation already worked. It does not exercise any non-NANP path, which is why the bug was never caught.

**Why a Playwright spec instead of an LV component unit test:** the existing Playwright spec already covers the contact-show → settings → re-render cycle end-to-end. Building a parallel LV component test would duplicate that with a brittler surface (private function tested through HTML assertion + full ConnCase fixtures). Extending what's already there is the right shape.

- [ ] **Step 5.1: Add a non-NANP test for National format**

Open `test/playwright/phone-format.spec.ts`. Insert this test inside the existing `test.describe("Phone Number Formatting", () => { ... })` block, immediately after the existing `"phone displayed in National format"` test (line ~98). Use your Task 1.2 recorded GB national string in place of `<GB_NATIONAL>`:

```ts
  test("non-NANP phone displayed in National format", async ({ page }) => {
    // Change setting to National
    await page.goto("/settings/account");
    await page.waitForLoadState("networkidle");
    await page.waitForTimeout(300);

    const select = page.locator('select[name="account[phone_format]"]');
    if ((await select.count()) > 0) {
      await select.selectOption("national");
      await page.getByRole("button", { name: /save/i }).first().click();
      await page.waitForTimeout(500);
    }

    // Add a GB phone to the contact
    await goToContact(page, contactId);
    await addPhoneToContact(page, "+44 20 7946 0958");

    // Should render in GB national format (NOT raw E.164)
    const content = await page.content();
    expect(content).toContain("<GB_NATIONAL>");
  });
```

- [ ] **Step 5.2: Add a non-NANP test for International format**

Immediately after the previous test. Replace `<GB_INTERNATIONAL>`:

```ts
  test("non-NANP phone displayed in International format", async ({ page }) => {
    await page.goto("/settings/account");
    await page.waitForLoadState("networkidle");
    await page.waitForTimeout(300);

    const select = page.locator('select[name="account[phone_format]"]');
    if ((await select.count()) > 0) {
      await select.selectOption("international");
      await page.getByRole("button", { name: /save/i }).first().click();
      await page.waitForTimeout(500);
    }

    await goToContact(page, contactId);
    await addPhoneToContact(page, "+44 20 7946 0958");

    const content = await page.content();
    expect(content).toContain("<GB_INTERNATIONAL>");
  });
```

- [ ] **Step 5.3: Run the Playwright project locally (optional but recommended)**

Playwright needs a running dev server. In one terminal:

```bash
mix phx.server
```

In another:

```bash
npx playwright test --project=e2e test/playwright/phone-format.spec.ts
```

Expected: all tests pass, including the two new non-NANP ones.

If you can't run Playwright locally, CI will run it on push — the new tests guard the contact-show display path against future regressions either way.

---

## Task 6: Full quality gate + manual smoke

- [ ] **Step 6.1: Full test suite**

```bash
mix test
```

Expected: 0 failures.

- [ ] **Step 6.2: Static analysis**

```bash
mix quality
```

Expected: clean across format, credo, sobelow, dialyzer.

- [ ] **Step 6.3: Manual smoke in dev**

```bash
mix phx.server
```

In a browser:
1. Log in as a test user.
2. Create or pick a contact, add a French phone (`+33123456789`) and a US phone (`+12025550100`).
3. Navigate to Account Settings, set *Phone Number Format* to `National`. Save.
4. Go back to the contact-show page. Both phones should render in their respective national formats.
5. Set the preference to `International`. Both phones should re-render accordingly.
6. Set the preference to `E.164` and `Raw`. Both phones should render as `+33123456789` / `+12025550100`.

Document the results in your commit message or PR description (a screenshot is ideal but not required).

---

## Task 7: Commit and open PR

- [ ] **Step 7.1: Stage and commit**

```bash
git add lib/kith/contacts/phone_formatter.ex \
        test/kith/contacts/phone_formatter_test.exs \
        test/playwright/phone-format.spec.ts

git -c commit.gpgsign=false commit -m "$(cat <<'EOF'
fix(phone): honor account.phone_format for non-NANP numbers

The hand-rolled NANP binary-pattern formatter in PhoneFormatter.format/2
only handled +1 numbers; every other country silently fell through and
rendered as raw E.164 regardless of the account's display preference.
Replace with ExPhoneNumber.format/2 which uses the phone's own country
code to drive locale-correct national/international rendering.

- Unparseable values pass through unchanged (matches normalize/2 contract).
- Empty string now returns nil consistently with nil input.
- Bug-pinning tests at lines 153-159 of phone_formatter_test.exs are
  replaced with the correct expected output for GB, FR, DE, JP, SA.
- Playwright spec extended with non-NANP National/International tests
  to guard the end-to-end display path against future regressions.

Spec: docs/superpowers/specs/2026-05-16-phone-display-format-fix-design.md
EOF
)"
```

- [ ] **Step 7.2: Push and open PR**

If working stacked on PR #23:

```bash
git push -u origin pr-23-review
gh pr view 23
```

If landing as a separate follow-up PR off `main`:

```bash
git push -u origin <your-fix-branch>
gh pr create --title "fix(phone): honor account.phone_format for non-NANP numbers" --body "$(cat <<'EOF'
## Summary
- Replaces the NANP-only hand-rolled regex in PhoneFormatter.format/2 with ExPhoneNumber library calls
- account.phone_format now works for every country, not just +1
- Bug-pinning tests replaced with correct expected output
- Component smoke test guards against future regressions

## Spec
docs/superpowers/specs/2026-05-16-phone-display-format-fix-design.md

## Test plan
- [x] mix test (full suite, 0 failures)
- [x] mix quality (format/credo/sobelow/dialyzer)
- [x] Manual smoke: French + US contact, toggle phone_format across all four values, both phones re-render correctly each time
EOF
)"
```

---

## Done Criteria

1. `mix test` reports 0 failures.
2. `mix quality` is clean.
3. The two bug-pinning tests at `phone_formatter_test.exs:153-159` are gone; replaced with correct GB rendering assertions.
4. Eight new non-NANP tests pass (FR, DE, JP, SA × national, international).
5. Four legacy/garbage-input tests pass.
6. nil and empty-string matrix tests pass.
7. Playwright spec has two new non-NANP tests covering National + International formats (running them locally is optional; CI enforces).
8. Manual smoke confirms phone_format toggle works for both NANP and non-NANP phones.
9. The hand-rolled `format_national/format_international` private helpers and their fall-through clauses are removed from `phone_formatter.ex`.
10. The moduledoc reflects the new behavior and includes the contributor warning.
