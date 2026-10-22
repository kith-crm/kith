import { test, expect } from "@playwright/test";
import { dav, assertWellFormedXml, propText, hrefs, responseFor, decodeXml } from "../helpers/dav";

test.describe("CardDAV harness", () => {
  test("H1: GET /health returns 200", async ({ request }) => {
    const res = await request.get("/health");
    expect(res.status()).toBe(200);
  });

  test("H2: authed PROPFIND /dav/ returns well-formed 207", async ({ request }) => {
    const res = await dav(request, "PROPFIND", "/dav/", {
      headers: { Depth: "0" },
      body: `<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/></d:prop></d:propfind>`,
    });
    expect(res.status).toBe(207);
    assertWellFormedXml(res.body);
  });

  test("H3: unauthenticated PROPFIND /dav/ returns 401", async ({ request }) => {
    const res = await dav(request, "PROPFIND", "/dav/", { user: null, headers: { Depth: "0" } });
    expect(res.status).toBe(401);
  });
});

test.describe("dav.ts helpers (no server)", () => {
  test("HX1: propText never matches across self-closed elements", () => {
    const xml = '<d:getetag /><d:x/></d:r><d:r><d:getetag>"abc"</d:getetag>';
    expect(propText(xml, "getetag")).toBe("");
    expect(propText('<d:a><d:getetag x="1"/></d:a>', "getetag")).toBe("");
    expect(propText("<d:a/>", "getetag")).toBeUndefined();
    expect(propText('<D:getetag>"q"</D:getetag>', "getetag")).toBe('"q"');
  });

  test("HX2: hrefs/responseFor skip self-closed elements", () => {
    const xml =
      "<d:multistatus><d:response><d:href/><d:href>/a</d:href></d:response>" +
      "<d:response><d:href>/b</d:href><d:status>x</d:status></d:response></d:multistatus>";
    expect(hrefs(xml)).toEqual(["", "/a", "/b"]);
    expect(responseFor(xml, "/b")).toContain("<d:status>x</d:status>");
    expect(responseFor(xml, "/zzz")).toBeUndefined();
  });

  test("HX3: decodeXml handles numeric entities", () => {
    expect(decodeXml("A&#13;&#10;B&#x41;&amp;lt;")).toBe("A\r\nBA&lt;");
  });
});
