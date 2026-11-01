# Monica contact field recovery

The importer reads Monica's embedded `contactFields` list, with `content`,
`label`, and `contact_field_type.name` / `.protocol`. Canonical `tel`, `mailto`,
`https`, and `http` protocols accept seeded suffixes (`tel:`, `https://`, etc.).
Unknown metadata remains a generic field. Phone parsing retains malformed
nonblank text; bare local numbers need an explicitly selected country to become
international numbers.

Missing or null `contactFields` is different from an explicit empty list. The
former adds an import diagnostic; the latter means no embedded fields. A healthy
embedded response makes no per-contact field requests. No alternate envelope or
extra field-fetch endpoint is assumed. The real missing-phone response is still
needed before adding source-specific fallback behavior: supply a redacted
listing request (including query), the affected contact object, source type
metadata, and any demonstrated detail response. Preserve keys, nulls, protocol,
labels, pagination, and relationship IDs; replace personal values and secrets.
The deterministic test payloads demonstrate importer behavior, not the shape of
an unprovided production omission.

## Supported opt-in recovery

Ordinary imports continue to skip contacts imported by an earlier job. For an
explicit field recovery, use the existing Imports context and crawl worker with
`api_options["recover_contact_fields"] = true`. This option has no wizard toggle
and does not require changing import mappings. Obtain the intended account/user
and credentials through the normal authenticated operational path. First
rehearse with a backup or isolated local account and the deterministic fixtures.

For example, in an authenticated operational Elixir session, where `scope` is the
selected user's scope and `source_url` / `source_key` are securely supplied:

```elixir
{:ok, job} = Kith.Imports.create_import(scope.account.id, scope.user.id, %{
  source: "monica_api",
  api_url: source_url,
  api_key_encrypted: source_key,
  api_options: %{
    "recover_contact_fields" => true,
    "phone_default_region" => "US", # choose the actual source region, or nil
    "photos" => false,
    "documents" => false,
    "extra_notes" => false,
    "auto_merge_duplicates" => false
  }
})

{:ok, _oban_job} = %{import_id: job.id}
  |> Kith.Workers.MonicaApiCrawlWorker.new()
  |> Oban.insert()
```

Do not copy the example region without checking the source data. Wait for any
active import to finish before creating a recovery job. The worker forwards the
saved option to `MonicaApi.crawl/5`; direct local callers may pass the same option
as its fifth argument. Review the resulting summary's `error_count`, `errors`,
and `coverage_backfill`; completion alone does not prove every field arrived.
Verify stored values, contact details, and downloaded vCards before considering
recovery complete. Missing embedded payload diagnostics require source evidence,
not another blind rerun.

For already mapped live contacts, recovery adds missing fields only and preserves
unrelated local children, contact attributes, and the original contact mapping.
It follows merge-survivor mappings, skips soft-deleted contacts, and deduplicates
normalized values on repeated runs. It does not recreate soft-deleted contacts. The
usual crawler still imports previously unseen contacts and performs its normal
coverage scan; this is not a source-ID allowlist or an offline backfill tool.

A source protocol can repair a same-name account type only when every existing
field using it has Monica import provenance. Global seeds and types with local
or mixed provenance remain unchanged; a separate account type is created for a
conflicting protocol. Type repair enters the shared contact write coordinator.
An old generic field on an unrelated user type is preserved; this deliberately
conservative case can leave that field beside a recovered typed field.

No production import or recovery was run for this change.

## Local browser verification

The maintained local scenario in `test/playwright/monica-import.spec.ts` imports
`Fixture custom mobile` with `tel:` and `Work`, verifies a `tel:+12025550100`
contact-details link, and downloads a vCard containing
`TEL;TYPE=WORK:+12025550100`. Use the local harness documented in
`test/playwright/fixtures/regressions/README.md`. The legacy live-host scenarios
in that spec require the separate explicit `KITH_LIVE_MONICA_TESTS=1` gate; the
local scenario never reads their private key or export.
