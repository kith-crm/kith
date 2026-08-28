# Duplicate Merge Revamp — Design Review

**Date:** 2026-08-17
**Reviews:** `2026-08-17-duplicate-merge-revamp-design.md`
**Status:** Open — items below are unresolved unless marked otherwise
**Verified against:** worktree `merge-revamp`, branch `worktree-merge-revamp`

Short version: a strong design. The best parts are genuinely good. It has one
under-specified core (cluster identity / route), a handful of concrete gaps that
will bite during implementation, and a slicing plan that does not hold up.

---

## What checks out

All three code citations in the design are exact:

| Design claim | Verified |
|---|---|
| `Contacts.merge_contacts/3` at `lib/kith/contacts.ex:1699` | ✅ exact line |
| `dismiss_candidates_for_contact/2` at `lib/kith_web/live/contact_live/merge.ex:174` | ✅ exact line |
| Worker skips `pending` **or** `dismissed` at `lib/kith/workers/duplicate_detection_worker.ex:70` | ✅ `where: d.status in ["pending", "dismissed"]` |

**Bug 1 is real.** The remap chain in `merge_contacts/3` covers notes,
`activity_contacts`, calls, life events, documents, photos, addresses, contact
fields, `contact_tags`, reminders and relationships. It omits `debts`, `gifts`,
`pets`, `tasks`, `conversations`, `immich_candidates`, `reminder_instances` and
`first_met_through` — all of which exist as associations on `Kith.Contacts.Contact`.

**Bug 2 is real and nasty.** Worker line 70 means a dismissal is permanent, and
the blanket post-merge dismissal wipes pairs the user never saw, with no rescan
to recover them.

**The negative-edge clustering rule is the strongest idea in the document.**
Plain union-find over pending edges would resurrect dismissed matches by
transitivity. §1 catches that, works the example, and accepts the residual cost
explicitly ("A skipped edge is invisible to the user until it resolves itself").

**The clique-over-*S* argument in §2 is likewise subtle and correct.** Detection
produces chains (A–B, B–C), so dismissing only the detected pairs leaves no
negative edge between A and C.

**The design undersells one win.** The current API merge path
(`lib/kith_web/controllers/api/contact_controller.ex:218`) writes **no** audit
entry at all — only the LiveView does. Moving audit into the engine fixes that
silently. Worth stating in §6 as a behaviour improvement.

---

## Blocking gaps

### 1. Cluster identity is never defined — and it is the route

§4 routes to `/contacts/duplicates/cluster/:id` while §1 insists clusters are
derived, not stored. §6 says the screen "accepts either a detected cluster key or
a bare contact id", disambiguating by whether the id belongs to a pending
cluster. So `:id` is presumably the minimum member contact id — never stated, and
load-bearing:

- Does the URL change when a new member joins and the min id shifts?
- Is the URL bookmarkable across detection runs?
- What happens when two tabs hold different derivations of the same cluster?

**Action:** define the cluster key explicitly in §1, and state its stability
guarantees.

### 2. `first_name` is `validate_required` — "Leave empty" cannot apply to every field

§3 says a resolved field "remains user-changeable, including an explicit 'Leave
empty'", and the resolution payload allows `:clear` for any field.
`Contact.update_changeset` requires `first_name`. Clearing it fails at step 2
with a changeset error the UI never predicted.

**Action:** add a non-clearable field set to the registry in §3, and have §4's
segmented control omit "Leave empty" for those rows.

### 3. `aliases` cannot be expressed in the `drop` payload

§4 puts aliases in the Contact details checklist alongside emails, phones,
addresses and tags; §3 gives them a dedupe key. But `aliases` is
`{:array, :string}` on `contacts` — elements have no ids — while `drop` is an id
map: `%{contact_fields: [88], addresses: [], tags: [12]}`.

**Action:** either move aliases to the scalar registry as a merged array value,
or give `drop` a non-id shape for them.

Related, smaller: `tags: [12]` is ambiguous. `contact_tags` is a bare join table
with no Ecto schema, so is `12` a `tag_id` or a join row id? Say which.

### 4. Outbound `first_met_through` self-reference

Bug 1 and D3 cover *inbound* references being repointed. Nothing covers:

- the survivor's own `first_met_through_id` pointing at a loser, or
- a loser's `first_met_through_id` pointing at the survivor.

After remap, that is a contact met through itself.

`first_met_through_id` is also not discussed as a mergeable scalar at all — nor
are `gender_id` / `currency_id` explicitly, though §1 name-drops `gender` and
`currency` as unexposed fields.

**Action:** give `belongs_to` ids their own rule in §3, including the self-
reference clear.

### 5. Score ties make greedy clustering nondeterministic

§1's worked example assumes distinct scores (0.90 vs 0.60). In practice
`compute_merged_score/1` emits a small fixed set of values:

| Signal | Base |
|---|---|
| email | 0.85 |
| phone | 0.75 |
| address | 0.60 |
| name | `similarity(display_name)` |

plus `0.05 × (signal_count - 1)`, rounded to 2 decimals. Ties are common, and
"sort pending pairs by score, descending" leaves the winner to arbitrary row
order — so which component an edge lands in can change between runs on identical
data.

**Action:** add a deterministic tiebreak (score, then `contact_id`, then
`duplicate_contact_id`) and state it. Otherwise the F2/F3 tests are flaky by
construction.

### 6. `merged`-status rows are invisible to both layers

§2's collision precedence keeps `merged` over `dismissed`. But §1 clusters over
`pending` + `dismissed` only, and the worker's dedupe check (line 70) also looks
only at `pending`/`dismissed`, with the unique index plus `on_conflict: :nothing`
behind it. Any `merged` row between two *active* contacts is therefore a
permanent silent block: never clustered, never re-detected, never surfaced.

No case was found where such a row survives — the loser is trashed, then
FK-cascaded on purge (`on_delete: :delete_all` on both contact FKs in
`20260321173108_create_duplicate_candidates.exs`).

**Action:** state the invariant ("a `merged` row always has at least one trashed
endpoint") rather than leaving it to be rediscovered.

### 7. No locking; the concurrency story is thinner than claimed

§2 says a concurrent edit "fails loudly instead of silently changing the
outcome" — true, since the submitted value would no longer be held by any member.
But:

- No recovery path is described. The user sees an abort and must redo every choice.
- Nothing prevents two users merging overlapping clusters simultaneously. Step 1's
  "all active" check is not a lock.

**Action:** `SELECT ... FOR UPDATE` on the member rows in step 1, and a sentence
in §4 on what the user sees when validation aborts.

### 8. G2 is an acceptance criterion for a feature that does not exist

"Given a user without contact update permission…" — roles exist
(`admin` / `editor` / `viewer` on `Kith.Accounts.User`, `@valid_roles` at
`user.ex:52`), but `viewer` appears in the web layer **only** in
`kith_ui.ex` as a badge colour. There is no authorization enforcement anywhere.

G2 therefore either quietly expands this work to include building an authz layer,
or it gets dropped during implementation.

**Action:** decide which, now. If out of scope, delete G2.

---

## Smaller notes

- **§1 field count.** "Roughly thirty other contact fields" overstates it — the
  castable field set is ~28 total, so about 20 are unexposed. The point stands;
  the number does not.
- **§2 audit PII.** "every dropped record with its type, **value** and original
  owner" writes emails, phone numbers and addresses into `audit_logs` metadata,
  unbounded in size, outside the contact soft-delete/purge lifecycle. Probably
  fine — deserves an acknowledging sentence rather than being a side effect of
  "leave a trail".
- **§3 `deceased`.** "true if any member is marked deceased, taking the earliest
  `deceased_at`" is undefined when the deceased member has a nil `deceased_at`
  and another has a date.
- **§3 `is_archived`.** "false if any member is active" means a merge almost
  always un-archives, since the column defaults to false. Presumably intended;
  worth one line.
- **§1 the 500 cap.** "name matching already caps at 500 rows per scan" is true
  (`LIMIT 500` on the name query, `duplicate_detection_worker.ex:107`), but the
  email, phone and address queries are uncapped — total pending pairs are *not*
  bounded by 500. In-memory union-find is still the right call; the justification
  is wrong.
- **§1 greedy union cost.** The "would the component contain a dismissed pair"
  check is O(|C₁|×|C₂|) per edge. Fine at this scale; worth stating.

---

## The slicing does not work

§8's suggested slicing claims four "independently shippable" slices. Two are not.

**Slice 1** says "the existing wizard and API adapt to the new functions". The
wizard passes `%{"first_name" => "non_survivor"}` — a per-field *chooser* keyed to
exactly two contacts. The new engine demands a complete resolution map with
concrete values. Adapting the three-step wizard to that is real work that slice 3
then deletes.

**Slice 2** ships a cluster *list* whose rows link to a cluster screen that does
not exist until slice 3.

**Proposed restructure:**

1. **Engine + resolver + bug fixes.** `MergeResolution`, `merge_cluster/4`,
   expanded remap list, pair resolution, repointing. API adapted. The wizard left
   calling a thin `merge_contacts/3` shim over the new engine — no wizard rework.
   Covers D1–D8, F4, G1, G3, Bug 1, Bug 2.
2. **Clusters + screen, together.** `list_clusters/2`, negative-edge building,
   trashed-member filtering, the index flip and the cluster LiveView in one
   deploy. Covers A1–A4, B1–B9, C1–C5, F1–F3, F5–F6.
3. **Manual merge and cleanup.** Add-contact search, route changes, deleting
   `ContactLive.Merge` and the dead `ContactLive.Duplicates`. Covers E1–E2.

---

## The one thing worth arguing with

**The non-goal on dismissal undo should be pulled into scope.**

§1 makes unchecking a checkbox a permanent, irreversible statement. §2 amplifies
it into a full clique of negative edges. §4's footer text is the only thing
standing between a user and silently destroying a correct future match — with no
dismissed-pairs view and no recovery short of `psql`.

The design names this risk honestly, which is to its credit. But the risk is
*created by this design*: today's dismissals are per-pair and far less
consequential. A read-only "Dismissed" list with a restore button is small next
to the rest of this work.

**Recommendation:** add it as a fourth slice rather than leaving it as "the
natural follow-up".

---

## Open questions for the next session

1. What is the cluster key, concretely, and how stable is it?
2. Non-clearable fields: just `first_name`, or is there a broader rule?
3. Aliases — scalar array merge, or extend `drop`?
4. Is G2 (permissions) in scope, or deleted?
5. Is the dismissal-undo slice in or out?
