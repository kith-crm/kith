# release/0.5.0 bug-fix plan

Worktree: `worktrees/debug-release-0.5.0` (base ref `release/0.5.0` @ `9cf2433`).

Six reported issues, root-caused from a code read. They ship as **5 focused
PRs grouped by page / feature**, arranged as a single `gh stack` on top of
`release/0.5.0`. Each `## Task N` below == one stack layer == one branch == one PR.

## Global Constraints

- Elixir / Phoenix LiveView / Ecto / Oban codebase. Run `mix precommit`
  (compile + unlock-unused + format + credo + test) before every commit; it
  must pass with 0 failures. If the pre-existing baseline is already broken,
  record that and only gate on *new* failures.
- Never add `Co-Authored-By` lines to commits (repo rule in CLAUDE.md).
- Scope-based multitenancy: context functions take `scope` / `account_id`
  first; never query without it. Soft-deleted contacts (`deleted_at`) are
  excluded from default queries.
- LiveView: no DB queries in `mount/3` (called twice) — data loads in
  `handle_params/3`. Match the existing file's HEEX idiom, token classes
  (`var(--color-*)`), and comment density.
- Storage keys become URLs via `Kith.Storage.url/1` (local `/uploads/...` +
  S3 impls). `Kith.Contacts.Photo.pending_sync?/1` flags `"pending_sync:…"`
  keys.
- Each task commits only to its own branch. Do not run `gh stack submit`,
  `git push`, or open PRs — the controller stops for that.
- Tasks are independent (disjoint files, except the shared section-nav
  component introduced in Task 2). Later tasks do not import code from
  earlier ones.

## PR / stack structure

| Layer | Branch | Page / feature | Issues | Size |
|------:|--------|----------------|--------|------|
| 1 | `fix/contact-timeline-photos` | Contact profile → activity stream | #4 | S |
| 2 | `fix/duplicate-merge-wizard` | Duplicates → cluster merge wizard | #1, #3 | S |
| 3 | `fix/monica-import-reminder-dates` | Monica import → reminders | #5 | M |
| 4 | `fix/monica-import-automerge` | Monica import → duplicate auto-merge | #2 | L |
| 5 | `chore/oban-import-job-retention` | Ops → Oban dashboard / retention | #6 | S |

Order: most-isolated, lowest-risk template fixes at the bottom (review + merge
first); the large auto-merge reconciliation and the ops/config change trail.
No hard code dependencies between layers — the stack is for review sequencing
and clean rebases.

Stack commands (controller runs these, NOT the implementers):

```bash
gh stack init --base release/0.5.0 \
  fix/contact-timeline-photos fix/duplicate-merge-wizard \
  fix/monica-import-reminder-dates fix/monica-import-automerge \
  chore/oban-import-job-retention
# per layer: gh stack checkout <branch> → implement → mix precommit → commit
gh stack sync            # restack upper layers after lower-layer edits
gh stack submit --open   # LAST, with human consent — pushes + opens 5 PRs
```

## Baseline

Before Task 1, run `mix compile --warnings-as-errors && mix test` in the
worktree. Record pre-existing failures in the ledger; gate only on new ones.

---

## Task 1 — `fix/contact-timeline-photos`  (issue #4)

**Branch:** `fix/contact-timeline-photos` (stack layer 1, base `release/0.5.0`).
**Page:** Contact profile (`/contacts/:id`) → unified activity stream.
**File:** `lib/kith_web/live/contact_live/activity_stream_component.ex` only
(plus its test file).

### Findings
- Timeline entry `entry.type == :photo` (around line 500-504) renders a fixed
  `size-[72px]` gradient box + `hero-photo` icon. **No `<img>`.**
- Photos Gallery mode (around line 393-400): same placeholder for every tile.
- Data is available: `Kith.Contacts.Photo.storage_key`
  (`lib/kith/contacts/photo.ex:7`); `Kith.Storage.url/1`
  (`lib/kith/storage.ex:65`). `Photo.pending_sync?/1`
  (`lib/kith/contacts/photo.ex:37`) flags `"pending_sync:…"` keys.

Root cause: the templates were stubbed with a placeholder and never wired to
`Storage.url/1`.

### Steps
1. First confirm what the `:photo` timeline entry carries in `entry.record` —
   find the entry-builder in this component (or the context that assembles
   `@entries`). If `entry.record` is the full `Kith.Contacts.Photo` struct,
   use `entry.record.storage_key`. If it only carries `id`/`title`, extend the
   projection so `storage_key` is available. Document what you found in the
   report.
2. Timeline block (`entry.type == :photo`): when
   `not Kith.Contacts.Photo.pending_sync?(entry.record)`, render
   `<img src={Kith.Storage.url(entry.record.storage_key)} alt={entry.title}
   class="size-[72px] rounded-lg object-cover" loading="lazy" />`. Otherwise
   keep the gradient placeholder box, adding a small "syncing" hint text.
3. Photos Gallery mode block: same treatment, image class
   `"w-full h-full object-cover"`, keep the `aspect-square` wrapper.
4. Do not change upload handling, filters, or `is_private` behaviour — private
   photos already list; just show the image like the others.

### Tests
Add/extend `test/kith_web/live/contact_live/activity_stream_component_test.exs`
(create if absent, matching the style of sibling component tests):
- a contact with a photo activity whose `storage_key` is a normal key →
  rendered HTML contains an `<img>` whose `src` contains that key (via
  `Kith.Storage.url/1`), in both timeline and gallery modes.
- a photo whose `storage_key` starts with `"pending_sync:"` → still renders the
  placeholder, no `<img>` for it.

### Verification
`mix test test/kith_web/live/contact_live/activity_stream_component_test.exs`
green; `mix precommit` clean.

---

## Task 2 — `fix/duplicate-merge-wizard`  (issues #1, #3)

**Branch:** `fix/duplicate-merge-wizard` (stack layer 2, base
`fix/contact-timeline-photos`).
**Page:** Duplicates → cluster merge wizard
(`/contacts/duplicates/cluster/:id`, `KithWeb.ContactLive.ClusterMerge`).
**Files:** `lib/kith_web/live/contact_live/cluster_merge.ex`,
`lib/kith_web/live/contact_live/index.html.heex`, a new shared component
module, and the relevant test files.

### Part A — #1: wizard drops the Contacts sub-nav / no "back to duplicates"

Findings:
- `ClusterMerge.render/1` already wraps `<Layouts.app>` (so the global left
  sidebar is present). What is missing is the page header + the "Secondary
  navigation" tab bar (`All / Archived / Duplicates / Trash`) that
  `ContactLive.Index` renders in `index.html.heex` lines ~8-60. That bar lives
  only in the `Index` template and its links use `patch=` (same-LiveView only).
- `ClusterMerge` has no breadcrumb and no link back to `/contacts/duplicates`.
  Its only navigations out: `push_navigate(~p"/contacts")` on error,
  `redirect(~p"/contacts/duplicates")` after "Not duplicates",
  `redirect(~p"/contacts/#{survivor}")` after a merge.

Root cause: `ClusterMerge` renders no section header/sub-nav and no
"back to duplicates" affordance.

Steps:
1. Extract the four-item section nav from `index.html.heex` (the
   `<nav class="flex items-center gap-1 border-b ...">` block, items
   `All / Archived / Duplicates / Trash` with the duplicates badge) into a
   new shared function component, e.g.
   `KithWeb.ContactLive.SectionNav.section_nav/1`, taking:
   - `active` (`:index | :archived | :duplicates | :trash`)
   - `pending_duplicates_count`
   - `link_mode` (`:patch` for Index, `:navigate` for ClusterMerge) — or two
     tiny wrappers; pick the cleaner option and note it in the report.
   Keep the exact markup, classes, icons and badge from the current Index nav.
2. `index.html.heex`: replace the inline `<nav>` with the new component
   (`link_mode={:patch}`), no visual change.
3. `cluster_merge.ex` `render/1`: immediately inside `<Layouts.app>`, before
   the `max-w-4xl` container, add:
   - an `<h1>` "Merge duplicates" styled like the `index.html.heex` header
     `<h1>` (`text-2xl font-semibold ... tracking-tight`);
   - a back-link `<.link navigate={~p"/contacts/duplicates"}>` with a
     `hero-arrow-left` icon and text "Back to duplicates";
   - the `section_nav` component with `active={:duplicates}`,
     `link_mode={:navigate}`, `pending_duplicates_count={@pending_duplicates_count}`.
   When `@synthetic?` is true (manual / `?with=` merge, not reached from the
   duplicates list): point the back-link at `~p"/contacts"` with text
   "Back to contacts" and render the section nav with `active={:index}` (or
   omit the nav for the synthetic case — pick one, note it).
4. `@pending_duplicates_count` and `@current_path` are already assigned by the
   `:require_authenticated` on_mount hook for this live_session — no mount
   changes needed. Confirm and note.

### Part B — #3: avatars render as raw storage keys/URLs

Findings:
- `avatar` is in `Kith.Contacts.MergeFields.@choice_fields`
  (`lib/kith/contacts/merge_fields.ex:24`).
- The Identity section renders each choice field's candidate values as text via
  `display(assigns, field, candidate.value)`. `display/3` special-cases only
  `:gender_id / :currency_id / :first_met_through_id`; everything else falls to
  `display/1` → `to_string/1`, so the "Avatar" row shows the raw storage key.
- The member chips already do it right
  (`<KithUI.avatar src={avatar_url(member)} ...>`).

Root cause: no image-rendering branch for the `avatar` field in the wizard's
value display.

Steps:
1. In `cluster_merge.ex`, in the choice-field `:for` loop that renders the
   candidate buttons, add an `avatar`-specific branch (guard on
   `field == :avatar`): render each candidate value as
   `<KithUI.avatar src={Kith.Storage.url(candidate.value)} name={...} size={:md} />`
   inside the button instead of the text line; keep the
   `{candidate.count} record(s)` caption.
2. The "Leave empty" button and `:clear` / `nil` effective value → let
   `KithUI.avatar` fall back to initials (it already does when `src` is nil).
   `avatar` stays clearable (it is not in `non_clearable?`).
3. Do not change the merge engine, `MergeFields`, `display/1` for other
   fields, or the member-chip rendering.

### Tests
- `test/kith_web/live/contact_live/cluster_merge_test.exs` (extend): opening a
  real cluster renders a "Back to duplicates" link whose `href` is
  `/contacts/duplicates`, and renders the section nav with Duplicates active.
- Same file: a cluster whose members disagree on `avatar` renders an `<img>`
  with the storage URL in the Avatar row (not the raw key text).
- If a `SectionNav` component test pattern exists for other components, add a
  minimal render test for it; otherwise the LiveView tests cover it.
- Ensure existing `index` LiveView tests still pass after the nav extraction.

### Verification
`mix test test/kith_web/live/contact_live/` green; `mix precommit` clean.

---

## Task 3 — `fix/monica-import-reminder-dates`  (issue #5)

**Branch:** `fix/monica-import-reminder-dates` (stack layer 3, base
`fix/duplicate-merge-wizard`).
**Feature:** Monica import → reminders.
**Files:** `lib/kith/workers/monica_misc_data_worker.ex`, a new `mix` task
under `lib/mix/tasks/`, and their tests.

### Findings
- `import_single_reminder/5` (around line 475):
  ```elixir
  next_date =
    parse_date_string(reminder_data["next_expected_date"]) || Date.utc_today()
  ```
  `parse_date_string/1` (around line 658) only matches `is_binary/1` → anything
  else → `nil` → every reminder falls back to `Date.utc_today()` (the import
  date). That is the bug the user sees ("all reminders dated today").
- Monica serialises special-date fields as an **object**
  `%{"date" => "2024-06-01 00:00:00", "timezone" => "UTC", ...}` — exactly the
  shape `Kith.Imports.Sources.MonicaApi`'s `parse_special_date/1` unpacks for
  `birthdate`. The reminders path never got that handling. The real key may be
  `next_expected_date` and/or `initial_date`; Monica may also send a plain ISO
  string in newer versions. Implement defensively for all of these — do not
  block on obtaining a live payload.
- `map_monica_reminder_frequency/1` (around line 614): `"year"` →
  `{"recurring", "annually"}`, others → `{"one_time", nil}`. Monica's
  special-date / birthday reminders come through this same endpoint and become
  generic `recurring` / `one_time` Kith reminders — they bypass
  `reminders_birthday_unique_idx` (which only covers `type == "birthday"`), so
  they can duplicate a real birthday reminder.
- `Kith.Reminders.create_birthday_reminder/2` currently has **no caller in
  `lib/`** (tests only). So Kith does not auto-derive a birthday reminder when
  the importer sets `birthdate`. The "wrong-date birthday reminder" the user
  sees is the imported generic one.

Root cause: (a) the Monica reminder date field is an object (or a different
key) that `parse_date_string/1` cannot read → every imported reminder gets the
import date; (b) Monica special-date reminders are imported as generic
reminders with no birthday dedup.

### Steps
1. Add a tolerant date extractor in `monica_misc_data_worker.ex`, mirroring
   `parse_special_date/1`:
   ```elixir
   defp reminder_next_date(%{"date" => d}) when is_binary(d), do: parse_date_string(d)
   defp reminder_next_date(d) when is_binary(d), do: parse_date_string(d)
   defp reminder_next_date(_), do: nil
   ```
   In `import_single_reminder/5` try `next_expected_date` then `initial_date`:
   ```elixir
   next_date =
     reminder_next_date(reminder_data["next_expected_date"]) ||
       reminder_next_date(reminder_data["initial_date"]) ||
       fallback_today(reminder_data)
   ```
   where `fallback_today/1` returns `Date.utc_today()` **and** emits
   `Logger.warning("[MonicaMiscData] reminder #{id} has no parseable date; using today")`
   so a future regression is visible in logs.
2. Birthday handling: when Monica's `frequency_type == "year"` AND the
   reminder looks like a birthday/special-date reminder (blank/absent title, or
   Monica marks it — inspect the fields available and pick the safest signal;
   document the choice), skip creating a generic reminder and instead, if
   `contact.birthdate` is set and no birthday reminder exists for the contact,
   call `Kith.Reminders.create_birthday_reminder(contact, user_id)`. If
   `contact.birthdate` is nil, fall through to the generic path with the parsed
   date. This keeps one code path for birthday reminders.
   - If a clean "is birthday reminder" signal is not available from the Monica
     payload shape, make this conservative: only treat it as birthday when
     `frequency_type == "year"` and the title is empty/nil. Note the decision.
3. New `mix` task `Mix.Tasks.Kith.Imports.FixReminderDates` (task name
   `kith.imports.fix_reminder_dates`), `--account <id>` required, `--dry-run`
   supported: for reminders whose `Kith.Imports.ImportRecord` has
   `source_entity_type == "reminder"` in that account, recompute
   `next_reminder_date` — for `type == "birthday"` use
   `Kith.TimeHelper.next_birthday_date(contact.birthdate)`; for others leave a
   `Logger.info` listing the reminder ids that still have the import date so an
   operator can re-run the import or fix them by hand. Keep it idempotent and
   scope-safe. Follow the structure of existing tasks in `lib/mix/tasks/` if
   any exist.
4. Do NOT wire `create_birthday_reminder/2` into `Contacts.update_contact` in
   this task — leave a `# TODO` note + mention it in the report as a follow-up.

### Tests
`test/kith/workers/monica_misc_data_worker_test.exs` (extend) — unit-test
`import_single_reminder/5` (make it testable or drive it through the public
path with a stubbed HTTP response, matching how the file's other endpoints are
tested):
- object-shaped `next_expected_date` → reminder gets that exact date.
- plain ISO string `next_expected_date` → parsed correctly.
- only `initial_date` present (object) → used.
- neither present → `Date.utc_today()` and a warning logged
  (`ExUnit.CaptureLog`).
- `frequency_type == "year"` + blank title + contact with `birthdate` → one
  `type: "birthday"` reminder, `next_reminder_date == next_birthday_date(...)`,
  and no duplicate generic reminder.
Add a test for the mix task's core function (extract the logic into a testable
module function; the `run/1` wrapper just parses args).

### Verification
`mix test test/kith/workers/monica_misc_data_worker_test.exs` and the mix-task
test green; `mix precommit` clean.

---

## Task 4 — `fix/monica-import-automerge`  (issue #2)

**Branch:** `fix/monica-import-automerge` (stack layer 4, base
`fix/monica-import-reminder-dates`).
**Feature:** Monica import → duplicate auto-merge.
**Files:** `lib/kith/imports/sources/monica_api.ex`,
`lib/kith/workers/duplicate_detection_worker.ex` (refactor a callable out),
possibly `lib/kith/duplicate_detection.ex`, a new `mix` task, and tests.

### Findings
Two independent matchers with different rules:

| | Import auto-merge (`monica_api.ex` `auto_merge_duplicates/2`, ~line 855) | Detection worker (`duplicate_detection_worker.ex`) |
|---|---|---|
| Candidate gate | must share a normalized `{first_name,last_name}` group (`name_key/1`, exact after trim/downcase/collapse) **and** `definite_duplicate?/2` = share ≥1 email OR phone OR address | any single signal: `similarity(display_name) > 0.5` (pg_trgm), OR shared email/phone/address |
| "100%" score | n/a (boolean) | `min(max_base + 0.05·(signals−1), 1.0)`; `name_sim` = raw trigram similarity. **Identical `display_name` ⇒ `name_sim = 1.0` ⇒ score `1.0`, `reasons = ["name_match"]`, nothing else shared.** |
| Grouping | pairwise, one survivor per name group; bails on a whole group if the survivor id is already `seen` | union-find, transitive |
| Field compare | `shared_phones?` digits-only; `shared_emails?` trim+downcase; `address_keys` needs line1 AND postal | SQL: phone exact `=` on E.164; email `LOWER(TRIM())`; address `LOWER(TRIM(line1))+LOWER(TRIM(postal))` |

A cluster shown at 100% is usually an identical-`display_name` pair with no
shared email/phone/address (or contact info only one normalizer treats as
equal, or first/last swapped so `display_name` matches but `name_key` does
not). `definite_duplicate?/2` refuses name-only matches by design; the
name-group gate refuses `display_name`-only matches — so ~23 detector-"100%"
clusters survive the import. Transitive chains (A–B phone, B–C email, A–C
nothing) also strand C.

Root cause: the importer's conservative predicate and the detector's scorer are
never reconciled.

### Steps
1. Refactor the per-account detection body of
   `DuplicateDetectionWorker.detect_duplicates/1` into a public callable —
   e.g. `Kith.DuplicateDetection.scan_account(account_id)` (or a new
   `Kith.DuplicateDetection.Scanner` module) — that runs the name/email/phone/
   address matchers, `merge_matches`, the `>= 0.5` filter, and the
   `DuplicateCandidate` upsert. The Oban worker calls the new function; no
   behaviour change for the cron path. Cover with an existing/added worker
   test.
2. In `monica_api.ex` `auto_merge_duplicates/2`, AFTER the current
   name-group merge pass (keep it — it is fast and safe), add a second pass:
   - call `Kith.DuplicateDetection.scan_account(account_id)`;
   - load `DuplicateCandidate`s for the account with `status == "pending"` and
     `score >= @auto_merge_score` (module attribute, default `1.0`; also
     accept an import option `opts["auto_merge_score"]` if present);
   - restrict to pairs where BOTH contact ids are in this import's
     `ImportRecord` local ids (do not touch pre-existing contacts);
   - build clusters (reuse `Kith.DuplicateDetection.build_clusters/1` or its
     union-find helper) and for each cluster call `Contacts.merge_cluster/4`
     (or repeated `Contacts.merge_contacts/2`) with the existing
     `DuplicateDetection.default_primary/1` rule;
   - **safety guard:** skip a cluster (and `Logger.info` the skip with ids +
     reason) if any pair's only reason is `["name_match"]` with `name_sim < 1.0`,
     or if two members have different non-empty `birthdate`s.
   - after merging, ensure `DuplicateDetection.resolve_after_merge/4` (or
     whatever the merge path already calls) runs so merged candidate rows are
     dismissed/repointed and `cluster_count/1` drops.
3. Keep the summary/return shape of `auto_merge_duplicates/2` — extend
   `%{merged: n, errors: [...]}` with the second pass's counts (e.g.
   `merged_by_detection`, `skipped`). Update the caller/log line at ~line 888
   and any import summary that surfaces these numbers.
4. New `mix` task `Mix.Tasks.Kith.Duplicates.Automerge`
   (`kith.duplicates.automerge --account <id> [--dry-run] [--min-score 1.0]`):
   runs steps 2's second pass standalone for an existing account (so the
   current prod account with ~23 clusters is cleaned without re-import).
   Extract the pass into a testable module function; `run/1` just parses args.
5. Do not change the scoring formula, the detector's SQL, or
   `definite_duplicate?/2`. Do not lower `@auto_merge_score` below `1.0` in
   this task.

### Tests
- Worker test still green after the `scan_account` refactor; add a direct test
  of `scan_account/1`.
- `test/kith/imports/sources/monica_api_test.exs` (or the auto-merge test file):
  seed contacts reproducing each divergence — (a) identical `display_name`,
  no shared fields, no shared `name_key` first/last → after
  `auto_merge_duplicates` the pair is merged and `cluster_count == 0`;
  (b) transitive A–B–C via different signals → all three merged;
  (c) safety guard: `name_match`-only with `name_sim 0.7` → NOT merged, logged;
  (d) different non-empty birthdates → NOT merged.
- Mix-task test on the extracted function with `--dry-run` asserting no writes.

### Verification
`mix test` for the affected files green; `mix precommit` clean. Note in the
report: this is the largest task; if the fix loop stalls it may need a more
capable model.

---

## Task 5 — `chore/oban-import-job-retention`  (issue #6)

**Branch:** `chore/oban-import-job-retention` (stack layer 5, base
`fix/monica-import-automerge`).
**Feature:** Ops → Oban Web dashboard / job retention.
**Files:** `config/config.exs`, `config/runtime.exs`,
`lib/kith/config_helpers.ex`, `lib/kith/application.ex` (boot log), a test,
and a short `docs/` note.

### Findings (root cause needs prod confirmation — no code smoking gun)
- Pruner is 7 days everywhere it exists:
  - `config/config.exs:54` — `Oban.Plugins.Pruner, max_age:
    OBAN_PRUNER_MAX_AGE_DAYS("7") * 86400` (evaluated at release-build time).
  - `config/runtime.exs:227` (`:prod`, `KITH_MODE=worker`) —
    `max_age: Kith.ConfigHelpers.oban_pruner_max_age_seconds()` (default 7 days,
    read at boot).
  - `config/runtime.exs:238` (`:prod`, `KITH_MODE` != worker) —
    `queues: false, plugins: false` → web container runs no Pruner.
- `Kith.ConfigHelpers.oban_pruner_max_age_seconds/0` returns 7 days unless
  `OBAN_PRUNER_MAX_AGE_DAYS` is set small/`0` — user says it is unset.
- `Kith.Imports.JobCancellation` uses `Oban.cancel_all_jobs/2`; cancelled jobs
  are terminal but still only pruned after `max_age`.
- No code calls `Oban.delete*` / `Repo.delete` on `oban_jobs`.

Most likely (to confirm on prod, documented for the operator):
1. Oban Web's Jobs view defaults to non-terminal states — `completed` import
   jobs drop off within seconds but remain in `oban_jobs` for 7 days. Verify
   with the `completed` state filter or
   `SELECT state, count(*) FROM oban_jobs WHERE worker LIKE '%Import%' GROUP BY 1`.
2. If rows are genuinely gone within a day: a stray `OBAN_PRUNER_MAX_AGE_DAYS`
   on the container running queues. Check `Oban.config()` on a prod node.

### Steps (safe, defensive — the diagnosis itself is an ops task)
1. `lib/kith/config_helpers.ex`: keep the default `7`, but clamp absurd values
   — if the parsed value is `< 1`, treat as `1` and `Logger.warning`. Add a
   `@doc` explaining the unit (seconds) and the env var.
2. Unify the Pruner config so web and worker cannot silently disagree: in
   `config/runtime.exs` compute `max_age` once via
   `Kith.ConfigHelpers.oban_pruner_max_age_seconds/0` for the worker branch
   (already does) and add a comment cross-referencing `config/config.exs`. Do
   not change the 7-day default or the `plugins: false` for web.
3. `lib/kith/application.ex` (or wherever Oban starts): on boot, when Oban
   plugins are enabled, `Logger.info("[Oban] pruner max_age = #{seconds}s
   (#{div(seconds, 86400)}d)")` so the effective retention is visible in logs.
4. Test `test/kith/config_helpers_test.exs`: unset env →
   `oban_pruner_max_age_seconds() == 604_800`; `OBAN_PRUNER_MAX_AGE_DAYS=0`
   → clamped to `86_400` (1 day) with a warning; `=14` → `1_209_600`.
   Use the async-safe env pattern (this module reads `System.get_env` at call
   time, so `System.put_env`/`System.delete_env` in the test with
   `async: false`).
5. `docs/ops/oban-import-jobs.md` (new, short): the two likely causes above,
   the exact SQL / `Oban.config()` checks, and the fix for each. This is the
   deliverable for the "diagnose on prod" part.

### Tests
`mix test test/kith/config_helpers_test.exs` green; `mix precommit` clean.

### Verification
`mix precommit` clean. Report notes clearly that the runtime root cause is
still to be confirmed on prod per `docs/ops/oban-import-jobs.md`.
