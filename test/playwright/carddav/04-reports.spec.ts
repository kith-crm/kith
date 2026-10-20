import { test, expect, type APIRequestContext } from "@playwright/test";
import { randomUUID } from "node:crypto";
import {
  dav,
  USERS,
  hrefs,
  responseFor,
  propText,
  vcard,
  runPrefix,
  assertWellFormedXml,
  type DavResponse,
} from "../helpers/dav";
import { loginUser } from "../helpers/auth";

test.describe.configure({ mode: "serial" });

const BOOK = "/dav/addressbooks/default/";
const VCARD_HEADERS = { "Content-Type": "text/vcard; charset=utf-8" };
const P = `${runPrefix()}-rep`;
const NS = `xmlns:d="DAV:" xmlns:card="urn:ietf:params:xml:ns:carddav"`;
const NOT_FOUND = "HTTP/1.1 404 Not Found";

// ── helpers ──────────────────────────────────────────────────────────────

async function report(request: APIRequestContext, body: string, headers: Record<string, string> = {}) {
  return dav(request, "REPORT", BOOK, { headers: { Depth: "1", ...headers }, body });
}

async function put(request: APIRequestContext, href: string, body: string, headers: Record<string, string> = {}) {
  const res = await dav(request, "PUT", href, { headers: { ...VCARD_HEADERS, ...headers }, body });
  expect([201, 204], res.body.slice(0, 300)).toContain(res.status);
  return res;
}

function multiget(hrefList: string[], prop = "<d:getetag/><card:address-data/>"): string {
  return (
    `<?xml version="1.0" encoding="UTF-8"?>` +
    `<card:addressbook-multiget ${NS}><d:prop>${prop}</d:prop>` +
    hrefList.map((h) => `<d:href>${h}</d:href>`).join("") +
    `</card:addressbook-multiget>`
  );
}

function syncBody(token: string, extra = "", prop = "<d:getetag/><card:address-data/>"): string {
  return (
    `<?xml version="1.0" encoding="UTF-8"?>` +
    `<d:sync-collection ${NS}><d:sync-token>${token}</d:sync-token>` +
    `<d:sync-level>1</d:sync-level>${extra}<d:prop>${prop}</d:prop></d:sync-collection>`
  );
}

function queryBody(filter: string, opts: { test?: string; prop?: string; limit?: number } = {}): string {
  const testAttr = opts.test ? ` test="${opts.test}"` : "";
  const limit = opts.limit ? `<card:limit><card:nresults>${opts.limit}</card:nresults></card:limit>` : "";
  return (
    `<?xml version="1.0" encoding="UTF-8"?>` +
    `<card:addressbook-query ${NS}><d:prop>${opts.prop ?? "<d:getetag/><card:address-data/>"}</d:prop>` +
    `<card:filter${testAttr}>${filter}</card:filter>${limit}</card:addressbook-query>`
  );
}

function textMatch(prop: string, text: string, attrs = ""): string {
  return `<card:prop-filter name="${prop}"><card:text-match ${attrs}>${text}</card:text-match></card:prop-filter>`;
}

async function sync(request: APIRequestContext, token: string, extra = "", prop?: string): Promise<DavResponse> {
  return report(request, syncBody(token, extra, prop));
}

async function syncOk(request: APIRequestContext, token: string): Promise<{ body: string; token: string }> {
  const res = await sync(request, token);
  expect(res.status, res.body.slice(0, 400)).toBe(207);
  assertWellFormedXml(res.body);
  const next = propText(res.body, "sync-token");
  expect(next).toMatch(/^https?:\/\/\S+$/);
  return { body: res.body, token: next! };
}

/** Member hrefs (everything except the book itself). */
/** The vCard inside a response block's address-data (CDATA unwrapped), trimmed. */
function addressData(block: string): string | undefined {
  const raw = propText(block, "address-data");
  return raw?.replace(/^<!\[CDATA\[/, "").replace(/\]\]>$/, "").replace(/\]\]\]\]><!\[CDATA\[>/g, "]]>").trim();
}

function members(xml: string): string[] {
  return hrefs(xml).filter((h) => h !== BOOK);
}

/** The response block for href has a bare 404 status and no propstat (RFC 6578 §3.5). */
function expectRemoved(xml: string, href: string): void {
  const block = responseFor(xml, href);
  expect(block, `no response for ${href}`).toBeDefined();
  expect(block).not.toMatch(/propstat/);
  expect(propText(block!, "status")).toBe(NOT_FOUND);
}

function expectPresent(xml: string, href: string): string {
  const block = responseFor(xml, href);
  expect(block, `no response for ${href}`).toBeDefined();
  expect(block).toMatch(/HTTP\/1\.1 200 OK/);
  return block!;
}

async function ctag(request: APIRequestContext): Promise<string> {
  const res = await dav(request, "PROPFIND", BOOK, {
    headers: { Depth: "0" },
    body: `<?xml version="1.0"?><d:propfind xmlns:d="DAV:" xmlns:cs="http://calendarserver.org/ns/"><d:prop><cs:getctag/><d:sync-token/></d:prop></d:propfind>`,
  });
  expect(res.status).toBe(207);
  return propText(res.body, "getctag")!;
}

async function initialToken(request: APIRequestContext): Promise<string> {
  return (await syncOk(request, "")).token;
}

// ── REST API (for context operations: trash, restore, archive) ───────────

let apiToken: string | undefined;

async function api(request: APIRequestContext, method: string, path: string, data?: unknown) {
  if (!apiToken) {
    const res = await request.post("/api/auth/token", {
      data: { email: USERS.admin.email, password: USERS.admin.password },
    });
    expect(res.status()).toBe(201);
    apiToken = (await res.json()).token;
  }
  const res = await request.fetch(path, {
    method,
    headers: { Authorization: `Bearer ${apiToken}`, "Content-Type": "application/json" },
    data: data === undefined ? undefined : JSON.stringify(data),
    failOnStatusCode: false,
  });
  expect(res.status(), `${method} ${path}: ${(await res.text()).slice(0, 300)}`).toBeLessThan(300);
  return res.status() === 204 ? null : await res.json();
}

async function apiContact(request: APIRequestContext, first: string, last: string): Promise<{ id: number; href: string }> {
  const json = await api(request, "POST", "/api/contacts", { contact: { first_name: first, last_name: last } });
  const id = json.data.id as number;
  return { id, href: `${BOOK}kith-contact-${id}.vcf` };
}

// ── shared fixtures ──────────────────────────────────────────────────────

const uuidName = `${randomUUID().toUpperCase()}.vcf`;
const uuidHref = `${BOOK}${uuidName}`;
const clientHref = `${BOOK}${P}-r2.vcf`;
let defaultHref = "";

test.beforeAll(async ({ request }) => {
  await put(request, clientHref, vcard({ fn: `${P} Rtwo Client`, uid: `${P}-r2-uid` }));
  await put(request, uuidHref, vcard({ fn: `${P} Ruuid Apple`, uid: uuidName.replace(".vcf", "") }));
  defaultHref = (await apiContact(request, `${P}`, "Rdefault")).href;
});

// ── R: multiget ──────────────────────────────────────────────────────────

test.describe("REPORT dispatch and multiget", () => {
  test("R1 dispatch uses the root element", async ({ request }) => {
    await put(request, `${BOOK}${P}-r1.vcf`, vcard({ fn: `${P} sync-collection addressbook-multiget` }));

    for (const text of ["sync-collection", "addressbook-multiget"]) {
      const filter = textMatch("FN", P, `match-type="starts-with"`) + textMatch("FN", text);
      const res = await report(request, queryBody(filter, { test: "allof", prop: "<d:getetag/>" }));
      expect(res.status, res.body.slice(0, 300)).toBe(207);
      expect(members(res.body)).toEqual([`${BOOK}${P}-r1.vcf`]);
      expect(propText(res.body, "sync-token")).toBeUndefined();
    }

    const unknown = await report(request, `<?xml version="1.0"?><d:unknown-report xmlns:d="DAV:"/>`);
    expect([403, 501], unknown.body).toContain(unknown.status);
    if (unknown.status === 403) expect(unknown.body).toMatch(/supported-report/);

    const malformed = await report(request, `<card:addressbook-multiget ${NS}><d:href>x</d:prop>`);
    expect(malformed.status).toBe(400);

    const empty = await report(request, "");
    expect(empty.status).toBe(400);
  });

  test("R2 multiget prefixes, absolute and percent-encoded hrefs give identical results", async ({ request, baseURL }) => {
    const name = `${P}-r2.vcf`;
    const encoded = BOOK + name.replace(/-/g, "%2D");
    const variants: string[] = [
      multiget([clientHref]),
      `<?xml version="1.0"?><C:addressbook-multiget xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:carddav"><D:prop><D:getetag/><C:address-data/></D:prop><D:href>${clientHref}</D:href></C:addressbook-multiget>`,
      `<?xml version="1.0"?><A:addressbook-multiget xmlns:A="urn:ietf:params:xml:ns:carddav" xmlns:B="DAV:"><B:prop><B:getetag/><A:address-data/></B:prop><B:href>${clientHref}</B:href></A:addressbook-multiget>`,
      `<?xml version="1.0"?><addressbook-multiget xmlns="urn:ietf:params:xml:ns:carddav"><prop xmlns="DAV:"><getetag/><address-data xmlns="urn:ietf:params:xml:ns:carddav"/></prop><href xmlns="DAV:">${clientHref}</href></addressbook-multiget>`,
      multiget([`${baseURL}${clientHref}`]),
      multiget([encoded]),
    ];

    const get = await dav(request, "GET", clientHref);
    expect(get.status).toBe(200);

    for (const body of variants) {
      const res = await report(request, body);
      expect(res.status, `${body}\n${res.body.slice(0, 300)}`).toBe(207);
      assertWellFormedXml(res.body);
      expect(members(res.body), body).toEqual([clientHref]);
      const block = expectPresent(res.body, clientHref);
      expect(propText(block, "getetag")).toBe(get.headers["etag"]);
      expect(addressData(block)).toBe(get.body.trim());
    }
  });

  test("R3 multiget with a missing href: bare 404 status; found ones match GET", async ({ request }) => {
    const missing = `${BOOK}${P}-missing.vcf`;
    const res = await report(request, multiget([clientHref, missing]));
    expect(res.status).toBe(207);
    assertWellFormedXml(res.body);
    expectRemoved(res.body, missing);

    const get = await dav(request, "GET", clientHref);
    const block = expectPresent(res.body, clientHref);
    expect(propText(block, "getetag")).toBe(get.headers["etag"]);
    expect(addressData(block)).toBe(get.body.trim());
  });

  test("R4 multiget mixing kith-contact-N.vcf and <uuid>.vcf", async ({ request }) => {
    const res = await report(request, multiget([defaultHref, uuidHref]));
    expect(res.status).toBe(207);
    expect(addressData(expectPresent(res.body, defaultHref))).toContain("Rdefault");
    expect(addressData(expectPresent(res.body, uuidHref))).toContain("Ruuid Apple");
  });
});

// ── Q: addressbook-query ─────────────────────────────────────────────────

test.describe("addressbook-query", () => {
  const qa = `${BOOK}${P}-qa.vcf`;
  const qb = `${BOOK}${P}-qb.vcf`;
  const qc = `${BOOK}${P}-qc.vcf`;

  test.beforeAll(async ({ request }) => {
    await put(request, qa, vcard({ fn: `${P} Qalpha`, email: `${P}-qa@example.test`, tel: "+1 555 0001111" }));
    await put(request, qb, vcard({ fn: `${P} Qbeta`, email: `${P}-qb@example.test` }));
    await put(request, qc, vcard({ fn: `${P} Qgamma` }));
  });

  async function q(request: APIRequestContext, body: string): Promise<string[]> {
    const res = await report(request, body);
    expect(res.status, res.body.slice(0, 400)).toBe(207);
    assertWellFormedXml(res.body);
    return members(res.body).sort();
  }

  const mine = textMatch("FN", `${P} Q`, `match-type="starts-with"`);

  test("Q1 match types, negate, anyof/allof, limit, prefixes, unsupported filters", async ({ request }) => {
    const allof = (f: string) => queryBody(mine + f, { test: "allof" });

    expect(await q(request, allof(textMatch("FN", `${P} Qalpha`, `match-type="equals"`)))).toEqual([qa]);
    expect(await q(request, allof(textMatch("FN", `${P} qal`, `match-type="starts-with"`)))).toEqual([qa]);
    expect(await q(request, allof(textMatch("FN", "BETA", `match-type="ends-with"`)))).toEqual([qb]);
    expect(await q(request, allof(textMatch("FN", "gamm", `match-type="contains"`)))).toEqual([qc]);
    expect(await q(request, allof(textMatch("EMAIL", `${P}-qa@`, `match-type="starts-with"`)))).toEqual([qa]);
    expect(await q(request, allof(textMatch("TEL", "0001111")))).toEqual([qa]);
    expect(await q(request, allof(textMatch("FN", "Qalpha", `negate-condition="yes"`)))).toEqual([qb, qc]);
    expect(
      await q(request, allof(`<card:prop-filter name="EMAIL"><card:is-not-defined/></card:prop-filter>`)),
    ).toEqual([qc]);

    // anyof (also the default) is a union
    const either = textMatch("FN", `${P} Qalpha`, `match-type="equals"`) + textMatch("FN", `${P} Qbeta`, `match-type="equals"`);
    expect(await q(request, queryBody(either, { test: "anyof" }))).toEqual([qa, qb]);
    expect(await q(request, queryBody(either))).toEqual([qa, qb]);
    // allof is an intersection
    expect(await q(request, queryBody(either, { test: "allof" }))).toEqual([]);

    // other prefixes
    const prefixed =
      `<?xml version="1.0"?><C:addressbook-query xmlns:A="DAV:" xmlns:C="urn:ietf:params:xml:ns:carddav">` +
      `<A:prop><A:getetag/></A:prop><C:filter><C:prop-filter name="FN"><C:text-match match-type="equals">${P} Qbeta</C:text-match></C:prop-filter></C:filter></C:addressbook-query>`;
    expect(await q(request, prefixed)).toEqual([qb]);

    // limit: at most N results, plus a 507 for the request-URI (RFC 6352 §8.6.1)
    const limited = await report(request, queryBody(mine, { limit: 1 }));
    expect(limited.status).toBe(207);
    expect(members(limited.body).length).toBe(1);
    expect(propText(responseFor(limited.body, BOOK)!, "status")).toBe("HTTP/1.1 507 Insufficient Storage");

    // unsupported filters are refused, not "match all"
    const badType = await report(request, queryBody(textMatch("FN", "x", `match-type="regex"`)));
    expect(badType.status, badType.body.slice(0, 300)).toBe(403);
    expect(badType.body).toMatch(/supported-filter/);
    const badCollation = await report(request, queryBody(textMatch("FN", "x", `collation="x-bogus"`)));
    expect(badCollation.status).toBe(403);
    expect(badCollation.body).toMatch(/supported-collation/);
  });

  test("Q2 query requesting only getetag has no address-data", async ({ request }) => {
    const res = await report(request, queryBody(mine, { prop: "<d:getetag/>" }));
    expect(res.status).toBe(207);
    expect(members(res.body)).toContain(qa);
    expect(res.body).not.toMatch(/address-data/);
    expect(propText(responseFor(res.body, qa)!, "getetag")).toMatch(/^"[^"]+"$/);
  });
});

// ── S: sync-collection ───────────────────────────────────────────────────

test.describe("sync-collection", () => {
  test("S1 initial sync lists every active contact and a URI token", async ({ request }) => {
    const { body } = await syncOk(request, "");
    const list = members(body);
    for (const h of [clientHref, uuidHref, defaultHref]) expect(list).toContain(h);

    const propfind = await dav(request, "PROPFIND", BOOK, {
      headers: { Depth: "1" },
      body: `<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop><d:getetag/></d:prop></d:propfind>`,
    });
    expect(list.sort()).toEqual(members(propfind.body).sort());
  });

  test("S2 create, edit and DAV DELETE after a token", async ({ request }) => {
    const edit = `${BOOK}${P}-s2-edit.vcf`;
    const del = `${BOOK}${P}-s2-del.vcf`;
    const created = `${BOOK}${P}-s2-new.vcf`;
    await put(request, edit, vcard({ fn: `${P} Stwo Edit` }));
    await put(request, del, vcard({ fn: `${P} Stwo Del` }));

    const token = await initialToken(request);
    await put(request, created, vcard({ fn: `${P} Stwo New` }));
    await put(request, edit, vcard({ fn: `${P} Stwo Edited` }));
    expect((await dav(request, "DELETE", del)).status).toBe(204);

    const { body } = await syncOk(request, token);
    expect(members(body).sort()).toEqual([created, del, edit].sort());
    expect(addressData(expectPresent(body, edit))).toContain("Stwo Edited");
    expectPresent(body, created);
    expectRemoved(body, del);
  });

  test("S3 trash, restore, archive, unarchive after a token", async ({ request }) => {
    const trash = await apiContact(request, P, "Sthree Trash");
    const restore = await apiContact(request, P, "Sthree Restore");
    const archive = await apiContact(request, P, "Sthree Archive");
    const unarchive = await apiContact(request, P, "Sthree Unarchive");
    await api(request, "DELETE", `/api/contacts/${restore.id}`);
    await api(request, "POST", `/api/contacts/${unarchive.id}/archive`);

    const token = await initialToken(request);
    await api(request, "DELETE", `/api/contacts/${trash.id}`);
    await api(request, "POST", `/api/contacts/${restore.id}/restore`);
    await api(request, "POST", `/api/contacts/${archive.id}/archive`);
    await api(request, "DELETE", `/api/contacts/${unarchive.id}/archive`);

    const { body } = await syncOk(request, token);
    expect(members(body).sort()).toEqual([trash.href, restore.href, archive.href, unarchive.href].sort());
    expectRemoved(body, trash.href);
    expectRemoved(body, archive.href);
    expectPresent(body, restore.href);
    expectPresent(body, unarchive.href);
  });

  test("S4 an edit in the same second the token was issued is reported", async ({ request }) => {
    const href = `${BOOK}${P}-s4.vcf`;
    await put(request, href, vcard({ fn: `${P} Sfour Zero` }));
    for (let i = 1; i <= 3; i++) {
      const token = await initialToken(request);
      await put(request, href, vcard({ fn: `${P} Sfour Edit${i}` }));
      const { body } = await syncOk(request, token);
      expect(members(body)).toContain(href);
      expect(addressData(responseFor(body, href)!)).toContain(`Sfour Edit${i}`);
    }
  });

  test("S5 hard delete after a token: 403 valid-sync-token or a 404", async ({ request, page }) => {
    const doomed = await apiContact(request, P, "Sfive Doomed");
    const token = await initialToken(request);
    await api(request, "DELETE", `/api/contacts/${doomed.id}`);

    await loginUser(page, USERS.admin.email, USERS.admin.password);
    page.on("dialog", (d) => d.accept());
    await page.goto("/contacts/trash");
    await page.locator(".phx-connected").first().waitFor();
    const row = page.locator("tr", { hasText: `${P} Sfive Doomed` });
    await row.getByRole("button", { name: /Delete Forever/i }).click();
    await expect(page.locator("tr", { hasText: `${P} Sfive Doomed` })).toHaveCount(0);

    const res = await sync(request, token);
    if (res.status === 403) {
      expect(res.body).toMatch(/valid-sync-token/);
    } else {
      expect(res.status).toBe(207);
      expectRemoved(res.body, doomed.href);
    }
    // a fresh initial sync then works, and so does its token
    const fresh = await initialToken(request);
    await syncOk(request, fresh);
  });

  test("S6 garbage or foreign tokens are 403 valid-sync-token", async ({ request }) => {
    for (const bad of [
      "not-a-valid-token-at-all",
      "http://other.example/ns/sync/12345",
      "https://kith.app/ns/sync/1700000000",
      "https://kith.app/ns/sync/99999999999999999999",
    ]) {
      const res = await sync(request, bad);
      expect(res.status, `${bad}: ${res.body.slice(0, 300)}`).toBe(403);
      expect(res.body).toMatch(/valid-sync-token/);
    }
  });

  test("S7 PROPFIND sync-token works; ctag changes after every mutation", async ({ request }) => {
    const pf = await dav(request, "PROPFIND", BOOK, {
      headers: { Depth: "0" },
      body: `<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop><d:sync-token/></d:prop></d:propfind>`,
    });
    const token = propText(pf.body, "sync-token")!;
    const older = `${BOOK}${P}-s7-old.vcf`;
    await put(request, older, vcard({ fn: `${P} Sseven Old` }));
    await put(request, `${BOOK}${P}-s7-newer.vcf`, vcard({ fn: `${P} Sseven Newer` }));
    const { body } = await syncOk(request, token);
    expect(members(body)).toContain(older);

    const c = await apiContact(request, P, "Sseven Ctx");
    const mutations: [string, () => Promise<unknown>][] = [
      ["create", () => put(request, `${BOOK}${P}-s7-c.vcf`, vcard({ fn: `${P} Sseven C` }))],
      ["edit", () => put(request, `${BOOK}${P}-s7-c.vcf`, vcard({ fn: `${P} Sseven C2` }))],
      ["delete non-newest", () => dav(request, "DELETE", older)],
      ["trash", () => api(request, "DELETE", `/api/contacts/${c.id}`)],
      ["restore", () => api(request, "POST", `/api/contacts/${c.id}/restore`)],
      ["archive", () => api(request, "POST", `/api/contacts/${c.id}/archive`)],
      ["unarchive", () => api(request, "DELETE", `/api/contacts/${c.id}/archive`)],
    ];
    let before = await ctag(request);
    for (const [label, mutate] of mutations) {
      await mutate();
      const after = await ctag(request);
      expect(after, `ctag unchanged after ${label}`).not.toBe(before);
      before = after;
    }
  });

  test("S8 sync-level infinite and <d:limit>", async ({ request }) => {
    const inf = await report(
      request,
      syncBody("", "").replace("<d:sync-level>1</d:sync-level>", "<d:sync-level>infinite</d:sync-level>"),
    );
    expect([207, 403], inf.body.slice(0, 300)).toContain(inf.status);
    if (inf.status === 207) expect(members(inf.body)).toContain(clientHref);

    const limited = await sync(request, "", "<d:limit><d:nresults>1</d:nresults></d:limit>");
    if (limited.status === 507) {
      expect(limited.body).toMatch(/number-of-matches-within-limits/);
    } else {
      expect(limited.status).toBe(207);
      expect(members(limited.body).filter((h) => responseFor(limited.body, h)!.includes("200 OK")).length).toBeLessThanOrEqual(1);
    }
  });
});
