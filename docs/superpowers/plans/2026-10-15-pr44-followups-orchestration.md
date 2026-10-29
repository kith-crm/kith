# PR #44 Follow-ups: Parallel Execution (Agent Team) Plan

> **For the lead agent:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development, with superpowers:dispatching-parallel-agents for each wave. You coordinate; lane agents implement; reviewers gate each task.

**Goal:** Execute the two implementation plans with a team of agents working in parallel wherever the code areas don't overlap, and land the result on `feat/stack-40-consolidated` (PR #44).

**Plans executed:**
- A: [`2026-10-15-monica-reminder-import.md`](2026-10-15-monica-reminder-import.md) (tasks A1–A12)
- B: [`2026-10-15-photo-thumbs-merge-wizard-review-fixes.md`](2026-10-15-photo-thumbs-merge-wizard-review-fixes.md) (tasks B1–B7)

## Team

| Agent | Lane | Owns (only these agents edit these files in that wave) | Tasks |
|---|---|---|---|
| `reminders-core` | A-core | `priv/repo/migrations/*`, `lib/kith/reminders*`, `lib/kith/contacts.ex`, `lib/kith/contacts/{contact,merge}.ex`, `lib/kith/workers/reminder_email_worker.ex`, `lib/kith_web/controllers/api/{reminder_controller,contact_json}.ex` | A1 → A2 → A3 → A4 → A5 |
| `monica-import` | A-import | `lib/kith/imports/monica/*`, `lib/kith/workers/monica_misc_data_worker.ex`, `lib/kith/imports/sources/monica_api.ex`, `test/support/fixtures/monica*` | A6 (wave 1); A7, A8 (wave 2) |
| `reminders-ui` | A-ui | `lib/kith/time_helper.ex`, `contact_live/{show.ex,pets_component.ex,reminders_component.ex,about_component.ex}`, `reminder_live/upcoming.ex`, `kith_ui.ex` **`reminder_icon_name/1` only** | A11 (wave 1); A9, A10 (wave 2) |
| `photo` | B-photo | `lib/kith/storage/s3.ex`, `assets/js/hooks/img_fallback.js`, `photo_thumb_component.ex`, `kith_ui.ex` **`avatar/1`, `contact_badge/1` only**, avatar call sites | B1 → B2 → B3 (wave 1); B4 (wave 2) |
| `wizard` | B-wizard | `lib/kith_web/live/contact_live/cluster_merge.ex` and its test | B5 → B6 (wave 1) |
| lead | integration | the integration branch; merges; wave 3 | merges, A12, B7, final review |

Each lane agent gets a fresh reviewer (superpowers:requesting-code-review) after every task, before it starts the next one.

## Why these lanes are independent

- **A vs B:** A is reminders and the Monica importer; B is storage, image hooks and the merge wizard. They share no module except `kith_ui.ex` (different functions; see below) and `about_component.ex` (wave 2 only; see below).
- **Inside A:** the mapper (A6) is pure and only produces attribute maps, so it doesn't wait for the schema. The 29 Feb fix (A11) touches only `time_helper.ex`, `show.ex` and `pets_component.ex`. Everything that needs the new columns or `sync_first_met/1` (A7–A10) is in wave 2.
- **Inside B:** the wizard lane edits only `cluster_merge.ex`; the photo lane never touches it. B6 adds the avatar ids in `cluster_merge.ex` in wave 1, so B4 (wave 2) can make ids mandatory without breaking the wizard.

Shared-file rules:
- `kith_ui.ex`: A9 edits only `reminder_icon_name/1` (lines ~106–111); B4 edits only `avatar/1` and `contact_badge/1`. Both are wave 2; the lead merges them one after the other.
- `about_component.ex`: A10 adds the root `id={@id}` and the first-met checkbox; B4 adds avatar ids (search results, `selected_contact_badge`). Merge A10 first; B4's lane then merges integration in before its own merge and resolves any hunk overlap by keeping both changes.

## Waves

```
wave 1 (parallel):  reminders-core [A1..A5]   monica-import [A6]   reminders-ui [A11]   photo [B1..B3]   wizard [B5, B6]
                    └─ lead merges, in order: a-core, b-wizard, a-import, a-ui, b-photo  (full suite after each)
wave 2 (parallel):  monica-import [A7, A8]    reminders-ui [A9, A10]    photo [B4]
                    └─ lead merges, in order: a-import, a-ui, b-photo
wave 3 (lead):      A12 (Monica e2e), B7 (S3 regression + browser checks), final whole-branch review
```

A lane that finishes a wave early stops; it does not start the next wave's tasks before the lead has merged and announced the new integration head.

## Setup (lead, once)

```bash
cd C:/Users/ME/projects/kith
git fetch origin
BASE=$(git -C worktrees/stack40-consolidated rev-parse HEAD)   # includes both specs and these plans
git worktree add worktrees/fu-integration -b fu/integration $BASE
for lane in a-core a-import a-ui b-photo b-wizard; do
  git worktree add worktrees/fu-$lane -b fu/$lane $BASE
  # Reuse compiled deps instead of a cold build per worktree.
  cp -r worktrees/stack40-consolidated/deps worktrees/stack40-consolidated/_build worktrees/fu-$lane/
  cp assets/vendor/heroicons.js worktrees/fu-$lane/assets/vendor/   # gitignored; needed by mix assets.build
done
```

Each lane agent's environment:

| Lane | Worktree | `MIX_TEST_PARTITION` | `DB_PORT` |
|---|---|---|---|
| a-core | `worktrees/fu-a-core` | `_acore` | 5444 |
| a-import | `worktrees/fu-a-import` | `_aimport` | 5444 |
| a-ui | `worktrees/fu-a-ui` | `_aui` | 5444 |
| b-photo | `worktrees/fu-b-photo` | `_bphoto` | 5444 |
| b-wizard | `worktrees/fu-b-wizard` | `_bwizard` | 5444 |
| integration | `worktrees/fu-integration` | `_integ` | 5444 |

Port 5444 is the `kith-e2e` Postgres container started during planning (`docker compose -p kith-e2e -f docker-compose.dev.yml up -d postgres`, with `DB_PORT=5444`). Each partition gets its own `kith_test<partition>` database, so lanes never share test data.

Rules for every lane agent:
- Work only in your worktree; never touch the main checkout or another lane's worktree. No bare `git stash`.
- Commit on your lane branch only; never push. The lead pushes.
- `DB_PORT=5444 MIX_TEST_PARTITION=<yours> mix test` with 0 failures, plus `mix format` and `mix credo --strict`, before every commit (the pre-commit hook doesn't run in worktrees).
- If a task needs a file another lane owns in this wave, stop and tell the lead.

## Merging (lead)

For each lane branch, in the wave's order:

```bash
cd C:/Users/ME/projects/kith/worktrees/fu-integration
git merge --no-ff fu/<lane> -m "Merge lane <lane> (wave N)"
DB_PORT=5444 MIX_TEST_PARTITION=_integ mix test     # must be 0 failures before the next merge
mix compile --warnings-as-errors && mix credo --strict
```

At the start of wave 2, each wave-2 lane merges the new integration head into its own branch first (`git merge fu/integration`) and runs its suite.

## E2E environment (wave 3)

- Monica 4.1.2: `docker compose up -d` in `C:/Users/ME/monica-review` (port 8089), or the committed copy from Task A12. Reseed with the committed seed.
- Kith from `worktrees/fu-integration` on port **4000** (Playwright's `baseURL`): `DB_PORT=5445 APP_PORT=4000 docker compose -p kith-fu -f docker-compose.dev.yml --profile app up -d postgres mailpit app` (or `mix phx.server` on the host). Stop the planning stack's app container (`kith-e2e-app-1`, :4044) first if it conflicts.
- Browser runs are headless (Playwright's default); never pass `--headed`.

## Finish (lead)

1. Whole-branch review of `fu/integration` against both specs (superpowers:requesting-code-review on the most capable model).
2. `DB_PORT=5444 MIX_TEST_PARTITION=_integ mix test` and `mix quality` on the integration worktree.
3. Fast-forward `feat/stack-40-consolidated` to `fu/integration` in `worktrees/stack40-consolidated` (`git merge --ff-only fu/integration`). **Ask the user before pushing** to `origin/feat/stack-40-consolidated` (PR #44).
4. Update PR #44's description: move the two follow-ups out of "Known follow-ups".
5. Clean up: `git worktree remove` the six `fu-*` worktrees, delete the `fu/*` branches, drop the `kith_test_*` partition databases, stop any dev servers and the fake S3.
