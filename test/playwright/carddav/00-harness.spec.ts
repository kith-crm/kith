import { test, expect } from "@playwright/test";
import { dav, assertWellFormedXml } from "../helpers/dav";

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
