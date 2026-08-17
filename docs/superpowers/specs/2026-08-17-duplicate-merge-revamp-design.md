# Duplicate Contact Merge Revamp — Design

**Date:** 2026-08-17
**Status:** Approved for planning
**Branch:** `worktree-merge-revamp`

## Problem

The duplicate merge tool has three defects that compound each other.

**Too many steps.** `ContactLive.Merge` is a three-step wizard: search for a
contact, choose field values, review a preview. When entered from the duplicates
page — the only path most users take — step 1 is already answered and is skipped,
but the stepper still reports "Step 2 of 3". Steps 2 and 3 show disjoint data, so
the user picks field values on one screen and sees unrelated counts on the next.

**Poor visibility.** The field picker exposes eight fields: `first_name`,
`last_name`, `nickname`, `birthdate`, `description`, `occupation`, `company`,
`avatar`. Roughly thirty other contact fields — `middle_name`, `aliases`,
`gender`, `currency`, `deceased`, `favorite`, `is_archived`, the `first_met_*`
group, the `immich_*` group — are never shown and silently keep the survivor's
values. The preview is a list of counts ("3 notes will be combined") with no
sample of the underlying records and no rendering of the resulting contact.

**Pairs, not clusters.** `duplicate_candidates` stores pairs
(`contact_id`, `duplicate_contact_id`, with a check constraint enforcing
`contact_id < duplicate_contact_id`) and `Contacts.merge_contacts/3` merges
exactly two contacts. Four duplicates of one person surface as up to six
unrelated rows that must be resolved one at a time.

## Goals

1. One screen, no wizard.
2. Every contact field visible, with miscellaneous and historical data
   summarised rather than expanded.
3. An N-contact cluster resolved in a single merge.
4. Fix the two data-loss bugs found during design (below).

## Non-goals

- Changing the detection algorithm, its signals, or its scoring.
- Adding a `duplicate_groups` table. Clusters are derived, not stored.
- Undo/restore for dismissed candidates.
- Automatic or bulk merging without review.

---

## 1. Cluster layer

### Derivation

`Kith.DuplicateDetection.list_clusters(account_id, opts)` loads pending
candidates for the account and computes connected components with union-find in
memory. Pending pairs are bounded — name matching already caps at 500 rows per
scan — so a recursive CTE is unnecessary.

Each cluster is a struct carrying:

- `key` — the lowest contact id in the cluster
- `contacts` — member contacts, preloaded for display
- `pairs` — the candidates that linked them, for per-member evidence
- `max_score` — highest pair score in the cluster
- `reasons` — union of pair reasons

Pagination moves from pairs to clusters, ordered by `max_score` descending.
`pending_count/1` continues to count pairs for the nav badge; a separate
`cluster_count/1` backs the page header.

### Cluster identity

Clusters have no database row, so the URL keys on the lowest member contact id:
`/contacts/duplicates/cluster/:id`. If cluster composition changed since the page
was loaded, the LiveView recomputes and renders the current cluster rather than
erroring.

### Membership is a selection

The cluster is fixed as detected. Every member carries a checkbox, checked by
default. Merge acts only on checked members. Unchecked members are left entirely
untouched: their candidate pairs stay `pending`, so the next detection run
reclusters whatever remains among them into its own group.

There is no per-member "not a duplicate" action and no cascade logic. A pair
between the survivor and an unchecked member stays `pending`, so that two-member
cluster reappears on the next visit — correct, because it genuinely is
unresolved. "Dismiss cluster" remains available to dismiss every pair in the
cluster at once.

### Primary selection

The default primary is the member with the most attached records, tie-broken by
earliest `inserted_at`. This moves the fewest rows and preserves the original
contact id, which matters because CardDAV clients hold URLs keyed on it. The user
can override by clicking a member chip.

---

## 2. Merge engine

`Kith.Contacts.merge_cluster(scope, survivor_id, loser_ids, resolution)` replaces
`merge_contacts/3`. One `Ecto.Multi`, one transaction.

### Resolution payload

The LiveView resolves values before submitting; the engine validates and applies
rather than re-deriving:

```elixir
%{
  fields: %{first_name: "Sarah", birthdate: ~D[1990-03-02], nickname: :clear},
  drop:   %{contact_fields: [88, 91], addresses: [], tags: [12]}
}
```

Every scalar value must match a value held by one of the selected members, or be
`:clear`. Every id in `drop` must belong to a selected member. Both are validated
server-side; a mismatch aborts the transaction.

### Steps

1. **Validate** — all contacts in `scope.account`, all active (`deleted_at` is
   nil), survivor not among losers, at least one loser, resolution well-formed.
2. **Apply scalars** to the survivor via changeset.
3. **Remap** every loser's owned records to the survivor.
4. **Deduplicate** the survivor's multi-valued records.
5. **Discard** records listed in `drop`.
6. **`last_talked_to`** — the maximum across all merged members.
7. **Cancel Oban jobs** for losers' reminders.
8. **Soft-delete** losers.
9. **Resolve candidate pairs** (below).
10. **Audit log** — one `:contact_merged` entry naming every loser and the full
    resolution.

### Entities remapped

Existing: notes, `activity_contacts`, calls, life events, documents, photos,
addresses, contact fields, `contact_tags`, reminders, relationships.

**Added, and currently missing — see Bug 1:** debts, gifts, pets, tasks,
conversations, `immich_candidates`, `reminder_instances`, and inbound
`first_met_through` references.

### Candidate pair resolution

- Pairs wholly inside the merged set → `merged`.
- Pairs touching a trashed loser → `merged`. Without this they would render
  clusters pointing at trashed contacts.
- Everything else → left `pending`, to recluster on the next run.

The blanket `dismiss_candidates_for_contact/2` call is removed — see Bug 2.

---

## 3. Auto-resolution rules

Computed across selected members only, and recomputed whenever the selection
changes.

### Scalar fields

| Distinct non-null values | Behaviour |
|---|---|
| 0 | Empty. No decision. |
| 1 | Auto-resolved. Attribution shown ("only S. Kim has this"). |
| 2+ | Conflict. Toggle, defaulting to the value held by the most members, tie-broken by most recently updated. |

Comparison trims whitespace. A resolved field remains user-changeable, including
an explicit "Leave empty".

### Multi-valued data

Unioned, then deduplicated on a per-type key:

| Type | Dedupe key |
|---|---|
| Contact fields | field type + normalized value |
| Addresses | `line1` + `postal_code`, case-insensitive, trimmed |
| Tags | `tag_id` |
| Aliases | the string |

Dropped duplicates are shown struck through with their source, not hidden.

### Boolean and flag fields

Policy is "the most engaged interpretation wins":

- `favorite` — true if any member is favorited.
- `deceased` — true if any member is marked deceased, taking the earliest
  `deceased_at`.
- `is_archived` — false if any member is active.

### History

Notes, activities, calls, life events, photos, documents, reminders, gifts,
debts, pets, tasks and relationships are never a decision. They always move to
the survivor and are reported as counts.

---

## 4. Screen

One screen at `/contacts/duplicates/cluster/:id`, replacing the wizard.

**Member strip** — a chip per member with a checkbox, avatar, display name, and
its best linking evidence ("86% · phone"). The primary chip is marked. Unchecking
dims the chip and recomputes every section below. An **Add contact** search sits
at the end of the strip for manually merging contacts detection did not link
(see §6).

**Three folded sections**, each an ordinary disclosure whose header states what it
holds, what the engine already did, and whether anything needs a decision:

1. **Identity** — every scalar contact field as a row. Resolved rows show the
   value plus attribution and are click-to-change, opening in place as a
   segmented control including "Leave empty". Conflicting rows are already
   segmented controls, tinted and dotted, sitting in their natural schema
   position rather than lifted to the top.
2. **Contact details** — emails, phones, addresses, tags and aliases as
   checklists of real values with source labels. Unchecking excludes a value from
   the merge.
3. **Carried over as-is** — history entity counts only.

**A section holding an unresolved conflict opens itself.** Sections with nothing
contested stay folded and say so. The page is therefore short when nothing needs
attention and unfolds exactly where the user is needed.

**Footer** — what will happen in plain language ("2 contacts move to trash and
stay recoverable for 30 days"), a "Dismiss cluster" secondary action, and the
primary "Merge N contacts".

The duplicates index at `/contacts/duplicates` lists clusters instead of pairs.
Each row shows member avatars, the top score, match reasons, and links to the
cluster screen.

### Design reference

Mockups of the four interaction models considered, and the approved design:
https://claude.ai/code/artifact/e9e42da5-121f-4e76-96c8-ce3427c88774

---

## 5. Bugs to fix

### Bug 1 — merging orphans six kinds of record

`Contacts.merge_contacts/3` (`lib/kith/contacts.ex:1699`) does not remap `debts`,
`gifts`, `pets`, `tasks`, `conversations`, `immich_candidates`, or inbound
`first_met_through` references. Those records stay attached to the soft-deleted
non-survivor and disappear from the UI. Fixed by the expanded remap list in §2.

### Bug 2 — unmerged members are dismissed instead of reclustered

After a merge, `dismiss_candidates_for_contact/2` runs for both contacts
(`lib/kith_web/live/contact_live/merge.ex:174`), dismissing every other pending
pair involving the survivor. `DuplicateDetectionWorker` then skips those pairs
permanently, because it excludes anything already recorded as `pending` **or**
`dismissed` (`lib/kith/workers/duplicate_detection_worker.ex:70`).

This directly breaks the cluster model: an unchecked member is supposed to keep
its pending pairs and return as its own cluster. Fixed by the targeted pair
resolution in §2.

---

## 6. Compatibility

**REST API.** `POST /api/contacts/merge` currently accepts `survivor_id` and
`non_survivor_id` and calls `merge_contacts/3` with no field choices. It keeps
working: the controller adapts the request to
`merge_cluster(scope, survivor_id, [non_survivor_id], %{fields: %{}, drop: %{}})`,
which applies the auto-resolution defaults. No new API surface in this change.

`GET /api/duplicates` continues to return pairs. Cluster listing is a LiveView
concern for now.

**Dead code.** `KithWeb.ContactLive.Duplicates` is unrouted and unreferenced —
the live page is `ContactLive.Index` with the `:duplicates` action. Delete it as
part of this work.

**Routes.** `/contacts/:id/merge` is removed along with `ContactLive.Merge`, and
replaced by `/contacts/duplicates/cluster/:id`.

**Manual merge is preserved.** Today the wizard's step 1 lets a user merge any
two contacts by search, independent of detection. That path must survive. The
cluster screen therefore accepts either a detected cluster key or a bare contact
id: when the id belongs to no pending cluster, the screen renders with that one
contact as its only member and an **Add contact** search — backed by the existing
`Contacts.search_contacts/2` — that appends members to the strip. Added members
behave exactly like detected ones: checked by default, contributing to conflict
computation, removable by unchecking. The "Merge" action on the contact show page
points here.

This also means the member strip has two sources — detection and manual addition
— and the merge itself does not distinguish them.

---

## 7. Testing

**Engine** (`test/kith/contacts_merge_test.exs`, extended):

- Three- and four-contact merges remap every entity type, including the six
  previously missed.
- Deduplication for each multi-valued type.
- `drop` excludes the listed records; invalid ids abort.
- Scalar values not held by any selected member abort.
- Boolean policy: `favorite`, `deceased` + earliest `deceased_at`, `is_archived`.
- `last_talked_to` takes the maximum across members.
- Cross-account members are rejected; trashed members are rejected.
- Inbound `first_met_through` references are repointed.

**Clusters** (`test/kith/duplicate_detection_test.exs`, extended):

- Transitive pairs form one cluster; disjoint pairs stay separate.
- Pair resolution after merge: inside-set → `merged`, loser-touching → `merged`,
  outside → `pending`.
- An unchecked member's pairs survive a merge and recluster on the next run —
  the regression test for Bug 2.

**LiveView** (`test/kith_web/live/contact_live/cluster_merge_test.exs`, new):

- Conflicts render as toggles; resolved fields render with attribution.
- A section with a conflict renders open; a fully resolved one renders folded.
- Unchecking a member recomputes conflicts and counts.
- Merge submits the resolved payload and redirects to the survivor.
- A bare contact id with no pending cluster renders a one-member screen, and
  adding a contact by search appends it to the strip.
