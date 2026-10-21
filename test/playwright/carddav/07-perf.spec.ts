import { test, expect, type APIRequestContext } from "@playwright/test";
import { dav, hrefs } from "../helpers/dav";

// Account E (dav-perf@carddav.test) is seeded only with PERF=1:
//   source /tmp/kith-carddav-e2e.env && PERF=1 mix run test/playwright/carddav_seed.exs
// 2000 contacts, each with 2 fields, 1 address, 1 tag. Budgets are the median of
// 3 runs after one warm-up request.

test.describe.configure({ mode: "serial" });

const BOOK = "/dav/addressbooks/default/";
const NS = `xmlns:d="DAV:" xmlns:card="urn:ietf:params:xml:ns:carddav"`;
const DATA = "<d:getetag/><card:address-data/>";

async function timed(fn: () => Promise<{ status: number; body: string }>, expectStatus: number) {
  const warm = await fn();
  expect(warm.status, warm.body.slice(0, 300)).toBe(expectStatus);
  const times: number[] = [];
  for (let i = 0; i < 3; i++) {
    const t0 = performance.now();
    const res = await fn();
    times.push(performance.now() - t0);
    expect(res.status).toBe(expectStatus);
  }
  times.sort((a, b) => a - b);
  console.log(`median ${Math.round(times[1])} ms (${times.map(Math.round).join(", ")})`);
  return { median: times[1], last: warm };
}

const asPerf = (request: APIRequestContext, method: string, path: string, headers = {}, body?: string) =>
  dav(request, method, path, { user: "perf", headers, body });

test.describe("PERF account E: request budgets", () => {
  let all: string[] = [];

  test.beforeAll(async ({ request }) => {
    const res = await asPerf(request, "PROPFIND", BOOK, { Depth: "1" },
      `<?xml version="1.0"?><d:propfind ${NS}><d:prop><d:getetag/></d:prop></d:propfind>`);
    all = hrefs(res.body).filter((h) => h.endsWith(".vcf"));
    expect(all.length).toBeGreaterThanOrEqual(2000);
  });

  test("PROPFIND Depth 1 < 1.5 s", async ({ request }) => {
    const body = `<?xml version="1.0"?><d:propfind ${NS}><d:prop><d:getetag/><d:getcontenttype/></d:prop></d:propfind>`;
    const { median } = await timed(() => asPerf(request, "PROPFIND", BOOK, { Depth: "1" }, body), 207);
    expect(median).toBeLessThan(1500);
  });

  test("initial sync-collection < 6 s", async ({ request }) => {
    for (const prop of ["<d:getetag/>", DATA]) {
      const body = `<?xml version="1.0"?><d:sync-collection ${NS}><d:sync-token/><d:sync-level>1</d:sync-level><d:prop>${prop}</d:prop></d:sync-collection>`;
      const { median } = await timed(() => asPerf(request, "REPORT", BOOK, { Depth: "1" }, body), 207);
      expect(median).toBeLessThan(6000);
    }
  });

  test("multiget of 200 hrefs < 2 s", async ({ request }) => {
    const body =
      `<?xml version="1.0"?><card:addressbook-multiget ${NS}><d:prop>${DATA}</d:prop>` +
      all.slice(0, 200).map((h) => `<d:href>${h}</d:href>`).join("") +
      `</card:addressbook-multiget>`;
    const { median } = await timed(() => asPerf(request, "REPORT", BOOK, { Depth: "1" }, body), 207);
    expect(median).toBeLessThan(2000);
  });

  test("addressbook-query matching 1 contact < 1.5 s", async ({ request }) => {
    const body =
      `<?xml version="1.0"?><card:addressbook-query ${NS}><d:prop>${DATA}</d:prop>` +
      `<card:filter><card:prop-filter name="EMAIL"><card:text-match match-type="equals">perf777@example.test</card:text-match></card:prop-filter></card:filter>` +
      `</card:addressbook-query>`;
    const { median, last } = await timed(() => asPerf(request, "REPORT", BOOK, { Depth: "1" }, body), 207);
    expect(hrefs(last.body).filter((h) => h.endsWith(".vcf")).length).toBe(1);
    expect(median).toBeLessThan(1500);
  });

  test("single GET < 200 ms", async ({ request }) => {
    const { median } = await timed(() => asPerf(request, "GET", all[1000]), 200);
    expect(median).toBeLessThan(200);
  });

  test("a card near the 1 MiB cap: PUT and GET each < 5 s (CDV-107/108/109)", async ({ request }) => {
    const name = `${BOOK}cdv-perf-${Date.now()}-cap.vcf`;
    const card =
      ["BEGIN:VCARD", "VERSION:3.0", "FN:Cap Card", "N:Card;Cap;;;"]
        .concat(Array.from({ length: 50000 }, (_, i) => `EMAIL:${i}@x.y`))
        .concat(Array.from({ length: 10000 }, (_, i) => `X-PERF-${i}:v`))
        .concat(["END:VCARD"])
        .join("\r\n") + "\r\n";
    expect(Buffer.byteLength(card)).toBeLessThan(1048576);

    const headers = { "Content-Type": "text/vcard; charset=utf-8" };
    for (const method of ["PUT", "PUT"]) {
      const t0 = performance.now();
      const res = await dav(request, method, name, { user: "perf", headers, body: card });
      const ms = performance.now() - t0;
      console.log(`${method} ${Buffer.byteLength(card)} bytes: ${Math.round(ms)} ms`);
      expect([201, 204], res.body.slice(0, 200)).toContain(res.status);
      expect(ms).toBeLessThan(5000);
    }
    const t1 = performance.now();
    const got = await dav(request, "GET", name, { user: "perf" });
    const ms = performance.now() - t1;
    console.log(`GET: ${Math.round(ms)} ms`);
    expect(got.status).toBe(200);
    expect(ms).toBeLessThan(5000);
    await dav(request, "DELETE", name, { user: "perf" });
  });
});
