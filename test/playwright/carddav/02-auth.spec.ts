import { test, expect, type APIRequestContext } from "@playwright/test";
import { dav, USERS, PASSWORD, hrefs, vcard, runPrefix, type DavUser, type DavResponse } from "../helpers/dav";

test.describe.configure({ mode: "serial" });

const BOOK = "/dav/addressbooks/default/";
const VCARD_HEADERS = { "Content-Type": "text/vcard; charset=utf-8" };

const PROPFIND_ETAG =
  `<?xml version="1.0" encoding="UTF-8"?>` +
  `<d:propfind xmlns:d="DAV:"><d:prop><d:getetag/></d:prop></d:propfind>`;

function basic(email: string, password: string): Record<string, string> {
  return { Authorization: "Basic " + Buffer.from(`${email}:${password}`).toString("base64") };
}

async function raw(
  request: APIRequestContext,
  method: string,
  path: string,
  headers: Record<string, string>,
  body?: string,
): Promise<DavResponse> {
  return dav(request, method, path, { user: null, headers: { Depth: "0", ...headers }, body });
}

async function members(request: APIRequestContext, user: DavUser): Promise<string[]> {
  const res = await dav(request, "PROPFIND", BOOK, { user, headers: { Depth: "1" }, body: PROPFIND_ETAG });
  expect(res.status, res.body.slice(0, 300)).toBe(207);
  return hrefs(res.body).filter((h) => h !== BOOK);
}

/** PUT a new vCard as `user` and return the href the server put it at. */
async function create(request: APIRequestContext, user: DavUser, fn: string): Promise<string> {
  const before = new Set(await members(request, user));
  const put = await dav(request, "PUT", `${BOOK}${runPrefix()}-${user}-${Date.now()}.vcf`, {
    user,
    headers: VCARD_HEADERS,
    body: vcard({ fn }),
  });
  expect(put.status, put.body).toBe(201);
  const added = (await members(request, user)).filter((h) => !before.has(h));
  expect(added.length).toBe(1);
  return added[0];
}

async function getBody(request: APIRequestContext, user: DavUser, href: string): Promise<DavResponse> {
  return dav(request, "GET", href, { user });
}

function expect401(res: DavResponse): void {
  expect(res.status, res.body.slice(0, 300)).toBe(401);
  expect(res.headers["www-authenticate"]).toMatch(/^Basic realm="[^"]+"/);
  // No body leak: no stack trace, no user data, no hint whether the email exists.
  expect(res.body.length).toBeLessThan(100);
  expect(res.body).not.toMatch(/carddav\.test|password|exception|stacktrace|\.ex:/i);
}

function multigetBody(paths: string[]): string {
  return (
    `<?xml version="1.0" encoding="UTF-8"?>` +
    `<card:addressbook-multiget xmlns:d="DAV:" xmlns:card="urn:ietf:params:xml:ns:carddav">` +
    `<d:prop><d:getetag/><card:address-data/></d:prop>` +
    paths.map((p) => `<d:href>${p}</d:href>`).join("") +
    `</card:addressbook-multiget>`
  );
}

const SYNC_BODY =
  `<?xml version="1.0" encoding="UTF-8"?>` +
  `<d:sync-collection xmlns:d="DAV:" xmlns:card="urn:ietf:params:xml:ns:carddav">` +
  `<d:sync-token/><d:sync-level>1</d:sync-level>` +
  `<d:prop><d:getetag/><card:address-data/></d:prop></d:sync-collection>`;

function queryBody(text: string): string {
  return (
    `<?xml version="1.0" encoding="UTF-8"?>` +
    `<card:addressbook-query xmlns:d="DAV:" xmlns:card="urn:ietf:params:xml:ns:carddav">` +
    `<d:prop><d:getetag/><card:address-data/></d:prop>` +
    `<card:filter><card:prop-filter name="FN">` +
    `<card:text-match match-type="contains">${text}</card:text-match>` +
    `</card:prop-filter></card:filter></card:addressbook-query>`
  );
}

// ── Authentication ────────────────────────────────────────────────────────

test.describe("02 auth: authentication", () => {
  test("A1: missing or bad credentials are a 401 Basic challenge with no leak", async ({ request }) => {
    const admin = USERS.admin.email;
    const cases: [string, Record<string, string>][] = [
      ["no auth", {}],
      ["wrong password", basic(admin, "WrongP@ssword123!")],
      ["unknown email", basic(`${runPrefix()}-nobody@carddav.test`, PASSWORD)],
      ["malformed base64", { Authorization: "Basic !!!not-base64!!!" }],
      ["no colon", { Authorization: "Basic " + Buffer.from(admin).toString("base64") }],
      ["Bearer scheme", { Authorization: "Bearer some-token" }],
      ["password containing ':'", basic(admin, `${PASSWORD}:extra`)],
    ];
    for (const [label, headers] of cases) {
      for (const path of ["/dav/", BOOK]) {
        await test.step(`${label} ${path}`, async () => {
          expect401(await raw(request, "PROPFIND", path, headers, PROPFIND_ETAG));
        });
      }
    }
    // The real credentials still work afterwards.
    expect((await raw(request, "PROPFIND", "/dav/", basic(admin, PASSWORD), PROPFIND_ETAG)).status).toBe(207);
  });

  test("A2: an unconfirmed user is rejected", async ({ request }) => {
    expect401(await dav(request, "PROPFIND", "/dav/", { user: "unconfirmed", headers: { Depth: "0" }, body: PROPFIND_ETAG }));
  });

  test("A3: email case is ignored, as on the web login (citext)", async ({ request }) => {
    // Web login: `users.email` is citext, so `get_user_by_email_and_password`
    // matches `DAV-Admin@…` and the web logs the user in. DAV must agree.
    const mixed = USERS.admin.email.replace("dav-admin", "DAV-Admin");
    const res = await raw(request, "PROPFIND", "/dav/", basic(mixed, PASSWORD), PROPFIND_ETAG);
    expect(res.status).toBe(207);
  });

  test.fixme("A4: TOTP user authenticates over DAV with the password alone (product decision)", async ({
    request,
  }) => {
    // Observed: 207. Recommended: per-user app passwords; until then 2FA users
    // keep DAV access with their password.
    const res = await dav(request, "PROPFIND", "/dav/", { user: "totp", headers: { Depth: "0" }, body: PROPFIND_ETAG });
    expect(res.status).toBe(401);
  });

  test("A5: 11th failure for one IP+email is 429 with Retry-After; others unaffected", async ({ request }) => {
    const victim = `${runPrefix()}-ratelimit-${Date.now()}@carddav.test`;
    for (let i = 1; i <= 10; i++) {
      const res = await raw(request, "PROPFIND", "/dav/", basic(victim, `wrong-${i}`), PROPFIND_ETAG);
      expect(res.status, `attempt ${i}`).toBe(401);
    }
    const locked = await raw(request, "PROPFIND", "/dav/", basic(victim, "wrong-11"), PROPFIND_ETAG);
    expect(locked.status).toBe(429);
    const retryAfter = Number(locked.headers["retry-after"]);
    expect(Number.isInteger(retryAfter)).toBe(true);
    expect(retryAfter).toBeGreaterThan(0);
    expect(retryAfter).toBeLessThanOrEqual(300);

    // A different email from the same IP is not throttled.
    const ok = await raw(request, "PROPFIND", "/dav/", basic(USERS.admin.email, PASSWORD), PROPFIND_ETAG);
    expect(ok.status).toBe(207);
    // Nor are chatty successful clients.
    for (let i = 0; i < 15; i++) {
      expect((await dav(request, "PROPFIND", "/dav/", { headers: { Depth: "0" }, body: PROPFIND_ETAG })).status).toBe(207);
    }
  });
});

// ── Multitenancy ──────────────────────────────────────────────────────────

test.describe("02 auth: multitenancy", () => {
  let hrefA = "";
  let bodyA = "";
  const fnA = `${runPrefix()} Tenant A`;

  test.beforeAll(async ({ request }) => {
    hrefA = await create(request, "admin", fnA);
    const res = await getBody(request, "admin", hrefA);
    expect(res.status).toBe(200);
    bodyA = res.body;
  });

  async function expectAUnchanged(request: APIRequestContext): Promise<void> {
    const res = await getBody(request, "admin", hrefA);
    expect(res.status).toBe(200);
    expect(res.body).toBe(bodyA);
  }

  test("M1: other cannot GET, PUT, DELETE, PROPFIND or multiget A's hrefs", async ({ request }) => {
    expect((await dav(request, "GET", hrefA, { user: "other" })).status).toBe(404);

    const del = await dav(request, "DELETE", hrefA, { user: "other" });
    expect(del.status).toBe(404);

    const pf = await dav(request, "PROPFIND", hrefA, { user: "other", headers: { Depth: "0" }, body: PROPFIND_ETAG });
    expect(pf.status).toBe(404);

    const mg = await dav(request, "REPORT", BOOK, { user: "other", headers: { Depth: "1" }, body: multigetBody([hrefA]) });
    expect(mg.status).toBe(207);
    expect(mg.body).toMatch(/404 Not Found/);
    expect(mg.body).not.toContain(fnA);

    await expectAUnchanged(request);
  });

  test("M2: other's sync-collection and addressbook-query never return A's contacts", async ({ request }) => {
    for (const body of [SYNC_BODY, queryBody(runPrefix())]) {
      const res = await dav(request, "REPORT", BOOK, { user: "other", headers: { Depth: "1" }, body });
      expect(res.status).toBe(207);
      expect(res.body).not.toContain(fnA);
      expect(hrefs(res.body)).not.toContain(hrefA);
    }
  });

  test("M3: other PUT to A's href does not overwrite A; anything created lives in B", async ({ request }) => {
    const fnB = `${runPrefix()} Hijack`;
    const before = new Set(await members(request, "other"));
    const put = await dav(request, "PUT", hrefA, { user: "other", headers: VCARD_HEADERS, body: vcard({ fn: fnB }) });
    expect([201, 204, 403, 404, 409]).toContain(put.status);
    await expectAUnchanged(request);

    const query = await dav(request, "REPORT", BOOK, { headers: { Depth: "1" }, body: queryBody(fnB) });
    expect(query.status).toBe(207);
    expect(query.body).not.toContain(fnB);

    // Clean up whatever B got.
    for (const h of (await members(request, "other")).filter((h) => !before.has(h))) {
      const g = await getBody(request, "other", h);
      if (g.body.includes(fnB)) await dav(request, "DELETE", h, { user: "other" });
    }
  });
});

// ── Roles ─────────────────────────────────────────────────────────────────

test.describe("02 auth: roles", () => {
  let href = "";
  let body = "";
  const fn = `${runPrefix()} Role Target`;

  test.beforeAll(async ({ request }) => {
    href = await create(request, "admin", fn);
    body = (await getBody(request, "admin", href)).body;
  });

  test("RL1: viewer can PROPFIND, GET and REPORT", async ({ request }) => {
    const pf = await dav(request, "PROPFIND", BOOK, { user: "viewer", headers: { Depth: "1" }, body: PROPFIND_ETAG });
    expect(pf.status).toBe(207);
    expect(hrefs(pf.body)).toContain(href);
    expect((await getBody(request, "viewer", href)).status).toBe(200);
    for (const b of [multigetBody([href]), SYNC_BODY, queryBody(fn)]) {
      const r = await dav(request, "REPORT", BOOK, { user: "viewer", headers: { Depth: "1" }, body: b });
      expect(r.status).toBe(207);
      expect(r.body).toContain(fn);
    }
  });

  test("RL2: viewer PUT (new and existing), DELETE and PROPPATCH are 403 and change nothing", async ({
    request,
  }) => {
    const before = await members(request, "admin");
    const newFn = `${runPrefix()} Viewer New`;

    const putNew = await dav(request, "PUT", `${BOOK}${runPrefix()}-viewer-new.vcf`, {
      user: "viewer",
      headers: VCARD_HEADERS,
      body: vcard({ fn: newFn }),
    });
    expect(putNew.status).toBe(403);

    const putExisting = await dav(request, "PUT", href, {
      user: "viewer",
      headers: VCARD_HEADERS,
      body: vcard({ fn: `${runPrefix()} Viewer Edit` }),
    });
    expect(putExisting.status).toBe(403);

    expect((await dav(request, "DELETE", href, { user: "viewer" })).status).toBe(403);

    const pp = await dav(request, "PROPPATCH", BOOK, {
      user: "viewer",
      body:
        `<?xml version="1.0" encoding="UTF-8"?><d:propertyupdate xmlns:d="DAV:">` +
        `<d:set><d:prop><d:displayname>Hacked</d:displayname></d:prop></d:set></d:propertyupdate>`,
    });
    expect(pp.status).toBe(403);

    expect(await members(request, "admin")).toEqual(before);
    const after = await getBody(request, "admin", href);
    expect(after.status).toBe(200);
    expect(after.body).toBe(body);
  });

  test("RL3: editor can PUT (new and existing) and DELETE", async ({ request }) => {
    const editorHref = await create(request, "editor", `${runPrefix()} Editor New`);

    const upd = await dav(request, "PUT", href, {
      user: "editor",
      headers: VCARD_HEADERS,
      body: vcard({ fn: `${fn} Edited` }),
    });
    expect(upd.status).toBe(204);
    expect((await getBody(request, "admin", href)).body).toContain(`${fn} Edited`);

    expect((await dav(request, "DELETE", editorHref, { user: "editor" })).status).toBe(204);
    expect((await getBody(request, "admin", editorHref)).status).toBe(404);
  });
});
