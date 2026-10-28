import { wireUid } from "../helpers/dav";
import { test, expect, type APIRequestContext } from "@playwright/test";
import { randomUUID } from "node:crypto";
import http from "node:http";
import { dav, USERS, hrefs, vcard, runPrefix, assertWellFormedXml, type DavResponse } from "../helpers/dav";

test.describe.configure({ mode: "serial" });

const BOOK = "/dav/addressbooks/default/";
const VCARD_HEADERS = { "Content-Type": "text/vcard; charset=utf-8" };
const STRONG_ETAG = /^"[^"]+"$/;

const PROPFIND_ETAG =
  `<?xml version="1.0" encoding="UTF-8"?>` +
  `<d:propfind xmlns:d="DAV:"><d:prop><d:getetag/></d:prop></d:propfind>`;

/** Raw PROPFIND Depth 1 body of the address book. */
async function listing(request: APIRequestContext): Promise<string> {
  const res = await dav(request, "PROPFIND", BOOK, { headers: { Depth: "1" }, body: PROPFIND_ETAG });
  expect(res.status, res.body.slice(0, 300)).toBe(207);
  assertWellFormedXml(res.body);
  return res.body;
}

async function members(request: APIRequestContext): Promise<string[]> {
  return hrefs(await listing(request)).filter((h) => h !== BOOK);
}

async function put(
  request: APIRequestContext,
  href: string,
  body: string,
  headers: Record<string, string> = {},
): Promise<DavResponse> {
  return dav(request, "PUT", href, { headers: { ...VCARD_HEADERS, ...headers }, body });
}

async function get(request: APIRequestContext, href: string, headers: Record<string, string> = {}) {
  return dav(request, "GET", href, { headers });
}

function expectNot500(res: DavResponse): void {
  expect(res.status, res.body.slice(0, 300)).toBeLessThan(500);
}

/**
 * Sends a request with a byte-exact path (no WHATWG URL normalisation of `%2E%2E`).
 * A response that arrives before the server closes a half-sent upload (an early
 * 413) still counts: the later ECONNRESET / EPIPE is ignored.
 */
function rawRequest(
  method: string,
  path: string,
  body?: string,
  opts: { chunked?: boolean } = {},
): Promise<{ status: number; body: string }> {
  const base = new URL(process.env.PLAYWRIGHT_BASE_URL ?? "http://127.0.0.1:4517");
  const { email, password } = USERS.admin;
  return new Promise((resolve, reject) => {
    const req = http.request(
      {
        host: base.hostname,
        port: base.port,
        method,
        path,
        // A fresh connection per request: the server may close one after an early answer.
        agent: false,
        headers: {
          Authorization: "Basic " + Buffer.from(`${email}:${password}`).toString("base64"),
          ...(body !== undefined ? { "Content-Type": "text/vcard; charset=utf-8" } : {}),
          // Node sends a body without Content-Length as chunked, which DAV refuses with 411.
          ...(body !== undefined && !opts.chunked ? { "Content-Length": String(Buffer.byteLength(body)) } : {}),
        },
      },
      (res) => {
        let data = "";
        res.on("data", (c) => (data += c));
        res.on("end", () => resolve({ status: res.statusCode ?? 0, body: data }));
      },
    );
    let status = 0;
    req.on("response", (res) => (status = res.statusCode ?? 0));
    req.on("error", (e) => (status ? resolve({ status, body: "" }) : reject(e)));
    if (body === undefined) return void req.end();
    // Like curl: upload in slices and stop once an early final response (e.g. 413) has arrived
    // (RFC 9112 §9.6), instead of pushing the rest into a connection the server is done with.
    const data = Buffer.from(body);
    const slice = 64 * 1024;
    const pump = (offset: number): void => {
      if (status) return void req.destroy();
      if (offset >= data.length) return void req.end();
      const more = req.write(data.subarray(offset, offset + slice));
      if (more) setImmediate(() => pump(offset + slice));
      else req.once("drain", () => pump(offset + slice));
    };
    pump(0);
  });
}

/** Waits until the wall clock has just entered a new second. */
async function atSecondStart(): Promise<void> {
  const ms = Date.now() % 1000;
  if (ms > 50) await new Promise((r) => setTimeout(r, 1000 - ms + 5));
}

// ── Create / update / delete ──────────────────────────────────────────────

test.describe("03 crud: application-named resource", () => {
  let href = "";
  const fn = `${runPrefix()} Crud One`;
  let etag = "";

  test("PUT a new arbitrary resource with If-None-Match: * is served at that href", async ({ request }) => {
    href = `${BOOK}${randomUUID()}.vcf`;
    const res = await put(request, href, vcard({ fn, email: "crud1@example.com" }), { "If-None-Match": "*" });
    expect(res.status, res.body).toBe(201);
    expect(res.headers["etag"]).toBeUndefined();

    const g = await get(request, href);
    expect(g.status, g.body).toBe(200);
    etag = g.headers["etag"];
    expect(etag).toMatch(STRONG_ETAG);
    expect(g.headers["content-type"]).toBe("text/vcard; charset=utf-8");
    expect(g.body).toContain(`FN:${fn}`);
  });

  test("C2: GET then PUT an edit with If-Match: <etag> gives a new ETag and the edit", async ({ request }) => {
    const res = await put(request, href, vcard({ fn: `${fn} Edited`, email: "crud1@example.com" }), {
      "If-Match": etag,
    });
    expect([200, 201, 204], res.body).toContain(res.status);
    expect(res.headers["etag"]).toBeUndefined();

    const g = await get(request, href);
    expect(g.body).toContain(`FN:${fn} Edited`);
    expect(g.headers["etag"]).toMatch(STRONG_ETAG);
    etag = g.headers["etag"];
  });

  test("K1: PUT on an existing href with If-None-Match: * is 412", async ({ request }) => {
    const res = await put(request, href, vcard({ fn: `${fn} K1` }), { "If-None-Match": "*" });
    expect(res.status).toBe(412);
    expect((await get(request, href)).body).not.toContain("K1");
  });

  test("K2: PUT or DELETE with a stale If-Match is 412 and changes nothing", async ({ request }) => {
    const stale = `"stale-${Date.now()}"`;
    const p = await put(request, href, vcard({ fn: `${fn} K2` }), { "If-Match": stale });
    expect(p.status, p.body).toBe(412);
    const d = await dav(request, "DELETE", href, { headers: { "If-Match": stale } });
    expect(d.status).toBe(412);
    const g = await get(request, href);
    expect(g.status).toBe(200);
    expect(g.body).not.toContain("K2");
    expect(g.headers["etag"]).toBe(etag);
  });

  test("K4: GET with If-None-Match: <current etag> is 304 with no body", async ({ request }) => {
    const g = await get(request, href, { "If-None-Match": etag });
    expect(g.status).toBe(304);
    expect(g.body).toBe("");
    const other = await get(request, href, { "If-None-Match": `"nope"` });
    expect(other.status).toBe(200);
    const star = await get(request, href, { "If-None-Match": "*" });
    expect(star.status).toBe(304);
  });

  test("K5: If-Match lists match any strong tag; W/ weak tags never match", async ({ request }) => {
    const list = await put(request, href, vcard({ fn: `${fn} K5` }), { "If-Match": `"a", ${etag}` });
    expect([200, 201, 204], list.body).toContain(list.status);
    etag = (await get(request, href)).headers["etag"];

    const weak = await put(request, href, vcard({ fn: `${fn} K5 weak` }), { "If-Match": `W/${etag}` });
    expect(weak.status).toBe(412);

    const none = await put(request, href, vcard({ fn: `${fn} K5 none` }), { "If-Match": `"a", "b"` });
    expect(none.status).toBe(412);
    expect((await get(request, href)).body).toContain(`FN:${fn} K5\r\n`);
  });

  test("K6: create plus two edits inside one second give three distinct ETags", async ({ request }) => {
    const h = `${BOOK}${runPrefix()}-k6-${randomUUID()}.vcf`;
    await atSecondStart();
    const c = await put(request, h, vcard({ fn: `${fn} K6`, tel: "+15550000001" }));
    const gc = await get(request, h);
    const e1 = await put(request, h, vcard({ fn: `${fn} K6 one`, tel: "+15550000001" }));
    const ge1 = await get(request, h);
    // Edit 2 changes only a child (TEL), not a scalar field.
    const e2 = await put(request, h, vcard({ fn: `${fn} K6 one`, tel: "+15550000002" }));
    expect([c.status, e1.status, e2.status]).toEqual([201, 204, 204]);
    const ge2 = await get(request, h);
    const tags = [gc.headers["etag"], ge1.headers["etag"], ge2.headers["etag"]];
    expect(new Set(tags).size, tags.join(" ")).toBe(3);
    expect((await get(request, h)).headers["etag"]).toBe(ge2.headers["etag"]);
    await dav(request, "DELETE", h);
  });

  test("E4: DELETE then DELETE again is 404; GET on a trashed contact is 404", async ({ request }) => {
    const d = await dav(request, "DELETE", href, { headers: { "If-Match": etag } });
    expect(d.status).toBe(204);
    expect((await dav(request, "DELETE", href)).status).toBe(404);
    expect((await get(request, href)).status).toBe(404);
    expect(await members(request)).not.toContain(href);
  });
});

test.describe("03 crud: client-named resource", () => {
  const uuid = randomUUID().toUpperCase();
  const href = `${BOOK}${uuid}.vcf`;
  const fn = `${runPrefix()} Crud Uuid`;

  test("C3: PUT <uuid>.vcf is served at that href, keeps its UID and is listed", async ({ request }) => {
    const res = await put(request, href, vcard({ fn, uid: uuid }), { "If-None-Match": "*" });
    expect(res.status, res.body).toBe(201);
    expect(res.headers["etag"]).toBeUndefined();

    const g = await get(request, href);
    expect(g.status, g.body).toBe(200);
    expect(g.body).toContain(`UID:${wireUid(uuid)}\r\n`);
    expect(g.headers["etag"]).toMatch(STRONG_ETAG);
    expect(await members(request)).toContain(href);
  });

  test("C4: PUT the same <uuid>.vcf again updates the same contact, no duplicate", async ({ request }) => {
    const before = await members(request);
    const res = await put(request, href, vcard({ fn: `${fn} Edited`, uid: uuid }));
    expect([200, 204], res.body).toContain(res.status);
    const after = await members(request);
    expect(after.length).toBe(before.length);
    const g = await get(request, href);
    expect(g.body).toContain(`FN:${fn} Edited`);
    expect(g.body).toContain(`UID:${wireUid(uuid)}\r\n`);
  });

  test("C5: DELETE <uuid>.vcf is 204; GET is then 404", async ({ request }) => {
    const d = await dav(request, "DELETE", href);
    expect(d.status).toBe(204);
    expect((await get(request, href)).status).toBe(404);
    expect(await members(request)).not.toContain(href);
  });

  test("PUT to a trashed resource is a conflict and leaves it hidden", async ({ request }) => {
    const res = await put(request, href, vcard({ fn, uid: uuid }));
    expect(res.status).toBe(409);
    expect((await get(request, href)).status).toBe(404);
  });

  test("K3: PUT with If-Match on a non-existent href is 412 and creates nothing", async ({ request }) => {
    const h = `${BOOK}${randomUUID()}.vcf`;
    const before = await members(request);
    const res = await put(request, h, vcard({ fn: `${fn} K3` }), { "If-Match": `"whatever"` });
    expect(res.status).toBe(412);
    expect((await get(request, h)).status).toBe(404);
    expect((await members(request)).length).toBe(before.length);
  });
});

// ── Content type, validation, size ────────────────────────────────────────

test.describe("03 crud: request validation", () => {
  test("E1: text/x-vcard is accepted; application/json is 415", async ({ request }) => {
    const h = `${BOOK}${runPrefix()}-e1-${randomUUID()}.vcf`;
    const x = await dav(request, "PUT", h, {
      headers: { "Content-Type": "text/x-vcard; charset=utf-8" },
      body: vcard({ fn: `${runPrefix()} XVcard` }),
    });
    expect(x.status, x.body).toBe(201);
    // A JSON body: a non-JSON body is already refused with 400 by the endpoint's JSON parser.
    const j = await dav(request, "PUT", `${BOOK}${randomUUID()}.vcf`, {
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ fn: `${runPrefix()} Json` }),
    });
    expect(j.status).toBe(415);
    await dav(request, "DELETE", h);
  });

  test("E2: an invalid vCard is a 4xx valid-address-data, never 500", async ({ request }) => {
    const noBegin = await put(request, `${BOOK}${randomUUID()}.vcf`, "VERSION:3.0\r\nFN:Nope\r\nEND:VCARD\r\n");
    expect(noBegin.status).toBeGreaterThanOrEqual(400);
    expect(noBegin.status).toBeLessThan(500);
    expect(noBegin.body).toContain("valid-address-data");

    const noName = await put(
      request,
      `${BOOK}${randomUUID()}.vcf`,
      "BEGIN:VCARD\r\nVERSION:3.0\r\nNOTE:no name\r\nEND:VCARD\r\n",
    );
    expect(noName.status).toBeGreaterThanOrEqual(400);
    expect(noName.status).toBeLessThan(500);
    expect(noName.body).toContain("valid-address-data");
  });

  test("E3: a PUT body over max-resource-size is 413 (or 403 max-resource-size), never 500", async ({
    request,
  }) => {
    for (const size of [2 * 1024 * 1024, 9 * 1024 * 1024]) {
      const h = `${BOOK}${runPrefix()}-e3-${randomUUID()}.vcf`;
      const big = vcard({ fn: `${runPrefix()} Big`, extra: [`NOTE:${"x".repeat(size)}`] });
      // Raw client: the server answers 413 early and closes the connection mid-upload.
      const res = await rawRequest("PUT", h, big);
      if (res.status === 403) expect(res.body).toContain("max-resource-size");
      else expect(res.status, res.body.slice(0, 200)).toBe(413);
      expect((await get(request, h)).status).toBe(404);
    }
  });

  test("E3b: a chunked PUT body is 411 Length Required before any read", async () => {
    const h = `${BOOK}${runPrefix()}-e3b-${randomUUID()}.vcf`;
    const res = await rawRequest("PUT", h, vcard({ fn: `${runPrefix()} Chunked` }), { chunked: true });
    expect(res.status).toBe(411);
  });
});

// ── Hrefs ────────────────────────────────────────────────────────────────

test.describe("03 crud: href handling", () => {
  test("E6: space and non-ASCII names round-trip; response hrefs are percent-encoded", async ({ request }) => {
    for (const name of [`${runPrefix()} space name.vcf`, `${runPrefix()}-ü-名前.vcf`]) {
      const encoded = `${BOOK}${encodeURIComponent(name)}`;
      const res = await put(request, encoded, vcard({ fn: `${runPrefix()} Href` }));
      expect(res.status, res.body).toBe(201);
      const g = await get(request, encoded);
      expect(g.status).toBe(200);

      const body = await listing(request);
      expect(hrefs(body)).toContain(encoded);
      // Every href in the listing is plain ASCII with no spaces.
      for (const h of hrefs(body)) expect(h).toMatch(/^[\x21-\x7e]+$/);
      expect((await dav(request, "DELETE", encoded)).status).toBe(204);
    }
  });

  test("E6: dot segments, encoded slashes, bad escapes and extra segments are refused, never 500", async ({
    request,
  }) => {
    const before = (await members(request)).length;
    const card = vcard({ fn: `${runPrefix()} Evil` });
    for (const path of [
      `${BOOK}%2E%2E`,
      `${BOOK}..`,
      `${BOOK}a%2Fb.vcf`,
      `${BOOK}%ZZ.vcf`,
      `${BOOK}x/y.vcf`,
    ]) {
      const p = await rawRequest("PUT", path, card);
      expect(p.status, `PUT ${path}`).toBeGreaterThanOrEqual(400);
      expect(p.status, `PUT ${path}`).toBeLessThan(500);
      const g = await rawRequest("GET", path);
      expect(g.status, `GET ${path}`).toBeGreaterThanOrEqual(400);
      expect(g.status, `GET ${path}`).toBeLessThan(500);
    }
    expect((await members(request)).length).toBe(before);
  });

  test("E7: DELETE on the address book or the home set is 403 or 405", async ({ request }) => {
    const before = (await members(request)).length;
    for (const path of [BOOK, "/dav/addressbooks/"]) {
      const res = await dav(request, "DELETE", path);
      expect([403, 405], `DELETE ${path}`).toContain(res.status);
    }
    expect((await members(request)).length).toBe(before);
  });
});
