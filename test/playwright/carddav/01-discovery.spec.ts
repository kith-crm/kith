import { test, expect, type APIRequestContext } from "@playwright/test";
import {
  dav,
  USERS,
  assertWellFormedXml,
  hrefs,
  responseFor,
  propText,
  vcard,
  runPrefix,
  decodeXml,
  type DavResponse,
} from "../helpers/dav";

test.describe.configure({ mode: "serial" });

const BOOK = "/dav/addressbooks/default/";

/** Every 207 must be well-formed XML with the RFC 4918 §8.2 content type. */
function expect207(res: DavResponse): void {
  expect(res.status, res.body.slice(0, 500)).toBe(207);
  expect(res.headers["content-type"]).toBe("application/xml; charset=utf-8");
  assertWellFormedXml(res.body);
}

// ── Tiny namespace-blind structural view of a multistatus ─────────────────

type Child = { name: string; inner: string; selfClosed: boolean };

/** Direct child elements of an XML fragment (local names, prefix stripped). */
function children(fragment: string): Child[] {
  const out: Child[] = [];
  const tag = /<(\/?)([\w.-]+:)?([\w.-]+)((?:\s[^>]*?)?)(\/?)>|<!\[CDATA\[[\s\S]*?\]\]>|<\?[\s\S]*?\?>|<!--[\s\S]*?-->/g;
  let depth = 0;
  let start = -1;
  let current = "";
  let m: RegExpExecArray | null;
  while ((m = tag.exec(fragment))) {
    if (m[3] === undefined) continue; // CDATA / PI / comment
    const closing = m[1] === "/";
    const selfClosing = m[5] === "/";
    if (closing) {
      depth--;
      if (depth === 0) out.push({ name: current, inner: fragment.slice(start, m.index), selfClosed: false });
    } else if (selfClosing) {
      if (depth === 0) out.push({ name: m[3], inner: "", selfClosed: true });
    } else {
      if (depth === 0) {
        current = m[3];
        start = m.index + m[0].length;
      }
      depth++;
    }
  }
  return out;
}

/** Normalised view: href -> status -> {propLocalName: normalisedValue}. */
function shape(xml: string): Record<string, Record<string, Record<string, string>>> {
  const ms = children(xml.replace(/<\?xml[^>]*\?>/, "")).find((c) => c.name === "multistatus");
  const result: Record<string, Record<string, Record<string, string>>> = {};
  for (const r of children(ms ? ms.inner : "").filter((c) => c.name === "response")) {
    const kids = children(r.inner);
    const href = decodeXml(kids.find((k) => k.name === "href")!.inner.trim());
    const byStatus: Record<string, Record<string, string>> = {};
    for (const ps of kids.filter((k) => k.name === "propstat")) {
      const psKids = children(ps.inner);
      const status = psKids.find((k) => k.name === "status")!.inner.trim();
      const prop = psKids.find((k) => k.name === "prop");
      const props: Record<string, string> = {};
      for (const p of children(prop ? prop.inner : "")) {
        props[p.name] = normaliseValue(p.inner);
      }
      byStatus[status] = props;
    }
    result[href] = byStatus;
  }
  return result;
}

function normaliseValue(inner: string): string {
  const kids = children(inner);
  if (kids.length === 0) return decodeXml(inner.trim());
  return kids
    .map((k) => `${k.name}(${normaliseValue(k.inner)})`)
    .sort()
    .join(",");
}

/** shape() with the time-based sync-token value masked (it may tick between two requests). */
function stable(xml: string): ReturnType<typeof shape> {
  const s = shape(xml);
  for (const byStatus of Object.values(s)) {
    const ok = byStatus["HTTP/1.1 200 OK"];
    if (ok?.["sync-token"]) {
      expect(ok["sync-token"]).toMatch(/^[a-z][a-z0-9+.-]*:\S+$/i);
      ok["sync-token"] = "<uri>";
    }
  }
  return s;
}

function okProps(res: DavResponse, href: string): Record<string, string> {
  return shape(res.body)[href]?.["HTTP/1.1 200 OK"] ?? {};
}

function propfindBody(style: "d" | "A" | "default", props: { ns: "DAV:" | "card" | "cs"; name: string }[]): string {
  const NS = { "DAV:": "DAV:", card: "urn:ietf:params:xml:ns:carddav", cs: "http://calendarserver.org/ns/" };
  if (style === "default") {
    // Default namespace = DAV:, foreign props declare their own default xmlns.
    const ps = props
      .map((p) => (p.ns === "DAV:" ? `<${p.name}/>` : `<${p.name} xmlns="${NS[p.ns]}"/>`))
      .join("");
    return `<?xml version="1.0" encoding="utf-8"?><propfind xmlns="DAV:"><prop>${ps}</prop></propfind>`;
  }
  const d = style;
  const ps = props.map((p) => (p.ns === "DAV:" ? `<${d}:${p.name}/>` : `<${p.ns}:${p.name}/>`)).join("");
  return (
    `<?xml version="1.0" encoding="UTF-8"?>` +
    `<${d}:propfind xmlns:${d}="DAV:" xmlns:card="${NS.card}" xmlns:cs="${NS.cs}">` +
    `<${d}:prop>${ps}</${d}:prop></${d}:propfind>`
  );
}

function wholeBody(style: "d" | "A" | "default", kind: "allprop" | "propname"): string {
  if (style === "default") return `<?xml version="1.0"?><propfind xmlns="DAV:"><${kind}/></propfind>`;
  return `<?xml version="1.0"?><${style}:propfind xmlns:${style}="DAV:"><${style}:${kind}/></${style}:propfind>`;
}

const P1_PROPS = [{ ns: "DAV:", name: "current-user-principal" }] as const;
const P2_PROPS = [
  { ns: "card", name: "addressbook-home-set" },
  { ns: "DAV:", name: "principal-URL" },
] as const;
const P3_PROPS = [
  { ns: "DAV:", name: "resourcetype" },
  { ns: "DAV:", name: "displayname" },
] as const;
const P4_PROPS = [
  { ns: "cs", name: "getctag" },
  { ns: "DAV:", name: "sync-token" },
  { ns: "DAV:", name: "supported-report-set" },
  { ns: "DAV:", name: "displayname" },
  { ns: "DAV:", name: "resourcetype" },
] as const;

async function propfind(
  request: APIRequestContext,
  path: string,
  depth: string,
  body: string,
): Promise<DavResponse> {
  return dav(request, "PROPFIND", path, { headers: { Depth: depth }, body });
}

async function memberHrefs(request: APIRequestContext): Promise<string[]> {
  const res = await propfind(request, BOOK, "1", propfindBody("d", [{ ns: "DAV:", name: "getetag" }]));
  expect207(res);
  return hrefs(res.body).filter((h) => h !== BOOK);
}

let contactHref = "";

test.describe("01 discovery, OPTIONS and PROPFIND", () => {
  test.beforeAll(async ({ request }) => {
    const before = new Set(await memberHrefs(request));
    const put = await dav(request, "PUT", `${BOOK}${runPrefix()}-disc.vcf`, {
      headers: { "Content-Type": "text/vcard; charset=utf-8" },
      body: vcard({ fn: `${runPrefix()} Discovery`, email: "disc@example.com" }),
    });
    expect([201, 204]).toContain(put.status);
    const after = await memberHrefs(request);
    const added = after.filter((h) => !before.has(h));
    expect(added.length).toBeGreaterThanOrEqual(1);
    contactHref = added[0];
  });

  // ── Well-known ──────────────────────────────────────────────────────────

  for (const path of ["/.well-known/carddav", "/.well-known/carddav/"]) {
    const id = path.endsWith("/") ? "W2" : "W1";
    for (const method of ["GET", "PROPFIND"]) {
      test(`${id}: unauthed ${method} ${path} redirects to the DAV service`, async ({ request }) => {
        const res = await dav(request, method, path, { user: null, headers: { Depth: "0" } });
        expect([301, 308]).toContain(res.status);
        expect(res.headers["location"]).toMatch(/\/dav\/(principals\/)?$/);
      });
    }
  }

  // ── OPTIONS ─────────────────────────────────────────────────────────────

  test("O1: OPTIONS advertises addressbook and every implemented method", async ({ request }) => {
    for (const path of ["/dav/", BOOK, contactHref]) {
      const res = await dav(request, "OPTIONS", path);
      expect(res.status, path).toBe(200);
      expect(res.headers["dav"], path).toContain("addressbook");
      const allow = (res.headers["allow"] ?? "").split(",").map((s) => s.trim());
      for (const m of ["OPTIONS", "GET", "PUT", "DELETE", "PROPFIND", "PROPPATCH", "REPORT"]) {
        expect(allow, `${path} Allow`).toContain(m);
      }
      const unauthed = await dav(request, "OPTIONS", path, { user: null });
      expect([200, 401], `${path} unauthed`).toContain(unauthed.status);
    }
  });

  // ── PROPFIND discovery chain ───────────────────────────────────────────

  test("P1: current-user-principal on /dav/", async ({ request }) => {
    const res = await propfind(request, "/dav/", "0", propfindBody("d", [...P1_PROPS]));
    expect207(res);
    expect(okProps(res, "/dav/")["current-user-principal"]).toBe("href(/dav/principals/)");
  });

  test("P2: principal addressbook-home-set and principal-URL", async ({ request }) => {
    const res = await propfind(request, "/dav/principals/", "0", propfindBody("d", [...P2_PROPS]));
    expect207(res);
    const p = okProps(res, "/dav/principals/");
    expect(p["addressbook-home-set"]).toBe("href(/dav/addressbooks/)");
    expect(p["principal-URL"]).toBe("href(/dav/principals/)");
  });

  test("P3: home set honours Depth 0 and Depth 1", async ({ request }) => {
    const d0 = await propfind(request, "/dav/addressbooks/", "0", propfindBody("d", [...P3_PROPS]));
    expect207(d0);
    expect(hrefs(d0.body).filter((h) => h)).toEqual(["/dav/addressbooks/"]);

    const d1 = await propfind(request, "/dav/addressbooks/", "1", propfindBody("d", [...P3_PROPS]));
    expect207(d1);
    expect(Object.keys(shape(d1.body)).sort()).toEqual(["/dav/addressbooks/", BOOK]);
    expect(okProps(d1, BOOK)["resourcetype"]).toContain("addressbook(");
  });

  test("P4: address book collection serves every requested prop", async ({ request }) => {
    const res = await propfind(request, BOOK, "0", propfindBody("d", [...P4_PROPS]));
    expect207(res);
    expect(Object.keys(shape(res.body))).toEqual([BOOK]);
    const p = okProps(res, BOOK);
    for (const { name } of P4_PROPS) expect(Object.keys(p), name).toContain(name);
    expect(p["getctag"]).not.toBe("");
    expect(p["sync-token"]).toMatch(/^[a-z][a-z0-9+.-]*:\S+$/i);
    expect(p["supported-report-set"]).toContain("sync-collection");
    expect(p["resourcetype"]).toContain("addressbook(");

    // The PROPFIND sync-token works as a sync-collection token (round trip).
    await new Promise((r) => setTimeout(r, 1100));
    const fresh = okProps(await propfind(request, BOOK, "0", propfindBody("d", [{ ns: "DAV:", name: "sync-token" }])), BOOK);
    const sync = () =>
      dav(request, "REPORT", BOOK, {
        body:
          `<?xml version="1.0" encoding="UTF-8"?><d:sync-collection xmlns:d="DAV:">` +
          `<d:sync-token>${fresh["sync-token"]}</d:sync-token><d:sync-level>1</d:sync-level>` +
          `<d:prop><d:getetag/></d:prop></d:sync-collection>`,
      });
    const unchanged = await sync();
    expect207(unchanged);
    expect(hrefs(unchanged.body).filter((h) => h.endsWith(".vcf"))).toEqual([]);

    await new Promise((r) => setTimeout(r, 1100));
    const put = await dav(request, "PUT", contactHref, {
      headers: { "Content-Type": "text/vcard; charset=utf-8" },
      body: vcard({ fn: `${runPrefix()} Discovery Changed`, email: "disc@example.com" }),
    });
    expect([201, 204]).toContain(put.status);
    const changed = await sync();
    expect207(changed);
    expect(hrefs(changed.body)).toContain(contactHref);
  });

  test("P5: Depth 1 lists active contacts; unknown props get a 404 propstat; infinity is 403", async ({
    request,
  }) => {
    const body =
      `<?xml version="1.0" encoding="UTF-8"?>` +
      `<d:propfind xmlns:d="DAV:"><d:prop><d:getetag/><x:bogus xmlns:x="urn:x"/></d:prop></d:propfind>`;
    const res = await propfind(request, BOOK, "1", body);
    expect207(res);
    const s = shape(res.body);
    const members = Object.keys(s).filter((h) => h !== BOOK);
    expect(members).toContain(contactHref);
    expect(new Set(hrefs(res.body)).size).toBe(hrefs(res.body).length);
    for (const href of members) {
      expect(href.startsWith(BOOK) && href.endsWith(".vcf"), href).toBe(true);
      expect(Object.keys(s[href]["HTTP/1.1 200 OK"] ?? {}), href).toEqual(["getetag"]);
      expect(Object.keys(s[href]["HTTP/1.1 404 Not Found"] ?? {}), href).toEqual(["bogus"]);
    }
    expect(Object.keys(s[BOOK]["HTTP/1.1 404 Not Found"] ?? {})).toContain("bogus");
    // The 404 prop must keep its namespace, not be re-labelled as DAV:.
    expect(responseFor(res.body, contactHref)).toMatch(/<(\w+:)?bogus xmlns(:\w+)?="urn:x"\s*\/>/);

    // A deleted contact disappears from the listing.
    const tmpBefore = new Set(members);
    await dav(request, "PUT", `${BOOK}${runPrefix()}-gone.vcf`, {
      headers: { "Content-Type": "text/vcard; charset=utf-8" },
      body: vcard({ fn: `${runPrefix()} Gone` }),
    });
    const gone = (await memberHrefs(request)).find((h) => !tmpBefore.has(h))!;
    expect(gone).toBeTruthy();
    expect((await dav(request, "DELETE", gone)).status).toBe(204);
    expect(await memberHrefs(request)).not.toContain(gone);

    const inf = await propfind(request, BOOK, "infinity", propfindBody("d", [{ ns: "DAV:", name: "getetag" }]));
    expect(inf.status).toBe(403);
    expect(inf.body).toContain("propfind-finite-depth");
    assertWellFormedXml(inf.body);
  });

  // ── Prefix independence ────────────────────────────────────────────────

  const cases: [string, string, string, readonly { ns: "DAV:" | "card" | "cs"; name: string }[]][] = [
    ["P1", "/dav/", "0", P1_PROPS],
    ["P2", "/dav/principals/", "0", P2_PROPS],
    ["P3", "/dav/addressbooks/", "1", P3_PROPS],
    ["P4", BOOK, "0", P4_PROPS],
  ];

  for (const style of ["A", "default"] as const) {
    test(`P6: ${style}-prefixed requests match the d: form`, async ({ request }) => {
      for (const [id, path, depth, props] of cases) {
        const ref = await propfind(request, path, depth, propfindBody("d", [...props]));
        const alt = await propfind(request, path, depth, propfindBody(style, [...props]));
        expect207(alt);
        expect(stable(alt.body), `${id} ${style}`).toEqual(stable(ref.body));
      }
      for (const kind of ["allprop", "propname"] as const) {
        for (const path of ["/dav/", "/dav/principals/", BOOK]) {
          const ref = await propfind(request, path, "0", wholeBody("d", kind));
          const alt = await propfind(request, path, "0", wholeBody(style, kind));
          expect207(alt);
          expect(stable(alt.body), `${kind} ${path} ${style}`).toEqual(stable(ref.body));
          const props = shape(alt.body)[path]["HTTP/1.1 200 OK"] ?? {};
          expect(Object.keys(props), `${kind} ${path} ${style}`).toContain("resourcetype");
          if (kind === "propname") expect(props["resourcetype"]).toBe("");
        }
      }
    });
  }

  // ── Malformed bodies ───────────────────────────────────────────────────

  test("P7: malformed XML and non-UTF-8 bodies are 400", async ({ request }) => {
    for (const path of ["/dav/", "/dav/principals/", "/dav/addressbooks/", BOOK, contactHref]) {
      const bad = await propfind(request, path, "0", `<d:propfind xmlns:d="DAV:"><d:prop><d:getetag></d:prop>`);
      expect(bad.status, `malformed ${path}`).toBe(400);
    }
    const latin1 = Buffer.concat([
      Buffer.from(`<?xml version="1.0" encoding="UTF-8"?><d:propfind xmlns:d="DAV:"><d:prop><d:displayname>`),
      Buffer.from([0xff, 0xfe, 0xe9]),
      Buffer.from(`</d:displayname></d:prop></d:propfind>`),
    ]);
    const auth = "Basic " + Buffer.from(`${USERS.admin.email}:${USERS.admin.password}`).toString("base64");
    const res = await request.fetch(BOOK, {
      method: "PROPFIND",
      headers: { Authorization: auth, Depth: "0", "Content-Type": "application/xml; charset=utf-8" },
      data: latin1,
      failOnStatusCode: false,
    });
    expect(res.status()).toBe(400);
    const pp = await dav(request, "PROPPATCH", BOOK, { body: "<d:propertyupdate xmlns:d=" });
    expect(pp.status).toBe(400);
    // a body over max-resource-size is 413, never a 500.
    const big = `<d:propfind xmlns:d="DAV:"><!--${"x".repeat(1_100_000)}--><d:allprop/></d:propfind>`;
    expect((await propfind(request, "/dav/", "0", big)).status).toBe(413);
  });

  // ── Address object ─────────────────────────────────────────────────────

  test("P8: PROPFIND on a contact returns its own href and the GET ETag", async ({ request }) => {
    const res = await propfind(request, contactHref, "0", propfindBody("d", [{ ns: "DAV:", name: "getetag" }]));
    expect207(res);
    expect(hrefs(res.body)).toEqual([contactHref]);
    const get = await dav(request, "GET", contactHref);
    expect(get.status).toBe(200);
    expect(propText(responseFor(res.body, contactHref)!, "getetag")).toBe(get.headers["etag"]);
  });

  test("P9: unknown resources are 404", async ({ request }) => {
    for (const path of [`${BOOK}no-such-${runPrefix()}.vcf`, "/dav/addressbooks/nope/"]) {
      const res = await propfind(request, path, "0", propfindBody("d", [{ ns: "DAV:", name: "getetag" }]));
      expect(res.status, path).toBe(404);
    }
  });

  test("P10: PROPPATCH displayname is refused with a 403 propstat", async ({ request }) => {
    const res = await dav(request, "PROPPATCH", BOOK, {
      body:
        `<?xml version="1.0" encoding="UTF-8"?><d:propertyupdate xmlns:d="DAV:">` +
        `<d:set><d:prop><d:displayname>Renamed</d:displayname></d:prop></d:set></d:propertyupdate>`,
    });
    expect207(res);
    const s = shape(res.body);
    expect(Object.keys(s)).toEqual([BOOK]);
    expect(Object.keys(s[BOOK]["HTTP/1.1 403 Forbidden"] ?? {})).toEqual(["displayname"]);
    const after = await propfind(request, BOOK, "0", propfindBody("d", [{ ns: "DAV:", name: "displayname" }]));
    expect(okProps(after, BOOK)["displayname"]).toBe("Kith Contacts");
  });
});
