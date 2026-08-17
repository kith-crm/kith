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
- Undo/restore for dismissed candidates. Noted as a risk: §2 makes dismissal
  load-bearing and permanent, and there is no UI listing dismissed pairs, so a
  mistaken uncheck is unrecoverable without direct database access. A "Dismissed"
  view with restore is the natural follow-up.
- Automatic or bulk merging without review.

---

## 1. Cluster layer

### Derivation

`Kith.DuplicateDetection.list_clusters(account_id, opts)` loads all `pending` and
`dismissed` candidates for the account and computes components with union-find in
memory. Pending pairs are bounded — name matching already caps at 500 rows per
scan — so a recursive CTE is unnecessary.

Pending pairs are positive edges; dismissed pairs are **negative edges** — a
record that the user already reviewed those two contacts and rejected the match.
Clustering must never place a negative edge inside a component, or a rejected
match would silently reappear by transitivity through some third contact.

The build is therefore greedy rather than a plain union of all edges:

1. Sort pending pairs by score, descending.
2. For each pair, union its endpoints **only if** the resulting component would
   contain no dismissed pair.
3. Skipped pairs stay `pending` and are reconsidered on the next run.

This yields "closest match wins". Given a dismissed A–D and a new contact E
matching A at 0.90 and D at 0.60, A–E unions first; D–E is then skipped because
it would put A and D in one component. The result is `{A, E}`, with D left
alone — not `{A, D, E}`.

A skipped edge is invisible to the user until it resolves itself: once `{A, E}`
merges, the D–E pair is repointed onto the already-dismissed A–D (§2). This is
accepted, not fixed.

### Trashed members

A pending pair survives its contact being trashed by ordinary deletion. Cluster
members are therefore filtered to active contacts (`deleted_at IS NULL`), and any
cluster left with fewer than two members is dropped from the listing.

### Membership is a selection

The cluster is fixed as detected. Every member carries a checkbox, checked by
default. **Both** the merge and the "Not duplicates" action operate on the
checked set only.

**Merging commits a review of the checked members.** Unchecking a member and
merging the rest is a statement that the unchecked member is not one of them, so
its pairs to the merged members become `dismissed` (§2). The worker already skips
any pair recorded as `pending` or `dismissed`, so the rejected match is never
regenerated, and the negative-edge rule above stops it reappearing by
transitivity. The cluster does not come back.

**Pairs between two unchecked members are never touched by either action.** This
is what lets a five-member cluster holding two distinct people be resolved in two
passes: merge person A's three records with person B's two unchecked, and B's
internal pair survives to recluster on the next run.

Leaving the page without acting commits nothing — the cluster returns unchanged.
There is no per-member "not a duplicate" action; unchecking plus acting is that
action.

### Primary selection

The default primary is the member with the most attached records — the sum of its
notes, activities, calls, life events, photos, documents, addresses and contact
fields — tie-broken by earliest `inserted_at`. This moves the fewest rows and
preserves the contact id holding the most history, which matters because CardDAV
clients hold URLs keyed on it. The user can override by clicking a member chip.

---

## 2. Merge engine

`Kith.Contacts.merge_cluster(scope, survivor_id, loser_ids, resolution)` replaces
`merge_contacts/3`. One `Ecto.Multi`, one transaction.

The engine does **not** derive anything. It validates the resolution it is handed
and applies it. Resolution is computed by a shared module (§3) called by every
caller, so what the user approved is exactly what is written, and a concurrent
edit between render and submit fails loudly instead of silently changing the
outcome.

### Resolution payload

```elixir
%{
  fields: %{first_name: "Sarah", birthdate: ~D[1990-03-02], nickname: :clear, ...},
  drop:   %{contact_fields: [88, 91], addresses: [], tags: [12]}
}
```

`fields` is complete — every mergeable field, with a concrete value or `:clear`.
Every value must be held by one of the selected members, or be `:clear`. Every id
in `drop` must belong to a selected member. Both are validated server-side; a
mismatch aborts the transaction.

`drop` is destructive by design (§4): a dropped record belonging to a loser is
simply not remapped and rides to trash with its owner, but a dropped record
belonging to the survivor is deleted outright, with no trash behind it. The audit
entry therefore records every dropped record with its type, value and original
owner, so the deletion leaves a trail.

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
10. **Enqueue** a `DisplayNameRecomputeWorker` job for the survivor, since
    `display_name` is computed and never merged directly (§3).
11. **Audit log** — one `:contact_merged` entry naming every loser, the full
    resolution, and every dropped record.

### Entities remapped

Existing: notes, `activity_contacts`, calls, life events, documents, photos,
addresses, contact fields, `contact_tags`, reminders, relationships.

**Added, and currently missing — see Bug 1:** debts, gifts, pets, tasks,
conversations, `immich_candidates`, `reminder_instances`, and inbound
`first_met_through` references.

### Candidate pair resolution

Both actions are scoped to the checked members. Let *S* be the checked set and
*U* the unchecked members of the cluster.

| Pair | Merge | Not duplicates |
|---|---|---|
| Both endpoints in *S* | `merged` | `dismissed` — written as the full clique over *S* |
| One in *S*, one in *U* | `dismissed` | `dismissed` |
| Both endpoints in *U* | untouched | untouched |

The clique matters because detection often links a cluster as a chain: A–B, B–C,
C–D is three pairs, not six. Dismissing only the detected pairs would leave no
negative edge between A and C, so a later contact matching both would reunite
them by transitivity. Writing the clique over *S* closes that hole. It is written
only over *S*, never over *U*, so it can never assert something about a pair the
user excluded.

**Repointing.** Every remaining pair referencing a loser is rewritten to
reference the survivor, since the survivor now *is* that contact. Without this, a
dismissal recorded against a loser evaporates when the loser is trashed and the
rejected match returns on the next scan.

Repointing must respect the table's constraints: normalize so
`contact_id < duplicate_contact_id`, drop self-pairs, and on collision with an
existing row keep the strongest status — `merged` over `dismissed` over
`pending`. Implemented as delete-then-insert rather than a bare `update_all`,
because the unique index on `(account_id, contact_id, duplicate_contact_id)` will
otherwise reject the rewrite.

The blanket `dismiss_candidates_for_contact/2` call is removed — see Bug 2. Note
the distinction: that call dismisses pairs the user never looked at, which is the
bug. These rules dismiss only pairs the user reviewed by unchecking.

---

## 3. Auto-resolution rules

`Kith.Contacts.MergeResolution.resolve(members)` returns the complete field map
for a set of members. It is the single implementation: the LiveView calls it to
render and re-calls it on every selection change; the API adapter calls it to
build its payload. The engine never calls it.

Resolution is recomputed from scratch whenever the member selection changes.
Explicit user choices made before a selection change are **not** retained.

### Scalar fields

| Distinct non-null values | Behaviour |
|---|---|
| 0 | Empty. No decision. |
| 1 | Auto-resolved. Attribution shown ("only S. Kim has this"). |
| 2+ | Conflict. Toggle, defaulting to the value held by the most members, tie-broken by most recently updated. |

Comparison trims whitespace. A resolved field remains user-changeable, including
an explicit "Leave empty".

**Excluded from the registry.** `display_name` is computed from the name fields
and recomputed asynchronously by `DisplayNameRecomputeWorker`; it is never a
mergeable field, and the merge enqueues a recompute instead (§2). Also excluded:
`account_id`, `deleted_at`, and the timestamps.

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

### Immich fields

`immich_person_id`, `immich_person_url`, `immich_status` and
`immich_last_synced_at` move **as one unit** — they are meaningless apart, and a
survivor marked `linked` while carrying another record's sync timestamp is
corrupt state.

They render as a **single editable row** listing each linked member by display
name and last sync date, rather than four rows of opaque ids. The default is:
the survivor's link if it has one; otherwise the only linked member's; otherwise
the most recently synced. The user can pick another linked member or unlink.

Per ADR-007 the integration is read-only, so nothing is written back to Immich
and a wrong choice is repairable by re-linking from the contact page.

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

1. **Identity** — every mergeable scalar field as a row, plus the single grouped
   Immich row. Resolved rows show the value plus attribution and are
   click-to-change, opening in place as a segmented control including "Leave
   empty". Conflicting rows are already segmented controls, tinted and dotted,
   sitting in their natural schema position rather than lifted to the top.
2. **Contact details** — emails, phones, addresses, tags and aliases as
   checklists of real values with source labels. The list is the flat union;
   unchecking any value excludes it from the merge, including values the survivor
   already owns, which are deleted (§2).
3. **Carried over as-is** — history entity counts only.

**A section holding an unresolved conflict opens itself.** Sections with nothing
contested stay folded and say so. The page is therefore short when nothing needs
attention and unfolds exactly where the user is needed.

**Footer** — what will happen in plain language, a secondary **"Not duplicates"**
action, and the primary "Merge N contacts". Both act on the checked members only.

The footer must state both halves of the outcome, because unchecking is a
permanent review (§1): what happens to the merged contacts ("2 contacts move to
trash and stay recoverable for 30 days") **and** what happens to the unchecked
ones ("Sarah J. Kim will be marked as not a duplicate and won't be suggested
again"). The second half is the consequence a user is most likely to trigger
without realising.

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

### Bug 2 — pairs the user never saw are dismissed

After a merge, `dismiss_candidates_for_contact/2` runs for both contacts
(`lib/kith_web/live/contact_live/merge.ex:174`), dismissing every other pending
pair involving the survivor. `DuplicateDetectionWorker` then skips those pairs
permanently, because it excludes anything already recorded as `pending` **or**
`dismissed` (`lib/kith/workers/duplicate_detection_worker.ex:70`).

This destroys pairs the user never looked at. Merging A and B wipes the pending
A–C and A–D pairs even though the user was never shown them, and no rescan brings
them back. Fixed by the targeted pair resolution in §2, which only dismisses
pairs the user reviewed by unchecking.

---

## 6. Compatibility

**REST API.** `POST /api/contacts/merge` currently accepts `survivor_id` and
`non_survivor_id` and calls `merge_contacts/3` with no field choices. It keeps
its request shape: the controller calls `MergeResolution.resolve/1` on the two
contacts and passes the resulting complete map to
`merge_cluster(scope, survivor_id, [non_survivor_id], resolution)`.

This is a deliberate behaviour improvement for API clients. Today a loser's
`middle_name` is discarded even when the survivor has none; under the shared
resolver that gap is filled. A survivor's existing value is never overridden, so
no client loses data it previously kept.

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

**Resolution** (`test/kith/contacts/merge_resolution_test.exs`, new):

- 0 / 1 / 2+ distinct values produce empty, resolved and conflict states.
- Conflict default is the most-held value; ties break by most recently updated.
- Boolean policy: `favorite`, `deceased` + earliest `deceased_at`, `is_archived`.
- Immich fields resolve as a unit under each branch of the default rule.
- `display_name` never appears in the resolved map.

**Engine** (`test/kith/contacts_merge_test.exs`, extended):

- Three- and four-contact merges remap every entity type, including the six
  previously missed.
- Deduplication for each multi-valued type.
- `drop` excludes loser-owned records and deletes survivor-owned ones; both are
  recorded in the audit entry.
- Invalid `drop` ids, and scalar values held by no selected member, abort.
- `last_talked_to` takes the maximum across members.
- A `DisplayNameRecomputeWorker` job is enqueued for the survivor.
- Cross-account members are rejected; trashed members are rejected.
- Inbound `first_met_through` references are repointed.

**Clusters** (`test/kith/duplicate_detection_test.exs`, extended):

- Transitive pairs form one cluster; disjoint pairs stay separate.
- Members trashed outside the merge flow are excluded, and clusters left with
  fewer than two members are dropped.
- Pair resolution after merge and after "Not duplicates", for all three rows of
  the §2 table.
- The clique is written over the checked set only, never over unchecked members.
- Repointing respects the ordering check constraint and the unique index, and
  keeps the strongest status on collision.
- Pairs in other clusters are untouched by a merge — the regression test for
  Bug 2.

**The handled-cluster scenario**, end to end, as its own test:

- Given a cluster `{A, B, C, D}`, merging `A + B + C` with D unchecked leaves
  A–D `dismissed` and repoints B–D and C–D onto A.
- Re-running `DuplicateDetectionWorker` does not recreate A–D and does not
  produce a cluster containing both A and D.
- A new contact E matching A at 0.90 and D at 0.60 clusters as `{A, E}`. D is
  excluded, and the D–E pair remains `pending`.
- Reversing the scores puts E with D instead, and A is excluded.

**The two-people scenario**, end to end, as its own test:

- Given a cluster `{A, B, C, D, E}` where D–E are duplicates of each other,
  merging `A + B + C` leaves D–E `pending`.
- The next detection run produces a `{D, E}` cluster, which merges independently.
- Neither resulting contact ever reclusters with the other.

**LiveView** (`test/kith_web/live/contact_live/cluster_merge_test.exs`, new):

- Conflicts render as toggles; resolved fields render with attribution.
- A section with a conflict renders open; a fully resolved one renders folded.
- Unchecking a member recomputes conflicts and counts, and discards any explicit
  field choices.
- Merge submits the resolved payload and redirects to the survivor.
- "Not duplicates" dismisses the clique over the checked members and leaves
  unchecked-to-unchecked pairs pending.
- A bare contact id with no pending cluster renders a one-member screen, and
  adding a contact by search appends it to the strip.

---

## 8. User scenarios

Written as the acceptance criteria for the implementation plan. Each maps to the
section that defines its behaviour.

### A. Finding duplicates

**A1 — Four duplicates appear as one entry.** *(§1)*
Given four contacts detected as duplicates of one person, when I open the
duplicates page, then I see one cluster entry showing all four members, not six
pair rows.

**A2 — Unrelated duplicates stay separate.** *(§1)*
Given two contacts duplicated with each other and two unrelated contacts
duplicated with each other, when I open the duplicates page, then I see two
cluster entries, each with two members.

**A3 — The queue is ordered by confidence.** *(§1)*
Given several clusters, when I open the duplicates page, then they are ordered by
their highest internal match score, and each shows member avatars, that score,
and the reasons for the match.

**A4 — Trashed contacts do not appear.** *(§1)*
Given a member of a pending cluster is trashed from the contacts page, when I
open the duplicates page, then that member is not shown, and if the cluster is
left with one member it is not listed at all.

### B. Reviewing the merge

**B1 — Every field is visible.** *(§4)*
Given a cluster, when I open it, then every mergeable scalar field is present —
including `middle_name`, `aliases`, `gender`, the `first_met_*` group and the
flags — not the eight the old wizard exposed.

**B2 — Agreement resolves itself.** *(§3)*
Given three members that all have the first name "Sarah", when I open the
cluster, then the First name row shows "Sarah" with the attribution "all 3
agree" and asks me nothing.

**B3 — A value only one member has is kept.** *(§3)*
Given only one member has a middle name, when I open the cluster, then the row
shows that value attributed to its source, and I am not asked to choose.

**B4 — Disagreement becomes a choice in place.** *(§3, §4)*
Given two members hold different birthdates, when I open the cluster, then the
Birthdate row is a toggle in its normal position in the Identity section, marked
as needing a decision, defaulted to the value held by the most members.

**B5 — A section with a conflict opens itself.** *(§4)*
Given a cluster whose only conflicts are identity fields, when I open it, then
the Identity section is expanded with a "2 need a decision" chip and the Contact
details section is folded and marked as having nothing to decide.

**B6 — A resolved field can still be changed.** *(§3, §4)*
Given a field the engine resolved on its own, when I click its value, then it
opens in place as a choice between the candidate values and "Leave empty".

**B7 — Multi-valued data is combined and prunable.** *(§3)*
Given members holding four distinct emails and one repeated email, when I expand
Contact details, then I see the four with their sources, the repeat struck
through as a dropped duplicate, and a checkbox on each so I can exclude one —
including values the survivor already owns.

**B8 — History is summarised, not detailed.** *(§3, §4)*
Given members with notes, activities, calls and gifts, when I open the cluster,
then the Carried over section reports counts per type and asks me nothing.

**B9 — Immich links are one choice, not four fields.** *(§3)*
Given two members linked to different Immich people, when I open the cluster,
then I see one row listing each linked member by name and last sync date, not
four rows of opaque identifiers.

### C. Membership and review

**C1 — Excluding a member changes the result.** *(§1, §3)*
Given a four-member cluster, when I uncheck one member, then conflicts, counts
and attributions recompute against the remaining three, and the merge button
reads "Merge 3 contacts".

**C2 — The consequence of excluding is stated.** *(§4)*
Given I have unchecked a member, when I read the footer, then it tells me both
that the merged contacts move to trash recoverably and that the unchecked member
will be marked as not a duplicate and not suggested again.

**C3 — Choosing the primary.** *(§1)*
Given a cluster, when I open it, then the member with the most attached records
is the primary by default, tie-broken by earliest creation, and I can make
another member primary by clicking its chip.

**C4 — Leaving without acting changes nothing.** *(§1)*
Given I uncheck a member and navigate away without merging, when the duplicates
page reloads, then the cluster is unchanged with all members checked.

**C5 — Changing the selection resets field choices.** *(§3)*
Given I have overridden a conflicting field, when I then uncheck a member, then
the resolution recomputes from defaults and my override is not retained.

### D. Merging

**D1 — An N-way merge is one action.** *(§2)*
Given a four-member cluster, when I merge, then one transaction produces one
surviving contact, three trashed contacts, and one audit entry naming all three.

**D2 — Nothing is orphaned.** *(§2, Bug 1)*
Given losers holding debts, gifts, pets, tasks, conversations, Immich candidates
and reminder instances, when I merge, then all of them appear on the survivor.
*Regression test for Bug 1.*

**D3 — Inbound references follow.** *(§2)*
Given another contact whose `first_met_through` points at a loser, when I merge,
then that reference points at the survivor.

**D4 — Duplicated sub-records collapse.** *(§2, §3)*
Given two members share an email address and a tag, when I merge, then the
survivor has one of each.

**D5 — Excluded values are not carried.** *(§2)*
Given I unchecked an address in Contact details, when I merge, then that address
is not on the survivor, and the audit entry records what was dropped and who
owned it.

**D6 — The merge is atomic.** *(§2)*
Given any step fails, when I merge, then nothing is changed and I am told the
merge failed.

**D7 — Tampering is rejected.** *(§2)*
Given a submitted scalar value that no selected member holds, or a dropped record
id belonging to no selected member, when the merge is submitted, then it is
rejected server-side.

**D8 — The display name is recomputed.** *(§2, §3)*
Given a merge that changes the survivor's name fields, when it completes, then a
`DisplayNameRecomputeWorker` job is enqueued for the survivor.

### E. Manual merge

**E1 — Merging two contacts detection never linked.** *(§6)*
Given a contact with no pending cluster, when I choose Merge from its page, then
the cluster screen opens with that contact as its only member and an Add contact
search.

**E2 — A manually added member behaves like a detected one.** *(§6)*
Given I add a contact by search, when it joins the strip, then it is checked,
contributes to conflicts and counts, and can be unchecked.

### F. After the merge

**F1 — A handled cluster does not return.** *(§1, §2)*
Given cluster `{A, B, C, D}` where I merged A, B and C with D unchecked, when the
detection worker runs again, then A–D is not recreated and no cluster contains
both A and D.

**F2 — A new match joins the closest contact only.** *(§1)*
Given A–D was dismissed by F1 and a new contact E matches A at 0.90 and D at
0.60, when the worker runs, then the cluster is `{A, E}` — D is excluded, and A
and D are not reunited by transitivity through E.

**F3 — The reverse holds.** *(§1)*
Given the same setup with E matching D more strongly than A, when the worker
runs, then the cluster is `{D, E}` and A is excluded.

**F4 — Other clusters are untouched.** *(§2, Bug 2)*
Given a merge in one cluster, when it completes, then pending pairs belonging to
unrelated clusters are still pending and still cluster.
*Regression test for Bug 2.*

**F5 — Two people in one cluster resolve in two passes.** *(§1, §2)*
Given a cluster `{A, B, C, D, E}` where D and E are duplicates of each other but
not of A, when I merge A, B and C with D and E unchecked, then the D–E pair is
untouched and the next detection run offers `{D, E}` as its own cluster.

**F6 — Marking the checked members as not duplicates.** *(§1, §2)*
Given the checked members do not belong together, when I choose Not duplicates,
then every pair among them is dismissed, pairs to unchecked members are
dismissed, pairs between two unchecked members are left alone, and the group does
not return.

### G. Compatibility

**G1 — The existing API keeps working, and improves.** *(§6)*
Given a client posting `survivor_id` and `non_survivor_id` to
`/api/contacts/merge`, when it is called, then the merge succeeds, the survivor
gains any field it had no value for, no existing survivor value is overridden,
and the survivor is returned.

**G2 — Permissions are enforced.** *(§2)*
Given a user without contact update permission, when they attempt to open or
submit a cluster merge, then it is refused.

**G3 — Account isolation holds.** *(§2)*
Given contact ids from another account, when a merge is submitted, then it is
rejected.

### Suggested slicing

Four vertical slices, each independently shippable and testable:

1. **Resolution and engine** — `MergeResolution`, `merge_cluster/4`, the expanded
   remap list, pair resolution and repointing. Covers D1–D8, F4, G1–G3, Bug 1,
   Bug 2. No UI change; the existing wizard and API adapt to the new functions.
2. **Clusters** — `list_clusters/2`, negative-edge building, trashed-member
   filtering, cluster listing on the duplicates page. Covers A1–A4, F1–F3,
   F5–F6.
3. **Screen** — the cluster merge LiveView, conflict rendering, sections, Immich
   row. Covers B1–B9, C1–C5.
4. **Manual merge and cleanup** — Add contact search, route changes, deleting
   `ContactLive.Merge` and the dead `ContactLive.Duplicates`. Covers E1–E2.
