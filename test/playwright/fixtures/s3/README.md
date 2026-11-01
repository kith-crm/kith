# Image-fallback browser checks (fake S3)

Drives `test/playwright/image-fallback.spec.ts` against a local fake S3.

1. Start the fake S3 (stdlib Python 3, port 9000, bucket `kith-review`):

   ```
   S3_DATA=$(mktemp -d /tmp/s3-data.XXXXXX)
   python3 test/playwright/fixtures/s3/fake_s3.py /tmp/s3.log "$S3_DATA" 9000
   ```

   The data directory must start empty, or objects from an earlier run leak into this one.
   `mktemp -d` gives a fresh empty directory each run, so nothing has to be deleted first.

   The seed script uploads the valid images (`ok-1.png`, `avatar-a.png`) itself; keys never
   uploaded return 404.

2. Add this block to `config/dev.exs`. It is **uncommitted**; never commit it:

   ```elixir
   if System.get_env("REVIEW_S3") == "1" do
     config :kith, Kith.Storage, backend: :s3, bucket: "kith-review"

     config :ex_aws,
       http_client: ExAws.Request.Req,
       access_key_id: "test",
       secret_access_key: "test",
       region: "us-east-1"

     config :ex_aws, :s3, scheme: "http://", host: "127.0.0.1", port: 9000
   end
   ```

3. `DB_PORT=<port> REVIEW_S3=1 mix phx.server` (port 4000). Omit `DB_PORT` for the default database;
   the server and the seed must use the same one (e.g. `DB_PORT=5444`).
4. `DB_PORT=<port> REVIEW_S3=1 mix run test/playwright/fixtures/s3/seed.exs` prints the JSON as its
   last line (the seed silences Ecto debug logging; Oban may still log one line first, so capture
   it with `| tail -1`).
5. The tests mutate seeded photos, so re-run the seed before each run. They shell out to `mix run`, so export the same `DB_PORT` (e.g. `5444`) there too.
6. `DB_PORT=<port> IMG_SEED_JSON='<json>' npx playwright test --project=e2e test/playwright/image-fallback.spec.ts`
   (headless, Chrome for Testing; without `IMG_SEED_JSON` all tests skip). Use the same `DB_PORT` as
   steps 3–4. Remove the dev.exs block afterwards.
