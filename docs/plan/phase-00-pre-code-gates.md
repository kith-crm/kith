# Phase 00: Pre-Code Gates

> **Status:** Implemented
> **Depends on:** None
> **Blocks:** Phase 01, Phase 02, Phase 03, Phase 04, Phase 05, Phase 06, Phase 07, Phase 08, Phase 09, Phase 10, Phase 11, Phase 12, Phase 13, Phase 14

## Overview

This phase produces the foundational documentation and architectural decisions that must exist before any code is written. It ensures the team has a shared, reviewed understanding of the database schema, frontend conventions, background job transactionality guarantees, technology rationale, and dependency inventory. No migration file, no Elixir module, and no LiveView template may be created until every task in this phase is marked complete and reviewed.

---

## Tasks

### TASK-00-01: Entity Relationship Diagram (ERD)
**Priority:** Critical
**Effort:** L
**Depends on:** None
**Description:**
Create a comprehensive ERD document covering all v1 tables. For each table, list every column with its name, Ecto/Postgres type, nullable flag, default value, and any constraints. Document all foreign keys, unique constraints, and indexes explicitly.

**Tables to document (27 total):**
- `accounts` — tenant/workspace root; columns include `immich_status` enum (`:disabled`/`:ok`/`:error`, default `:disabled`), `immich_last_synced_at` (utc_datetime, nullable), `timezone` (string), `locale` (string), `send_hour` (integer 0-23)
- `users` — belongs to account; role enum (`:admin`/`:editor`/`:viewer`); email, hashed_password, confirmed_at, totp_secret, webauthn fields
- `user_tokens` — session/email/api tokens; context column; belongs to user
- `invitations` — email, role, unique token, accepted_at; belongs to account, invited_by user
- `contacts` — central hub entity; first_name, last_name, display_name, nickname, gender_id (FK), birthdate, description, avatar, occupation, company, favorite (bool), archived (bool), deceased (bool), last_talked_to (utc_datetime), deleted_at (timestamptz nullable — SOFT DELETE), immich_person_id, immich_person_url, immich_status enum, immich_last_synced_at; belongs to account
- `addresses` — street, city, province, postal_code, country, latitude (decimal), longitude (decimal); belongs to contact
- `contact_fields` — data (string), contact_field_type_id (FK); belongs to contact
- `contact_field_types` — name, protocol (e.g. "mailto:", "tel:"), icon; belongs to account (nullable for defaults)
- `relationship_types` — name, name_reverse_relationship; belongs to account (nullable for defaults)
- `relationships` — contact_id (FK), related_contact_id (FK), relationship_type_id (FK); belongs to account; unique index on (account_id, contact_id, related_contact_id, relationship_type_id)
- `tags` — name; belongs to account; unique on (account_id, name)
- `contact_tags` — join table; contact_id (FK), tag_id (FK); unique on (contact_id, tag_id)
- `genders` — name; belongs to account (nullable for defaults)
- `emotions` — name; belongs to account (nullable for defaults); seeded table
- `activity_type_categories` — name; belongs to account (nullable for defaults); seeded table
- `life_event_types` — name; belongs to account (nullable for defaults); seeded table
- `notes` — body (text), favorite (bool), private (bool, default false); belongs to contact
- `documents` — file_name, file_path, file_size, content_type; belongs to contact
- `photos` — file_name, file_path, file_size, content_type; belongs to contact
- `life_events` — life_event_type_id (FK), name, description, happened_at (date); belongs to contact
- `activities` — activity_type_category_id (FK), title, description, happened_at (date), emotion_id (FK nullable); belongs to account
- `activity_contacts` — join table; activity_id (FK), contact_id (FK); unique on (activity_id, contact_id)
- `calls` — contact_id (FK), description, called_at (utc_datetime), emotion_id (FK nullable); belongs to account
- `reminders` — contact_id (FK), reminder_type enum (`:birthday`/`:stay_in_touch`/`:one_time`/`:recurring`), title, description, initial_date (date), frequency_type enum (nullable), frequency_number (integer nullable), enqueued_oban_job_ids (jsonb, default `[]`), active (bool, default true); belongs to account
- `reminder_rules` — reminder_id (FK), number_of_days_before (integer); how many days before to send pre-notification
- `reminder_instances` — reminder_id (FK), scheduled_at (utc_datetime), triggered_at (utc_datetime nullable), status enum (`:pending`/`:resolved`/`:dismissed`); belongs to account
- `audit_logs` — account_id (**non-nullable FK → `accounts.id`**), actor_id (**nullable FK → `users.id`** — nullable to allow system-initiated events), action (string), auditable_type (string), auditable_id (integer), contact_id (integer — **plain integer, NO FK**), contact_name (string — snapshot at event time), properties (jsonb), inserted_at (utc_datetime)

**Key Schema Constraints:**
- Soft-delete on `contacts` only via `deleted_at` column. All other tables cascade hard-delete.
- `contacts_active_idx`: partial index on `(account_id) WHERE deleted_at IS NULL`
- `contacts_trash_idx`: partial index on `(account_id, deleted_at) WHERE deleted_at IS NOT NULL`
- `audit_logs.contact_id` is a plain integer with NO foreign key constraint. Entries survive contact hard-deletion.
- `relationships` has a unique index on `(account_id, contact_id, related_contact_id, relationship_type_id)`
- `reminders.enqueued_oban_job_ids` is jsonb defaulting to `'[]'`
- All reference data tables (`genders`, `emotions`, `activity_type_categories`, `life_event_types`, `contact_field_types`, `relationship_types`) use seeded database tables, NOT Postgres enums, to allow v1.5 customization as additive migration.
- `currencies` table must appear in the ERD as a reference data table alongside `genders`, `pronouns`, `relationship_types`, `contact_field_types`, `activity_types`, `call_directions`, `life_event_types`, and `reminder_frequencies`.
- Additive-only migrations policy: no column drops, table drops, or destructive renames until major version.

**Acceptance Criteria:**
- [ ] Document exists at `docs/erd.md` (or equivalent) in the repo
- [ ] Every one of the 27 tables listed above is documented with all columns, types, nullability, defaults, and constraints
- [ ] All foreign keys are explicitly listed with ON DELETE behavior (CASCADE for all except audit_logs.contact_id which has no FK)
- [ ] `audit_logs.account_id` is documented as a non-nullable FK to `accounts.id`
- [ ] `audit_logs.actor_id` is documented as a nullable FK to `users.id` (nullable to allow system-initiated events)
- [ ] All indexes (including partial indexes) are documented with their WHERE clauses
- [ ] The unique index on relationships is documented
- [ ] The `enqueued_oban_job_ids` jsonb column on reminders is documented
- [ ] The `currencies` table is present in the ERD alongside all other reference data tables (`genders`, `pronouns`, `relationship_types`, `contact_field_types`, `activity_types`, `call_directions`, `life_event_types`, `reminder_frequencies`)
- [ ] Document has been reviewed and approved by at least 2 team members before any migration is written

**Safeguards:**
> ⚠️ Do NOT use Postgres enums for any reference data. All six reference tables (genders, emotions, activity_type_categories, life_event_types, contact_field_types, relationship_types) must be seeded database tables to enable additive v1.5 customization. Using enums would require destructive migrations later.

**Notes:**
- The ERD document is the single source of truth for all migration files in Phase 03+
- Consider using a Mermaid ER diagram alongside the tabular column definitions for visual clarity
- Reference: Product spec sections 3 (Domain Model), 6 (Multi-Tenancy), 7 (Reminders)

---

### TASK-00-02: Frontend Conventions Document
**Priority:** Critical
**Effort:** M
**Depends on:** None
**Description:**
Write a frontend conventions document that establishes the component hierarchy, Alpine.js boundaries, RTL-safe CSS conventions, and the authorization interface. This document is a PR gate — no contact profile LiveView may be merged without it.

**Document must cover:**

1. **Component Hierarchy:**
   - Level 1: LiveView modules — one per route, owns socket state, no rendering logic in the module itself
   - Level 2: LiveComponents — stateful sub-units with independent data loading, own their events (e.g., `NotesListComponent`, `ActivitiesListComponent`, `ImmichReviewComponent`)
   - Level 3: Function components — stateless pure render, no Phoenix module (e.g., `.contact_badge`, `.tag_badge`, `.form_field`, `.card`, `.reminder_row`)

2. **Alpine.js Scope Boundary:**
   - Alpine handles UI chrome ONLY: dropdown menus, tooltips, clipboard, keyboard shortcuts, sidebar collapse, local toggle state
   - Alpine does NOT read from or write to server state
   - No form submissions or contact field mutations through Alpine
   - All data changes go through LiveView forms or explicit API calls
   - Include examples of correct and incorrect Alpine usage

3. **RTL-Safe Tailwind Conventions:**
   - Use logical properties: `ms-` / `me-` / `ps-` / `pe-` instead of directional `ml-` / `mr-` / `pl-` / `pr-`
   - `<html dir="<%= html_dir(@locale) %>" lang="<%= @locale %>">` in root layout
   - Every major screen must be verified in at least one RTL locale during development

4. **Kith.Policy.can?/3 Interface:**
   - Function signature: `Kith.Policy.can?(user, action, resource) :: boolean()`
   - Used in LiveView `mount/3`, function component templates, and context function guards
   - Viewer-restricted controls are hidden (not grayed out)
   - 403 pages explain the role limitation and link to account admin
   - Document the canonical action atoms (`:create`, `:read`, `:update`, `:delete`, `:archive`, `:restore`, `:merge`, `:import`, `:export`, etc.)
   - Document the resource atoms (`:contact`, `:note`, `:activity`, `:reminder`, `:settings`, `:users`, `:account`, etc.)

**Acceptance Criteria:**
- [ ] Document exists at `docs/frontend-conventions.md` in the repo
- [ ] Component hierarchy is defined with all three levels, responsibilities, and examples
- [ ] Alpine.js scope boundary includes correct/incorrect usage examples
- [ ] Alpine.js boundary rule is explicitly stated: Alpine.js is used ONLY for micro-interactions (dropdown toggles, character counters, accordion). ALL state that affects server data must go through LiveView. No Alpine.js form submissions that bypass LiveView events.
- [ ] RTL conventions specify logical properties and root layout `dir` attribute
- [ ] `Kith.Policy.can?/3` interface is fully defined with action and resource atoms
- [ ] Document is marked as a PR gate for the first contact profile LiveView

**Auth Conventions Gate:**
- [ ] Confirm that the OAuth/PKCE flow is documented: the `state` parameter must be a signed token verifiable server-side, NOT a random nonce stored only in session. Document the signing mechanism and verification step.

**Safeguards:**
> ⚠️ Never use directional Tailwind classes (`ml-`, `mr-`, `pl-`, `pr-`) in any template. Always use logical properties (`ms-`, `me-`, `ps-`, `pe-`). This is not a suggestion — it's a hard rule enforced in code review. Retrofitting RTL support is extremely expensive.

**Notes:**
- Reference: Product spec section 12 (Frontend Architecture)
- Consider adding a Credo custom check or CI linting rule that flags directional Tailwind classes

---

### TASK-00-03: Oban Transactionality Confirmation
**Priority:** Critical
**Effort:** M
**Depends on:** None
**Description:**
Write a detailed document confirming the transactional guarantees for Oban job management in all reminder-related operations. The document must show pseudocode for how `enqueued_oban_job_ids` updates, Oban job insertion (`Oban.insert/2`), and Oban job cancellation (`Oban.cancel_job/1`) happen inside the same `Ecto.Multi` transaction.

**Operations that must be covered:**

1. **Reminder Create:** Insert reminder row → insert Oban jobs → store job IDs in `enqueued_oban_job_ids` — all in one `Ecto.Multi`.

2. **Reminder Update:** Cancel existing Oban jobs listed in `enqueued_oban_job_ids` → update reminder row → insert new Oban jobs → update `enqueued_oban_job_ids` — all in one `Ecto.Multi`.

3. **Reminder Delete:** Cancel all Oban jobs in `enqueued_oban_job_ids` → delete reminder row — all in one `Ecto.Multi`.

4. **Contact Archive:** For all active reminders on the contact: cancel all Oban jobs in `enqueued_oban_job_ids` → set reminder `active: false` → clear `enqueued_oban_job_ids` → set contact `archived: true` — all in one `Ecto.Multi`.

5. **Contact Soft-Delete:** Same as archive but sets `deleted_at` instead. All reminder jobs cancelled within the same transaction.

6. **Contact Merge:** For the non-survivor contact: cancel all Oban jobs for non-survivor's reminders → remap survivor-kept reminders → soft-delete non-survivor — all in one `Ecto.Multi`. For reminders that move to the survivor: new Oban jobs are enqueued for the survivor's schedule.

7. **Stay-in-Touch Reset (Activity/Call logged):** Cancel pending stay-in-touch Oban jobs → resolve pending `ReminderInstance` → compute next fire date → enqueue new Oban jobs → update `enqueued_oban_job_ids` — all in one `Ecto.Multi`.

**For each operation, the document must show:**
- The `Ecto.Multi` pipeline steps in order
- Where `Oban.insert/2` is called (inside Multi via `Oban.insert/4` or `Multi.run/3`)
- Where `Oban.cancel_job/1` is called
- How `enqueued_oban_job_ids` is updated atomically
- What happens if any step fails (full rollback)

**Acceptance Criteria:**
- [ ] Document exists at `docs/oban-transactionality.md` in the repo
- [ ] All 7 operations listed above are covered with pseudocode Multi pipelines
- [ ] Each operation explicitly shows job insertion and cancellation within the Multi
- [ ] Document confirms that a failure at any step rolls back the entire transaction
- [ ] Pre-notification jobs (30-day, 7-day, on-day) are addressed for birthday and one-time reminders
- [ ] Document reviewed by at least 1 team member

**Phase 02+ Gate — ADR-03 Enforcement:**
> Before any code is merged in Phase 02 or later, confirm ALL of the following:
> - [ ] ADR-03 (Oban transactionality) document exists at `docs/adr/adr-003-oban-transactionality.md` and is approved
> - [ ] Every job-enqueue call in the codebase uses `Oban.insert/2` inside `Ecto.Multi` (via `Oban.insert/4` or `Multi.run/3`) — standalone `Oban.insert/2` outside a Multi is a merge-blocking violation
> - [ ] This checklist is reviewed as a required PR check before Phase 02 begins

**Safeguards:**
> ⚠️ Oban job insertion outside of an `Ecto.Multi` transaction creates a race condition: the reminder row could be committed without the job, or vice versa. NEVER use `Oban.insert/2` standalone for reminder operations — always use `Oban.insert/4` (the Multi-aware variant) or wrap in `Multi.run/3`.

**Notes:**
- Oban supports `Oban.insert/4` for inserting jobs within an `Ecto.Multi`
- `Oban.cancel_job/1` can be wrapped in `Multi.run/3` for transactional cancellation
- Reference: Product spec section 7 (Notifications & Reminders), especially the "Oban job cancellation on reminder changes" subsection

---

### TASK-00-04: Architecture Decision Records (ADRs)
**Priority:** High
**Effort:** M
**Depends on:** None
**Description:**
Write Architecture Decision Records documenting key technology choices. Each ADR should follow a standard format: Title, Status, Context, Decision, Consequences (positive and negative), and Alternatives Considered.

**ADR-001: Elixir over Rails/Django**
- Context: Choosing the backend language/framework for a self-hosted PRM
- Decision: Elixir + Phoenix
- Key arguments: OTP fault isolation (supervisor trees for background jobs, WebSocket connections), native Oban integration (PostgreSQL-backed, no external broker), LiveView eliminates JS framework complexity, pattern matching + immutable data for domain logic, excellent concurrency model for multi-tenant workloads
- Acknowledged tradeoff: Smaller hiring pool compared to Ruby/Python ecosystems
- Alternatives: Ruby on Rails (larger ecosystem, more developers), Django (Python ecosystem, mature ORM), Node.js/Express (JS everywhere)

**ADR-002: REST over GraphQL**
- Context: Choosing the API paradigm for v1, with a future mobile app in mind
- Decision: REST with `?include=` compound documents
- Key arguments: Data model maps cleanly to REST resources, avoids N+1 at GraphQL resolver boundaries without mandatory DataLoader, HTTP caching and CDN compatibility, simpler per-endpoint rate limiting, per-route access logging, `?include=` convention prevents over-fetching
- Acknowledged tradeoff: Multiple requests for complex data vs single GraphQL query
- Alternatives: GraphQL via Absinthe (flexible queries, but complexity overhead for well-defined resources), JSON:API (too rigid for our needs)

**ADR-003: PKCE OAuth Library Confirmation**
- Context: Mobile OAuth flows require PKCE; must confirm library support before v1 ships
- Decision: Use `assent` library for social OAuth with PKCE
- Verification checklist:
  - [ ] `assent` supports PKCE code challenge generation
  - [ ] `assent` supports `code_challenge_method=S256`
  - [ ] Integration tested with at least GitHub and Google OAuth providers
  - [ ] PKCE flow works end-to-end in test environment
- Alternatives: `ueberauth` (larger ecosystem but PKCE support varies by strategy), custom OAuth client (maintenance burden)

**ADR-004: Elixir/OTP Background Job Architecture** _(already covered in ADR-001 context; see TASK-00-03 for Oban transactionality detail)_

**ADR-005: REST over GraphQL**
- Context: Choosing the API paradigm for v1, with a future mobile app in mind; GraphQL was evaluated
- Decision: REST with `?include=` compound documents
- Rationale: Simpler client integration — REST resources map cleanly to domain entities, no N+1 resolver complexity, compound documents via `?include=` handle eager loading without mandatory DataLoader, HTTP caching and CDN compatibility, per-endpoint rate limiting, per-route access logging
- Consequences (positive): Easier onboarding for API consumers, no client-side query language required, straightforward per-resource authorization
- Consequences (negative): Multiple round-trips for deeply nested data; `?include=` convention must be consistently documented
- Alternatives: GraphQL via Absinthe (flexible queries but adds resolver/DataLoader complexity for well-defined resources), JSON:API (too rigid)

**ADR-006: Soft-Delete Scope**
- Context: Deciding which entities support recovery vs. immediate hard-deletion
- Decision: Soft-delete (`deleted_at`) applies ONLY to the `contacts` table. All other entities hard-delete via cascade.
- Rationale: Contacts have recoverable business value — a mis-deleted contact can be restored without data loss. Sub-entities (notes, activities, calls, reminders, etc.) exist only in the context of a contact and have no independent recovery value. Extending soft-delete to all tables would require global `WHERE deleted_at IS NULL` guards on every query, increasing complexity and bug surface.
- Consequences (positive): Recovery path for contacts; simpler queries on all non-contact tables
- Consequences (negative): Sub-entity data is permanently lost when a contact is hard-deleted from trash; must be communicated clearly in the UI
- Alternatives: Soft-delete all tables (too complex, monotonic table growth), hard-delete contacts immediately (no recovery path)

**ADR-007: Immich Integration Scope**
- Context: Kith optionally integrates with a user's self-hosted Immich instance for contact photo suggestions
- Decision: Immich integration is read-only. Kith never writes to Immich. Photo suggestions are conservative (exact name match only). The user must explicitly confirm before any photo is attached to a contact.
- Rationale: Read-only minimizes security surface and eliminates risk of corrupting a user's photo library. Conservative matching (exact name, not fuzzy) prevents false-positive suggestions. Explicit confirmation ensures no photo is silently applied without user intent.
- Consequences (positive): No risk of modifying user's Immich library; predictable, trustworthy suggestion UX
- Consequences (negative): May miss valid matches where names differ slightly; requires user action for every attachment
- Alternatives: Write-back to Immich (rejected — risk of library corruption), fuzzy name matching (rejected — too many false positives in v1)

**Acceptance Criteria:**
- [ ] ADR files exist at `docs/adr/adr-001-elixir.md`, `docs/adr/adr-002-rest.md`, `docs/adr/adr-003-pkce.md`, `docs/adr/adr-005-rest-vs-graphql.md`, `docs/adr/adr-006-soft-delete-scope.md`, `docs/adr/adr-007-immich-integration.md`
- [ ] Each ADR follows the standard format: Title, Status, Context, Decision, Consequences, Alternatives
- [ ] ADR-001 acknowledges the hiring pool tradeoff
- [ ] ADR-002/ADR-005 explains the `?include=` convention as the REST answer to GraphQL's flexible querying
- [ ] ADR-003 includes a concrete PKCE verification checklist that must be completed before v1 ships
- [ ] ADR-005 explicitly states "simpler client integration" and "no N+1 resolver complexity" as rationale
- [ ] ADR-006 explicitly states the scope boundary: soft-delete on contacts only, all others cascade hard-delete
- [ ] ADR-007 explicitly states read-only constraint, exact-name-match-only suggestion policy, and required explicit user confirmation

**Safeguards:**
> ⚠️ ADR-003 is not just a document — it includes a verification checklist. The PKCE checklist items must be actually tested (not just documented) before the auth phase ships. Flag this to the auth-architect.
> ⚠️ ADR-006 and ADR-007 are binding constraints, not preferences. Any code that soft-deletes non-contact entities, writes to Immich, or auto-attaches photos without confirmation is a merge-blocking violation.

**Notes:**
- Reference: Product spec section 13 (Tech Stack Summary) for ADR rationale
- Reference: Product spec section 4 (API Design) for REST rationale
- Reference: Product spec section 5 (Authentication) for PKCE requirements
- Reference: Product spec section 8 (Immich Integration) for ADR-007

---

### TASK-00-05: Dependency Audit
**Priority:** High
**Effort:** S
**Depends on:** None
**Description:**
Enumerate all Hex packages and npm packages needed for Kith v1. For each dependency, list: package name, version (pinned to latest stable at time of writing), purpose, and whether it's a runtime or dev/test dependency.

**Hex packages (Elixir):**

| Package | Purpose | Type |
|---------|---------|------|
| `phoenix` | Web framework | Runtime |
| `phoenix_html` | HTML helpers | Runtime |
| `phoenix_live_view` | LiveView server-rendered UI | Runtime |
| `phoenix_live_reload` | Dev live reload | Dev |
| `phoenix_live_dashboard` | Dev dashboard | Dev |
| `ecto_sql` | Database ORM | Runtime |
| `postgrex` | PostgreSQL driver | Runtime |
| `oban` | Background job processing | Runtime |
| `oban_web` | Oban admin dashboard | Runtime |
| `swoosh` | Email sending | Runtime |
| `gen_smtp` | SMTP adapter for Swoosh | Runtime |
| `ex_aws` | AWS SDK core | Runtime |
| `ex_aws_s3` | S3 file storage | Runtime |
| `req` | HTTP client | Runtime |
| `pot` | TOTP 2FA | Runtime |
| `wax` | WebAuthn/FIDO2 (note: package atom is `:wax`, NOT `:wax_`) | Runtime |
| `assent` | Social OAuth with PKCE | Runtime |
| `hammer` | Rate limiting | Runtime |
| `hammer_backend_redis` | Redis backend for Hammer (optional) | Runtime |
| `redix` | Redis client — required when `RATE_LIMIT_BACKEND=redis` | Runtime |
| `plug_remote_ip` | Real client IP resolution behind reverse proxy (Caddy) | Runtime |
| `cachex` | In-memory cache | Runtime |
| `timex` | Timezone/date handling | Runtime |
| `gettext` | i18n string translations | Runtime |
| `ex_cldr` | CLDR locale data | Runtime |
| `ex_cldr_dates_times` | Locale-aware date/time formatting | Runtime |
| `ex_cldr_numbers` | Locale-aware number/currency formatting | Runtime |
| `logger_json` | JSON structured logging | Runtime |
| `sentry` | Error tracking | Runtime |
| `prom_ex` | Prometheus metrics (replaces deprecated prometheus_ex) | Runtime |
| `plug_content_security_policy` | CSP headers | Runtime |
| `jason` | JSON encoding/decoding | Runtime |
| `bcrypt_elixir` | Password hashing | Runtime |
| `floki` | HTML parsing (Phoenix dep) | Runtime |
| `telemetry_metrics` | Telemetry metrics definitions | Runtime |
| `telemetry_poller` | Telemetry periodic measurements | Runtime |
| `esbuild` | JS bundling | Dev |
| `tailwind` | CSS framework | Dev |
| `credo` | Static analysis | Dev/Test |
| `dialyxir` | Type checking | Dev |
| `ex_machina` | Test factories | Test |
| `mox` | Test mocking | Test |
| `wallaby` | Browser E2E testing | Test |

**npm packages (via assets/package.json):**

| Package | Purpose |
|---------|---------|
| `trix` | Rich text editor for notes |
| `alpinejs` | UI chrome interactions |
| `heroicons` | Icon set (if not using Phoenix built-in) |

**Acceptance Criteria:**
- [ ] Document exists at `docs/dependency-audit.md` in the repo
- [ ] Every Hex package listed above is included with a pinned version number
- [ ] npm packages are listed separately
- [ ] Each dependency has its purpose documented
- [ ] Runtime vs dev/test classification is correct for every package
- [ ] No packages are included that conflict with spec decisions (e.g., no `waffle`, no `absinthe`, no `ueberauth`)
- [ ] License compatibility verified (all packages must be MIT, Apache 2.0, or similarly permissive)
- [ ] The following packages are explicitly present and audited:
  - [ ] `wax` — WebAuthn/FIDO2 (package atom is `:wax`, NOT `:wax_` — verify the correct atom in mix.exs)
  - [ ] `ex_aws` — AWS SDK core (required separately from `ex_aws_s3`)
  - [ ] `ex_aws_s3` — S3 file storage (required separately; both `ex_aws` and `ex_aws_s3` must be listed)
  - [ ] `redix` — Redis client, required when `RATE_LIMIT_BACKEND=redis` is configured
  - [ ] `plug_remote_ip` — real client IP resolution behind Caddy reverse proxy

**Safeguards:**
> ⚠️ Do NOT include `waffle` — the spec explicitly says to use `ex_aws` directly with a custom `Kith.Storage` wrapper. Do NOT include `absinthe` or any GraphQL library. Do NOT include `ueberauth` — use `assent` for OAuth. Verify that `prometheus_ex` is not deprecated in favor of `prom_ex` at the time of implementation.
> ⚠️ The WebAuthn package atom is `:wax`, NOT `:wax_`. Using `:wax_` in mix.exs will pull a different (possibly unmaintained) package. Double-check this before finalizing the audit.

**Notes:**
- Pin versions to latest stable at implementation time, not at spec writing time
- The version numbers in this audit are targets — verify each one compiles cleanly together before finalizing
- Reference: Product spec section 13 (Tech Stack Summary)

---

### TASK-00-06: API Conventions Document

**Owner:** Tech Lead
**Blocker for:** Phase 10 (REST API)
**Description:** Before Phase 10 begins, produce a written document defining the REST API conventions for this project. This document must be reviewed by at least 2 engineers before Phase 10 starts.

**Document must define:**
- REST response envelope shape
- `?include=` compound document format and nesting rules
- Cursor pagination structure: `next_cursor`, `has_more`, cursor encoding (base64 opaque token)
- RFC 7807 error response format (all error fields: `type`, `title`, `status`, `detail`, `instance`)
- All HTTP status codes used and their specific trigger conditions (200, 201, 204, 400, 401, 403, 404, 409, 422, 500, 501)

**Acceptance criteria:**
- Document exists at `docs/api-conventions.md`
- All fields and status codes documented with examples
- Reviewed and approved by 2 engineers
- Phase 10 tasks reference this document

---

### TASK-00-07: Configuration & Integration Audit

**Owner:** Tech Lead
**Blocker for:** Phase 01 TASK-01-NEW-F (`.env.example`)
**Description:** Enumerate ALL environment variables for the application. Document each with: name, type, default value, which phase configures it, and whether it is required or optional.

**Variables to document (minimum):**
- `SENTRY_DSN` — string, optional, Phase 07
- `SENTRY_ENVIRONMENT` — string, default "production", Phase 07
- `IMMICH_BASE_URL` — URL string, optional, Phase 07
- `IMMICH_API_KEY` — string, optional, Phase 07
- `IMMICH_SYNC_INTERVAL_HOURS` — integer, default 24, Phase 07
- `LOCATION_IQ_API_KEY` — string, optional, Phase 05
- `ENABLE_GEOLOCATION` — boolean, default false, Phase 05
- `DISABLE_SIGNUP` — boolean, default false, Phase 01
- `SIGNUP_DOUBLE_OPTIN` — boolean, default true, Phase 02
- `MAX_UPLOAD_SIZE_KB` — integer, default 5120, Phase 05
- `MAX_STORAGE_SIZE_MB` — integer, default 1024, Phase 05
- `KITH_HOSTNAME` — string, required in prod, Phase 01
- `RATE_LIMIT_BACKEND` — enum (ets|redis), default ets, Phase 01
- `TRUSTED_PROXIES` — comma-separated CIDRs, default "127.0.0.1/8", Phase 01
- `GEOIP_DB_PATH` — string, optional, Phase 07
- `METRICS_TOKEN` — string, required in prod, Phase 12
- `AWS_S3_BUCKET`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_REGION` — optional, Phase 05
- `STORAGE_PATH` — string, default "/app/uploads", Phase 13

**Decision note (record in this task):** Rate limiting backend defaults to ETS. Redis migration path: set `RATE_LIMIT_BACKEND=redis` and configure `REDIS_URL`. ETS is sufficient for single-node deployments; Redis required for multi-node. When Redis is configured, an unavailable server or a version older than Redis 7 prevents startup. Runtime Redis errors fail the rate-limited operation; never fall back to independent ETS counters or authorize requests on backend failure.

**Acceptance criteria:**
- Document exists at `docs/configuration.md`
- All variables listed with type, default, phase, required/optional
- Rate limit backend decision documented
- Phase 01 TASK-01-NEW-F can reference this document

---

## E2E Product Tests

### TEST-00-01: ERD Document Review Gate
**Type:** Manual (Document Review)
**Covers:** TASK-00-01

**Scenario:**
This test validates that the ERD document is complete and has been reviewed before any migration code is written. A reviewer opens the ERD document and verifies that all 27 tables are present with complete column definitions.

**Steps:**
1. Open `docs/erd.md` in the repository
2. Verify all 27 tables are listed with columns, types, nullable flags, and defaults
3. Verify the soft-delete constraint (only on contacts table)
4. Verify `audit_logs.contact_id` has NO foreign key
5. Verify the unique index on relationships
6. Verify `enqueued_oban_job_ids` jsonb on reminders
7. Confirm at least 2 review approvals exist (PR comments or sign-off)

**Expected Outcome:**
All tables documented, all constraints verified, at least 2 reviewers have signed off.

---

### TEST-00-02: Frontend Conventions Document Completeness
**Type:** Manual (Document Review)
**Covers:** TASK-00-02

**Scenario:**
Verify that the frontend conventions document covers all required sections and is actionable for developers building LiveView screens.

**Steps:**
1. Open `docs/frontend-conventions.md`
2. Verify component hierarchy defines all 3 levels with examples
3. Verify Alpine.js scope boundary includes correct/incorrect usage examples
4. Verify RTL conventions mention logical Tailwind properties and the root layout `dir` attribute
5. Verify `Kith.Policy.can?/3` interface lists action and resource atoms

**Expected Outcome:**
Document is complete, actionable, and ready to serve as a PR gate for the first LiveView screen.

---

### TEST-00-03: Oban Transactionality Document Completeness
**Type:** Manual (Document Review)
**Covers:** TASK-00-03

**Scenario:**
Verify that the Oban transactionality document covers all 7 reminder operations with Multi pseudocode.

**Steps:**
1. Open `docs/oban-transactionality.md`
2. Verify all 7 operations are covered: reminder create, update, delete, contact archive, soft-delete, merge, stay-in-touch reset
3. For each operation, verify the Multi pipeline shows job insertion/cancellation steps
4. Verify pre-notification handling for birthday and one-time reminders

**Expected Outcome:**
All 7 operations documented with transactional pseudocode showing no race conditions.

---

### TEST-00-04: ADR Completeness
**Type:** Manual (Document Review)
**Covers:** TASK-00-04

**Scenario:**
Verify that all required ADRs exist and follow the standard format.

**Steps:**
1. Open `docs/adr/adr-001-elixir.md` — verify it covers Elixir rationale with tradeoffs
2. Open `docs/adr/adr-002-rest.md` — verify it covers REST rationale with `?include=` convention
3. Open `docs/adr/adr-003-pkce.md` — verify it includes a PKCE verification checklist
4. Open `docs/adr/adr-005-rest-vs-graphql.md` — verify rationale includes "simpler client integration" and "no N+1 resolver complexity"
5. Open `docs/adr/adr-006-soft-delete-scope.md` — verify it states soft-delete applies ONLY to contacts, all other entities hard-delete via cascade
6. Open `docs/adr/adr-007-immich-integration.md` — verify it states read-only constraint, exact-name-match-only, and required explicit user confirmation

**Expected Outcome:**
All ADRs exist with standard format, clear reasoning, acknowledged tradeoffs, and binding constraints documented.

---

### TEST-00-05: Dependency Audit Completeness
**Type:** Manual (Document Review)
**Covers:** TASK-00-05

**Scenario:**
Verify that the dependency audit lists all required packages with no prohibited dependencies.

**Steps:**
1. Open `docs/dependency-audit.md`
2. Verify all Hex packages from the spec are listed with versions
3. Verify npm packages (trix, alpinejs) are listed
4. Verify NO prohibited packages are present: waffle, absinthe, ueberauth
5. Verify each package has purpose and runtime/dev classification
6. Verify `wax` is listed with atom `:wax` (NOT `:wax_`)
7. Verify both `ex_aws` and `ex_aws_s3` are listed as separate entries
8. Verify `redix` is listed with note that it is required when `RATE_LIMIT_BACKEND=redis`
9. Verify `plug_remote_ip` is listed for real IP resolution behind Caddy

**Expected Outcome:**
Complete dependency inventory with pinned versions, no prohibited packages, and all required packages explicitly audited.

---

## Phase Safeguards
- No code may be written until ALL tasks in this phase are complete and reviewed
- The ERD document requires 2 reviewer sign-offs before any migration file is created
- The frontend conventions document is a PR gate for the first contact profile LiveView
- ADR-003 (PKCE) includes a verification checklist that must be actually tested, not just documented
- **ADR-03 Phase 02 gate:** Before any code is merged in Phase 02 or later, confirm ADR-03 (Oban transactionality) is documented and all job-enqueue code uses `Oban.insert/2` inside `Ecto.Multi`. Standalone `Oban.insert/2` outside a Multi is a merge-blocking violation.
- ADR-006 (soft-delete scope) and ADR-007 (Immich read-only) are binding constraints enforced in code review
- All documents must be committed to the repository, not stored externally

## Phase Notes
- This phase is entirely documentation — zero lines of application code
- The ERD from TASK-00-01 is the single source of truth for all migration tasks in Phase 03
- The dependency audit from TASK-00-05 feeds directly into Phase 01 (Foundation) dependency installation
- The Oban transactionality document from TASK-00-03 is the blueprint for Phase 06 (Reminders) implementation
- Consider using a shared review session or async PR review to parallelize the 2-reviewer requirement on the ERD
