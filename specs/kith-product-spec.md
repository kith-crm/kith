# Kith — Product Specification
> Version: 1.0 (finalized after 2-round team review)
> Purpose: Reference spec for building Kith from scratch

---

## 1. Product Overview

**Kith is a Personal Relationship Manager (PRM)** — a CRM for your personal life. It helps individuals organize, document, and maintain meaningful relationships with family and friends.

**Target user (v1):** Technical self-hosters — developers, sysadmins, and Docker-comfortable individuals who already run self-hosted software. Kith v1 is not a consumer product. A hosted offering is v2.

**Core philosophy:**
- Privacy-first: self-hostable, no tracking, user owns their data
- Not a social network — purely a personal tool
- Simple, structured, and memorable
- No vendor lock-in (open source, data export/import, API)
- Mobile-ready API: REST-first design supports a future native mobile app

**Primary use case:** "Never forget important details about the people you care about."

---

## 2. v1 Feature Scope

### In — v1

| # | Feature | Notes |
|---|---------|-------|
| 1 | Contact Management | Create, edit, search, tag, favorite, archive, soft-delete with 30-day trash |
| 2 | Contact Fields | Email, phone, social — custom typed; field types fully customizable |
| 3 | Addresses | Physical addresses with GPS coordinates via LocationIQ |
| 4 | Relationship Mapping | Typed links between contacts; relationship types fully customizable |
| 5 | Notes | Freeform, markdown, favoritable; `private` schema flag (enforcement v1.5) |
| 6 | Life Events | Graduation, wedding, birth, etc. — hard-coded types in v1 |
| 7 | Activities | Logged interactions, many-to-many contacts, emotions (hard-coded set) |
| 8 | Calls | Phone interactions with emotional state |
| 9 | Reminders | Birthday (auto-created), stay-in-touch, one-time, recurring |
| 10 | Tags | User-defined labels; bulk assign/remove |
| 11 | Contact Merge | Manual; sub-entities remapped; non-survivor soft-deleted for 30 days |
| 12 | Multi-User Accounts | Admin / Editor / Viewer roles; invitation-based onboarding |
| 13 | Immich Integration | Read-only; conservative exact-name auto-suggest; user confirms every link |
| 14 | Data Export | vCard (.vcf), JSON |
| 15 | Data Import | vCard — creates new contacts only; no upsert; no duplicate detection |
| 16 | Authentication | Email/password, TOTP 2FA, social OAuth (PKCE), WebAuthn, recovery codes |
| 17 | Account Settings | Timezone, locale, send hour, custom genders, relationship types |
| 18 | Upcoming Reminders View | Top-level nav; 30/60/90-day window; all roles |
| 19 | Audit Log | Contact created/edited/archived/deleted; reminder fired; filterable |
| 20 | API | REST; `?include=` compound docs; cursor pagination; RFC 7807 errors |

### Deferred — v1.5

Tasks, Journal, Pets, Gifts, Debt tracking, Weather, CardDAV/CalDAV, Conversations & messages, Reminder snooze, Duplicate contact detection, Customizable emotions / activity categories / life event types, `private` note enforcement, Previous name/alias search, Per-record privacy controls.

### Deferred — v2

Hosted/managed offering, mobile app (API is mobile-ready from day one; the app itself is not in scope).

---

## 3. Domain Model

### Top-Level Architecture

```
ACCOUNT (tenant/workspace)
  └─ Users (members, with admin/editor/viewer role)
  └─ Invitations (pending onboarding)
  └─ Modules (feature toggles)
  └─ Audit Logs
  └─ Contacts (all data below is account-scoped)
```

### Contact Entity (Central Hub)

```
Contact
  ├─ Identity: first_name, last_name, display_name, nickname, gender, birthdate, description, avatar
  ├─ Work: occupation, company
  ├─ State: favorite (bool), archived (bool), deceased (bool), last_talked_to (timestamp)
  ├─ Soft-delete: deleted_at (timestamptz, nullable) — see schema notes below
  ├─ ImmichLink: immich_person_id, immich_person_url, immich_status (:unlinked/:linked/:needs_review), immich_last_synced_at
  │
  ├─ Address[]            (with GPS coordinates, via LocationIQ)
  ├─ ContactField[]       (email, phone, social media — custom typed)
  ├─ Tag[]                (user-defined organizational labels)
  │
  ├─ Note[]               (freeform text, markdown, favoritable, private bool)
  ├─ Document[]           (file attachments, PDFs)
  ├─ Photo[]              (images, gallery)
  │
  ├─ LifeEvent[]          (graduation, wedding, birth, etc. — hard-coded types in v1)
  ├─ Relationship[]       (links to other Contacts via typed relationship)
  │
  ├─ Activity[]           (many-to-many: one activity can involve multiple contacts)
  │     └─ Emotions (hard-coded set in v1)
  ├─ Call[]               (phone interactions, with emotional state)
  │
  ├─ Reminder[]           (birthday, stay-in-touch, one-time, recurring)
  │     ├─ ReminderRule[] (how many days before to notify)
  │     └─ enqueued_oban_job_ids jsonb (Oban job IDs for cancellation tracking)
  └─ ReminderInstance[]   (fired reminder records; tracks :pending / :resolved / :dismissed)
```

### Journal System — DEFERRED to v1.5

### Customizable Reference Data (per Account)

| Reference Data | v1 | Notes |
|---|---|---|
| Genders | Fully customizable | Inclusivity requirement |
| Relationship Types | Fully customizable | Core to relationship-mapping feature |
| Contact Field Types | Fully customizable | Core to contact profiles |
| Emotions | Hard-coded defaults | Customizable in v1.5; seeded table (not enum) |
| Activity Type Categories | Hard-coded defaults | Customizable in v1.5; seeded table (not enum) |
| Life Event Types | Hard-coded defaults | Customizable in v1.5; seeded table (not enum) |
| Currencies | Reference data | Multi-currency support |

> **Schema note:** All six use seeded database tables (not Postgres enums). This ensures v1.5 customization is an additive migration (add `account_id` nullable FK + settings UI), not a schema rewrite.

### Schema Policies

**Soft-delete:** `contacts` table only. Column: `deleted_at timestamptz DEFAULT NULL`. All other tables use `ON DELETE CASCADE`. Default Ecto query scope on `Contact` filters `WHERE deleted_at IS NULL`. 30-day trash window; `ContactPurgeWorker` purges tombstoned contacts after 30 days. Admins can restore within 30 days; editors cannot.

**Indexes:**
- `CREATE INDEX contacts_active_idx ON contacts (account_id) WHERE deleted_at IS NULL` — default scope queries
- `CREATE INDEX contacts_trash_idx ON contacts (account_id, deleted_at) WHERE deleted_at IS NOT NULL` — trash view queries

**Audit log:** `contact_id` stored as plain integer (no FK constraint) + `contact_name` snapshot captured at event time. Entries survive contact hard-deletion. Intentional non-FK design.

**Relationship uniqueness:** Unique index on `(account_id, contact_id, related_contact_id, relationship_type_id)`. A contact may have multiple typed relationships to the same other contact if the types differ.

**Additive-only migrations (v1.x):** No column drops, table drops, or destructive renames until a major version. Deprecated columns get a `_deprecated_` prefix.

---

## 4. API Design

### Strategy: REST

REST over GraphQL. Phoenix controllers with JSON serializers (e.g., `Jason`-based views). GraphQL (Absinthe) deferred — add if mobile demand proves it necessary.

**Rationale:** The data model maps cleanly to REST resources. GraphQL's N+1 problem at resolver boundaries is a real v1 risk without mandatory DataLoader. HTTP caching, CDN compatibility, rate-limiting per-endpoint, and per-route access logging are all simpler with REST. A well-designed REST API is equally mobile-friendly.

### REST Conventions

- **Compound documents:** `GET /api/contacts/:id?include=relationships,reminders,notes` — uniform `?include=` parameter applied across all top-level resources. Defined before any controller is written.
- **Pagination:** Cursor-based on all list endpoints. Request: `?after=cursor&limit=20`. Response includes `next_cursor` and `has_more`.
- **Error format:** RFC 7807 Problem Details on all error responses.
- **Auth:** Bearer token in `Authorization` header. All API endpoints require auth.

### Resource Overview

| Resource | Operations |
|----------|-----------|
| `/api/contacts` | List, Create, Show, Update, Delete, Archive, Favorite + Merge |
| `/api/relationships` | Full CRUD; list by contact |
| `/api/notes` | Full CRUD; list by contact |
| `/api/activities` | Full CRUD; list by contact |
| `/api/calls` | Full CRUD; list by contact |
| `/api/reminders` | Full CRUD; list; upcoming |
| `/api/documents` | Create, Delete; list by contact |
| `/api/photos` | Create, Delete; list by contact |
| `/api/life_events` | Full CRUD; list by contact |
| `/api/tags` | Full CRUD; set/unset on contacts |
| `/api/addresses` | Full CRUD; list by contact |
| `/api/contact_fields` | Full CRUD; list by contact |
| `/api/genders` | Full CRUD |
| `/api/relationship_types` | Full CRUD |
| `/api/contact_field_types` | Full CRUD |
| `/api/account` | Get, Update |
| `/api/me` | Get, Update |
| `/api/statistics` | Read-only instance stats |
| `/api/devices` | `POST` returns 501 (mobile push stub) |

### Mobile App Readiness

- `?include=` compound document convention (no over-fetching per-request)
- Cursor-based pagination on all list endpoints
- `POST /api/devices` stub returning 501 as integration point for future push notification support
- PKCE support confirmed in OAuth library before v1 ships (required for mobile OAuth flow)
- RFC 7807 error format for consistent mobile error handling
- No server-side session required — all API access via Bearer tokens

### Protocol Support (v1)

- **vCard** — import/export individual contacts and bulk

### Protocol Support (v1.1 roadmap)

- **CardDAV** — sync contacts with external address books
- **CalDAV** — sync reminders/events with calendar apps
- Well-known redirects: `/.well-known/carddav`, `/.well-known/caldav`

> No mature Elixir CardDAV/CalDAV server library exists. Will be evaluated for v1.1 as either a minimal Plug-based implementation or a sidecar approach.

---

## 5. Authentication & Security

| Feature | Implementation |
|---------|---------------|
| Standard login | Email + password (Bcrypt via `phx_gen_auth`) |
| Two-Factor Auth (TOTP) | Google Authenticator via `pot` library |
| Passwordless / WebAuthn | FIDO2/U2F via `wax` library |
| Social OAuth (login) | `assent` library (GitHub, Google, etc.) with PKCE |
| API Bearer tokens | `phx_gen_auth`-issued tokens; no separate OAuth2 server in v1 |
| Recovery codes | 2FA backup codes |
| Email verification | Required on signup (configurable) |
| Rate limiting | Per-IP and per-account via `hammer` (ETS backend; Redis for multi-node) |
| Audit logging | All account actions logged async via Oban |
| CSRF protection | Phoenix built-in |
| Secure headers | `plug_content_security_policy` |
| Session security | Encrypted cookies, HTTPS-only, SameSite=Strict |

---

## 6. Multi-Tenancy & Account Model

- **Account** = workspace/tenant. Owns all data.
- **Users** belong to an Account. Multiple users per account (shared data).
- **Invitation flow**: Email-based invite → accept via unique key → join account with assigned role.
- **Roles:**
  - `admin` — full access + user management + account deletion + restore soft-deleted contacts
  - `editor` — create/update/delete all data, import/export, trigger Immich sync
  - `viewer` — read-only; can update personal settings only
- **Authorization:** Single `Kith.Policy.can?(user, action, resource)` function. Used in LiveView `mount/3`, function component templates, and context function guards. Viewer-restricted controls are hidden (not grayed). 403 pages explain the role limitation and link to account admin.
- All data models carry `account_id` FK — full row-level tenant isolation.
- **Data reset** and **account deletion** both available to admins from settings.

---

## 7. Notifications & Reminders

### Reminder Types

- `birthday` — auto-created from contact birthdate; auto-fires annually
- `stay_in_touch` — per-contact frequency setting based on `last_talked_to`
- `one_time` — fires once on a specified date
- `recurring` — week / month / year intervals

### Stay-in-Touch Semantics

- Per-contact frequency: weekly, 2 weeks, monthly, 3 months, 6 months, annually
- Triggered by: Activity or Call logged against the contact (not notes, life events, or reminder creation)
- `last_talked_to` updated account-wide (any user logging against the contact updates it)
- Does not re-fire while a `ReminderInstance` with `status: :pending` exists for that reminder
- Re-fires one full interval after the `ReminderInstance` is resolved or dismissed
- No snooze in v1
- Archiving disables stay-in-touch; unarchiving does not auto-re-enable (must manually re-enable)

### Oban Workers

| Worker | Responsibility |
|--------|---------------|
| `ReminderSchedulerWorker` | Runs nightly; enqueues due reminder notification jobs |
| `ReminderNotificationWorker` | Sends notification emails for due reminders |
| `ImmichSyncWorker` | Periodic Immich person sync (configurable interval, default 24h) |
| `ContactPurgeWorker` | Nightly; hard-deletes contacts soft-deleted > 30 days ago |

### Reminder Scheduler Behavior (Specification)

1. **DST handling:** Always use IANA timezone names. Compute UTC offset at scheduling time via `Timex`. Never store UTC offsets. `America/New_York` fires at 14:00 UTC in winter, 13:00 UTC in summer — both correct.

2. **February 29 in non-leap years:** Fire on February 28. Consistent with iOS/Google Calendar. No special messaging required.

3. **Unacknowledged reminders:** A stay-in-touch reminder does not re-enqueue while a `ReminderInstance` with `status: :pending` exists. Scheduler checks before enqueuing.

4. **Oban job cancellation on reminder changes:** `reminders` table has `enqueued_oban_job_ids jsonb DEFAULT '[]'`. When a reminder is edited, the contact is archived, soft-deleted, merged, or the reminder deleted — all Oban job IDs in this array are cancelled and the array is cleared. Cancellation is wrapped in the same `Ecto.Multi` transaction as the reminder change (using `Oban.insert/2` for insertion, `Oban.cancel_job/1` for cancellation). Crash safety is guaranteed by transactionality.

5. **Send-hour changes:** Up to 24-hour drift is acceptable. Already-enqueued jobs fire at the old send hour. Next nightly run enqueues at the new send hour. Settings UI states: "Changing your send hour takes effect starting the following day."

6. **Pre-notification sets:** Birthday and one-time reminders support 30-day and 7-day pre-notifications. All three job IDs (30-day, 7-day, on-day) are stored in `enqueued_oban_job_ids`. All three are cancelled when the stay-in-touch resets via a logged Activity or Call.

### Reminder Delivery Timing

- Configurable per account: `send_hour` (integer 0–23, wall-clock in account timezone)
- Pre-notifications: 30 days and 7 days before (configurable via ReminderRules, toggleable per account)
- All scheduling uses IANA timezone from `account.timezone`

---

## 8. Integrations & External Services

| Category | Service | Notes |
|----------|---------|-------|
| **Email** | SMTP, Mailgun, Amazon SES, Postmark | Via **Swoosh** adapter system |
| **Geocoding** | LocationIQ | Address → GPS; `LOCATION_IQ_API_KEY`; `ENABLE_GEOLOCATION` flag |
| **Weather** | — | Deferred to v1.5 |
| **IP Geolocation** | Cloudflare, IPInfo, MaxMind | IP → location via `remote_ip` plug |
| **File Storage** | Local disk or AWS S3 | Direct `ex_aws` wrapper (not Waffle) |
| **Error Tracking** | Sentry | Via `sentry-elixir` |
| **CDN / Proxy** | Cloudflare | Trusted proxy detection |
| **Cache** | ETS / Cachex | In-memory; Redis optional for multi-node |
| **Background Jobs** | **Oban** (PostgreSQL-backed) | No external broker required |
| **Rate Limiting** | `hammer` | ETS (single-node); Redis (multi-node — see `RATE_LIMIT_BACKEND`) |
| **Email testing (dev)** | Mailpit | Local SMTP catch-all in `docker-compose.dev.yml` |
| **HTTP Client** | `req` | All external API calls |
| **2FA** | Google Authenticator | Via `pot` TOTP library |
| **Passwordless** | WebAuthn (FIDO2) | Via `wax` library |
| **Immich** | Self-hosted photo app | Read-only; person linking — see below |

### File Storage

Direct `ex_aws` with a small custom `Kith.Storage` wrapper: `Kith.Storage.upload(file, path)` → returns URL. Local dev uses MinIO (in `docker-compose.dev.yml` only). Production can use local disk or S3-compatible storage. Avoids Waffle's ImageMagick system dependency.

### Immich Integration

**Goal:** Link a Kith contact to an Immich person entity, providing a direct link to their Immich page.

**Example link:** `https://immich.example.com/people/66a8e873-d13d-4e54-8127-5a73077d2217`

**Behavior:**
- `ImmichSyncWorker` (Oban cron) calls the Immich API and attempts to match persons to Kith contacts by exact `first_name + last_name` match (case-insensitive).
- **Conservative matching:** A match is only suggested — never auto-confirmed. The user always confirms every link via the Immich Review UI.
- **Unambiguous match:** Exactly one Immich person matches → contact flagged as `immich_status: :needs_review` with the single candidate shown.
- **Multiple matches:** Multiple Immich persons share a name → contact flagged as `immich_status: :needs_review` with all candidates listed.
- **No match:** Contact remains `immich_status: :unlinked`.
- **Confirmed match:** User confirms → `immich_person_id` and `immich_person_url` stored, `immich_status: :linked`.
- **Read-only:** Kith never writes to or modifies Immich.
- **Link display:** "View in Immich" button on contact profile links to `IMMICH_BASE_URL/people/{immich_person_id}`.
- **Unlinking:** Users can manually unlink any contact.
- **Circuit breaker:** After 3 consecutive failed sync attempts, `ImmichSyncWorker` sets `account.immich_status: :error` and stops retrying. Error state visible in Settings > Integrations.
- **Manual sync:** "Sync Now" button in Settings > Integrations > Immich triggers immediate sync.
- **Sync status:** Account-level sync status in Settings > Integrations: last successful sync, next scheduled sync, error log.
- **Dashboard badge:** Count of contacts with `immich_status: :needs_review` displayed on dashboard.

**Immich API calls (read-only):**
- `GET /api/people` — list all persons with names
- `GET /api/people/{id}` — get person details (name, thumbnail URL)

**Contact schema additions:**
```
contacts
  immich_person_id       :string    (nullable)
  immich_person_url      :string    (nullable)
  immich_status          :enum      [:unlinked, :linked, :needs_review]  (default: :unlinked)
  immich_last_synced_at  :utc_datetime (nullable)
```

**Account schema additions:**
```
accounts
  immich_status          :enum      [:disabled, :ok, :error]  (default: :disabled)
  immich_last_synced_at  :utc_datetime (nullable)
```

**Configuration:**
```
IMMICH_BASE_URL=https://immich.example.com
IMMICH_API_KEY=your_api_key
IMMICH_ENABLED=true
IMMICH_SYNC_INTERVAL_HOURS=24
```

---

## 9. Settings & Personalization

### User-Level Settings
- Display name format (ordering options)
- Timezone, locale (Gettext + ex_cldr), currency, temperature unit
- Default profile tab (life-events / notes / photos)
- "Me" contact linkage (user maps themselves to a contact)

### Account-Level Settings
- Default reminder send hour
- Custom genders
- Custom relationship types
- Custom contact field types (with icons)
- Feature modules (toggle on/off)
- Reminder rules (how many days in advance)
- Tags management
- Users & invitations & roles
- Immich integration configuration

### Instance-Level Config (environment variables)

| Variable | Purpose |
|----------|---------|
| `DISABLE_SIGNUP` | Close registration |
| `SIGNUP_DOUBLE_OPTIN` | Require email verification |
| `MAX_UPLOAD_SIZE_KB` | File upload cap |
| `MAX_STORAGE_SIZE_MB` | Per-account storage cap |
| `ENABLE_GEOLOCATION` | LocationIQ on/off |
| `IMMICH_ENABLED` | Immich integration on/off |
| `RATE_LIMIT_BACKEND` | `ets` (default) or `redis` (multi-node) |
| `KITH_HOSTNAME` | Required for Caddy + LiveView WebSocket `check_origin` |
| `KITH_MODE` | `web` (default) or `worker` — controls container behavior |

---

## 10. Data Import / Export

| Format | Direction | Notes |
|--------|-----------|-------|
| vCard (.vcf) | Import & Export | Per contact or bulk; import creates only (no upsert, no duplicate detection) |
| JSON | Export | Structured full data export |

**Import behavior:** Creates new contacts only. No update of existing contacts. No duplicate detection. UI shows explicit note: "Import creates new contacts. Existing contacts are not updated. Review for duplicates after import."

---

## 11. Contact Merge

In v1. Manual only.

**Flow:**
1. User selects two contacts to merge and designates the survivor.
2. System runs a dry-run and shows the confirmation screen including any relationships that will be deduplicated.
3. On confirm, transaction executes: (a) remap all sub-entity FKs from non-survivor to survivor, (b) delete exact same-type relationship duplicates to the same third contact (keep survivor's version), (c) preserve different-type relationships to the same third contact, (d) soft-delete non-survivor for 30-day recovery window.

**Relationship deduplication rule:** Unique index on `(account_id, contact_id, related_contact_id, relationship_type_id)`. Multiple typed relationships to the same contact are valid; exact duplicates are not.

---

## 12. Frontend Architecture

### Stack: Phoenix LiveView + TailwindCSS

| Layer | Technology |
|-------|-----------|
| Framework | Phoenix LiveView |
| CSS | TailwindCSS (utility-first; logical properties for RTL) |
| Icons | Heroicons (built into Phoenix 1.7) |
| JS sprinkles | Alpine.js — UI chrome only (see scope boundary below) |
| Rich text | Trix editor via LiveView hook (for notes) |
| i18n | Gettext (strings) + **`ex_cldr`** (dates, numbers, currencies) |
| Build | esbuild (built into Phoenix 1.7+) |
| Testing | ExUnit (unit), Playwright (E2E browser) |

### Component Hierarchy (Required — PR gate before first contact profile LiveView is merged)

| Level | Type | Responsibility |
|-------|------|---------------|
| 1 | LiveView modules | One per route. Owns socket state. No rendering logic in the module itself. |
| 2 | LiveComponents | Stateful sub-units with independent data loading. Own their events. Examples: NotesListComponent, ActivitiesListComponent, ImmichReviewComponent |
| 3 | Function components | Stateless pure render. No Phoenix module. Examples: `.contact_badge`, `.tag_badge`, `.form_field`, `.card`, `.reminder_row` |

### Alpine.js Scope Boundary

Alpine.js handles **UI chrome only**: dropdown menus, tooltips, clipboard, keyboard shortcuts, sidebar collapse, local toggle state. It does **not** read from or write to server state. No form submissions or contact field mutations through Alpine. All data changes go through LiveView forms or explicit API calls. This boundary is a written coding standard, not a suggestion.

### RTL & i18n Requirements

- All date, time, number, and currency rendering goes through `ex_cldr` from the first template (not `Calendar` or raw formatting).
- RTL languages: use Tailwind **logical properties** (`ms-`, `me-`, `ps-`, `pe-`) instead of directional utilities (`ml-`, `mr-`, `pl-`, `pr-`) in all templates from day one.
- `<html dir="<%= html_dir(@locale) %>" lang="<%= @locale %>">` in root layout, driven by user locale.
- RTL testing: as each major screen is built, it must be verified in at least one RTL locale using browser DevTools.

### Key Screens

1. **Dashboard** — recent contacts, upcoming reminders count, activity feed, Immich `needs_review` badge
2. **Contact List** — searchable/sortable/filterable; tag filters; archive toggle; debounced live search
3. **Contact Profile** — tabbed (Life Events / Notes / Photos), sidebar with metadata + Immich link, merge action
4. **Upcoming Reminders** — top-level nav; 30/60/90-day window; all reminder types; all roles can view
5. **Journal** — DEFERRED to v1.5
6. **Settings** — personalization, modules, security (2FA/WebAuthn), users/roles, export, Immich config (no DAV section in v1), audit logs
7. **Auth** — login, register, email verify, 2FA, WebAuthn, OAuth, recovery codes
8. **Immich Review** — disambiguation UI for contacts with multiple Immich person candidates; batch accept/reject
9. **Contact Merge** — dry-run confirmation screen showing relationships to be deduplicated; commit merge
10. **Trash** — 30-day soft-deleted contacts; admin restore; permanent deletion count-down

---

## 13. Tech Stack Summary

| Layer | Technology | Notes |
|-------|-----------|-------|
| Language | Elixir | Functional, concurrent, fault-tolerant |
| Framework | Phoenix 1.7+ | Web + LiveView + REST API |
| Database | PostgreSQL 15+ | Ecto ORM; Oban queue |
| ORM | Ecto | Schema, migrations, queryable |
| Auth | `phx_gen_auth` + `assent` | Base auth + social OAuth (PKCE) |
| 2FA / TOTP | `pot` | TOTP library |
| WebAuthn | `wax` | FIDO2/U2F |
| API | Phoenix REST controllers | JSON serializers; no GraphQL in v1 |
| Background Jobs | **Oban** | PostgreSQL-backed; no external broker |
| Email | **Swoosh** | Adapters: SMTP, Mailgun, SES, Postmark |
| File Storage | `ex_aws` + custom wrapper | Local disk or S3; no Waffle |
| HTTP Client | `req` | External API calls (Immich, LocationIQ) |
| Cache | ETS / Cachex | Redis optional via `redix` for multi-node |
| Rate Limiting | `hammer` | ETS (default); Redis backend for multi-node |
| Frontend | Phoenix LiveView | Server-rendered reactive UI |
| CSS | TailwindCSS | Logical properties for RTL |
| JS sprinkles | Alpine.js | UI chrome only |
| Rich text | Trix | Notes editor via LiveView hook |
| i18n | Gettext + **`ex_cldr`** | Strings + date/number/currency |
| Logging | `logger_json` | JSON-structured in prod; plain text in dev |
| Error tracking | `sentry-elixir` | Production only |
| Testing | ExUnit + Playwright | Unit + browser E2E |
| Deployment | Docker + Docker Compose | See Section 14 |

### Architecture Decision Records (ADRs — required before first commit)

1. **Elixir over Rails/Django:** Chosen for OTP fault isolation, Oban integration, LiveView, and long-term maintainability. Hiring-pool constraint is a known, accepted tradeoff.
2. **REST over GraphQL:** Simpler for well-defined resources; avoids N+1 at resolver boundaries; better HTTP caching; mobile-ready via `?include=` convention.
3. **PKCE OAuth library confirmation:** Library choice must confirm PKCE support before v1 ships.

---

## 14. Deployment & Infrastructure

### Docker-First

Kith is fully containerized. Docker Compose is the primary deployment target for both development and production.

### Production Services

```
services:
  migrate    # One-shot: runs mix ecto.migrate; restart: no; depends: postgres
  app        # Phoenix web (LiveView + REST API); depends: migrate
  worker     # Oban background jobs; same image as app, KITH_MODE=worker; depends: migrate
  postgres   # PostgreSQL 15+; persistent volume
  caddy      # Reverse proxy with automatic TLS; required service
```

**Note:** `redis` is an optional service (uncomment when scaling to multiple `app` replicas). `minio` is in `docker-compose.dev.yml` only — never in the production file.

### Worker Container

Same Docker image as `app`. Behavior controlled by `KITH_MODE` environment variable:
- `KITH_MODE=web` (default) — starts Phoenix endpoint
- `KITH_MODE=worker` — starts Oban workers only, no HTTP server

Built once, deployed as two separate containers.

### Migration Strategy

Dedicated `migrate` service with `restart: no`. Defined before `app` and `worker` with `depends_on: { postgres: { condition: service_healthy } }`. App and worker containers do not run migrations on startup. Implements `Kith.Release` module with `migrate/0`, `rollback/2`, and `start_worker/0` entry points.

### Dockerfile (Multi-stage)

- **Builder stage:** Elixir + Node.js (for esbuild/TailwindCSS); mix deps compile; `mix assets.deploy`; `mix phx.digest`; `mix release`
- **Runner stage:** Alpine Linux minimal; runtime libs only (`libssl3`, `libcrypto3`, `ncurses-libs`, `ca-certificates`); non-root user (UID 1000); no mix/hex

### Reverse Proxy (Caddy — Required)

Caddy is a required production service. Handles: automatic TLS, WebSocket passthrough for LiveView (must forward `X-Forwarded-For` and `X-Forwarded-Proto` — required for Phoenix `check_origin` validation), static asset caching, HSTS, and compression. Reference `Caddyfile` is committed to the repository.

### Health Check Endpoints

| Endpoint | Purpose | Checks |
|----------|---------|--------|
| `GET /health/live` | Docker `HEALTHCHECK`; process alive | Returns 200 always (unless crashed) |
| `GET /health/ready` | Caddy + orchestrators | DB connectivity + migration version |

### Observability

- **Structured logging:** `logger_json` in production. JSON logs with `request_id`, `user_id`, `account_id` metadata.
- **Metrics:** Phoenix Telemetry + `prometheus_ex` exporter at `/metrics` (admin-auth gated).
- **Error tracking:** Sentry (`sentry-elixir`); production only.
- **Oban Web:** Admin-auth gated dashboard (uses `Oban.Web.Resolver` with `can?/2` callback requiring admin session).

### Volume Management

| Volume | Service | Required |
|--------|---------|---------|
| `postgres_data` | postgres | Yes |
| `uploads` | app | Yes (if local disk storage) |
| `caddy_data` | caddy | Yes (TLS certs) |
| `caddy_config` | caddy | Yes |
| `redis_data` | redis (optional) | Only if Redis enabled |

### Resource Limits (Production Defaults)

```yaml
deploy:
  resources:
    limits:
      memory: 512M  # app and worker
      cpus: '1.0'
    reservations:
      memory: 256M
      cpus: '0.5'
```
PostgreSQL: 256MB limit. Configurable via environment variables.

### Restart Policies

All services: `restart: unless-stopped`.

### Secret Management

`.env` file with `chmod 600`. `runtime.exs` supports both env var and file-based secrets (for Docker Swarm). `.env.example` documents all required variables. `.env` in `.gitignore`. Required non-defaultable secrets: `SECRET_KEY_BASE`, `DATABASE_URL`, `AUTH_TOKEN_SALT`, `SMTP_PASSWORD` (or equivalent mailer secret).

### Scaling Notes

- Stateless app containers enable horizontal scaling behind a load balancer
- Phoenix supports multi-node via `libcluster` (defer to after v1 stability)
- Oban supports multi-node job processing natively via PostgreSQL LISTEN/NOTIFY
- If scaling to multiple `app` replicas: enable Redis for rate limiting (`RATE_LIMIT_BACKEND=redis`); configure sticky sessions at the load balancer for LiveView WebSocket connections

---

## 15. Compliance & Privacy

- No external tracking or analytics baked in
- Self-hostable (full data sovereignty)
- Audit log for all account actions (survived contact hard-deletion)
- Account deletion with full data wipe
- GDPR-friendly: no third-party data sharing, all data exportable (vCard, JSON)
- Terms of Service acceptance tracking per user (configurable)
- Immich integration is read-only: Kith never writes to Immich

---

## 16. Pre-Code Gate Conditions

The following must be completed **before the first migration file is written:**

1. **Entity Relationship Diagram (ERD)** committed to the repository — all v1 tables, FKs, nullable columns, and indexes. Reviewed by backend engineer and one other team member.

2. **Frontend conventions document** — component hierarchy (Level 1/2/3), Alpine.js scope boundary definition, RTL-safe Tailwind conventions, `Kith.Policy.can?/3` interface.

3. **Oban enqueue transactionality confirmed** — explicit implementation plan showing that `enqueued_oban_job_ids` updates and Oban job insertion happen inside the same `Ecto.Multi` transaction for all reminder operations.

---

## 17. Roadmap

### v1.5
Tasks, Journal, Pets, Gifts, Debt tracking, Weather at contact locations, CardDAV/CalDAV evaluation, Conversations & messages, Reminder snooze, Duplicate contact detection (automated), Customizable emotions/activity categories/life event types, `private` note enforcement (access control), Previous name/alias search.

### v2
Hosted/managed offering, mobile app (iOS/Android — REST API is ready from day one), advanced conversation integrations.
