# Image-fallback browser checks (fake S3)

Drives `test/playwright/image-fallback.spec.ts` against a local fake S3.

1. Start the fake S3 (stdlib Python 3, port 9000, bucket `kith-review`):

   ```
   python3 test/playwright/fixtures/s3/fake_s3.py /tmp/s3.log /tmp/s3-data 9000
   ```

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

3. `REVIEW_S3=1 mix phx.server` (port 4000).
4. `REVIEW_S3=1 mix run test/playwright/fixtures/s3/seed.exs` prints JSON.
5. The tests mutate seeded photos, so re-run the seed before each run. They shell out to `mix run`, so export `DB_PORT` if needed.
6. `IMG_SEED_JSON='<json>' npx playwright test --project=e2e test/playwright/image-fallback.spec.ts`
   (headless; without `IMG_SEED_JSON` all tests skip). Remove the dev.exs block afterwards.
