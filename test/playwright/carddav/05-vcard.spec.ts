import { test, expect, type APIRequestContext } from "@playwright/test";
import { readFileSync } from "node:fs";
import { dav, propText, responseFor, runPrefix, assertWellFormedXml, USERS, vcard } from "../helpers/dav";
import { loginUser } from "../helpers/auth";

test.describe.configure({ mode: "serial" });
const BOOK = "/dav/addressbooks/default/";
const prefix = runPrefix();
const headers = { "Content-Type": "text/vcard; charset=utf-8" };
const unfold = (s: string) => s.replace(/\r\n[ \t]/g, "");
const withoutRev = (s: string) => s.replace(/^REV:.*\r\n/gm, "");
const created: string[] = [];
let bearer = "";
const fixtureUids: Record<string, string> = { "v30-full": `${prefix}-v30`, "v40-full": `${prefix}-v40`, "apple-ios": `${prefix}-apple`, "davx5-android": `${prefix}-davx5`, "thunderbird": `${prefix}-thunderbird`, "unicode-folding": `${prefix}-unicode` };
const fullCommon = ["NICKNAME:Enchantress", "ORG:Analytical Engines", "TITLE:Mathematician", "ada@home.example.test", "ada@work.example.test", "+15550001111", "+15550002222", "https://ada.example.test/home", "https://ada.example.test/work", "xmpp:ada@example.test", "CATEGORIES:Computing,Friends\\, close", "ADR;TYPE=HOME:;Suite 2;12 Engine St;London;Greater London;N1;UK", "ADR;TYPE=WORK:;Floor 3;20 Office St;Oxford;Oxon;OX1;UK", "X-CUSTOM:Keep me"];
const fixtures: Record<string, string[]> = {
  "v30-full": [...fullCommon, "LABEL;TYPE=HOME:PO 42\\nLondon", "AGENT:BEGIN:VCARD\\nFN:Agent Smith\\nEND:VCARD", "KEY;ENCODING=b;TYPE=PGP:AAEC", "X-CHARSET;CHARSET=utf-8:Charset value"],
  "v40-full": [...fullCommon, "KEY:data:application/pgp-keys;base64,AAEC", "pid@example.test", "KIND:individual", "ANNIVERSARY:20100601"],
  "apple-ios": [`FN:${prefix} Alice Apple`, "alice@icloud.example.test", "+15550003333", `X-ABUID:${prefix}-apple-abuid`, `https://twitter.com/${prefix}-alice`],
  "davx5-android": [`FN:${prefix} Amira Android`, "amira@example.test", "+15550004444", "IMPP:sip:amira@example.test", "X-PHONETIC-FIRST-NAME:Amira"],
  "thunderbird": [`FN:${prefix} Theo Thunderbird`, "theo@example.test", "URL:https://theo.example.test", "X-MOZILLA-HTML:TRUE"],
  "unicode-folding": [`FN:${prefix} 小明😀 مرحبا שלום 王`, "NOTE:" + "漢字😀مرحباשלום".repeat(20)],
};
async function put(request: APIRequestContext, href: string, body: string) {
  return dav(request, "PUT", href, { headers, body });
}
function valid(body: string, version: string) {
  expect(body.replace(/\r\n/g, "")).not.toMatch(/[\r\n]/);
  expect(body.startsWith(`BEGIN:VCARD\r\nVERSION:${version}\r\n`)).toBe(true);
  for (const line of body.split("\r\n")) {
    expect(Buffer.byteLength(line), line).toBeLessThanOrEqual(75);
    expect(line).not.toContain("\uFFFD");
  }
  expect(unfold(body).match(/^FN:/gm)).toHaveLength(1);
  expect(body.endsWith("END:VCARD\r\n")).toBe(true);

}
async function reportCard(request: APIRequestContext, href: string, sync = false) {
  const body = sync
    ? `<d:sync-collection xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:carddav"><d:sync-token/><d:sync-level>1</d:sync-level><d:prop><d:getetag/><c:address-data/></d:prop></d:sync-collection>`
    : `<c:addressbook-multiget xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:carddav"><d:prop><c:address-data/></d:prop><d:href>${href}</d:href></c:addressbook-multiget>`;
  const res = await dav(request, "REPORT", BOOK, { body });
  expect(res.status, res.body.slice(0, 300)).toBe(207);
  assertWellFormedXml(res.body);
  const block = responseFor(res.body, href);
  expect(block).toBeTruthy();
  // A client sees the CDATA section's content, not its markup.
  return propText(block!, "address-data")!.replace(/^<!\[CDATA\[([\s\S]*)\]\]>$/, "$1").replace(/\]\]\]\]><!\[CDATA\[>/g, "]]>");
}
async function api(request: APIRequestContext, method: string, path: string, data?: unknown, status = 200) {
  const response = await request.fetch(path, { method, headers: { Authorization: `Bearer ${bearer}` }, data });
  expect(response.status(), await response.text()).toBe(status);
  return status === 204 ? undefined : response.json();
}
async function contactId(request: APIRequestContext, first: string) {
  const result = await api(request, "GET", `/api/contacts?q=${encodeURIComponent(first)}`);
  const contact = result.data.find((c: { first_name: string; birthdate_year_unknown: boolean }) => c.first_name === first && (!first.endsWith(" Ada") || c.birthdate_year_unknown));
  expect(contact).toBeTruthy(); return contact.id as number;
}
test.beforeAll(async ({ request }) => {
  const auth = await request.post("/api/auth/token", { data: USERS.admin });
  expect(auth.status()).toBe(201); bearer = (await auth.json()).token;
  const friend = `${BOOK}${prefix}-friend.vcf`;
  expect((await put(request, friend, vcard({ fn: `${prefix} Friend`, uid: `urn:uuid:${prefix}-friend` }))).status).toBe(201);
  created.push(friend);
});
test.afterAll(async ({ request }) => {
  for (const href of created) expect((await dav(request, "DELETE", href)).status).toBe(204);
  if (bearer) await api(request, "DELETE", "/api/auth/token", undefined, 204);
});
for (const [name, values] of Object.entries(fixtures)) {
  test(`V1/V2/V6: ${name} survives both versions and an identical PUT`, async ({ request }) => {
    const href = `${BOOK}${prefix}-${name}.vcf`;
    // Unfold bytes before UTF-8 decoding: unicode fixture deliberately cuts inside code points.
    const bytes = readFileSync(`test/playwright/fixtures/carddav/${name}.vcf`);
    const body = bytes.toString("latin1").replace(/\r\n[ \t]/g, "");
    const input = Buffer.from(body, "latin1").toString("utf8").replaceAll("{{PREFIX}}", prefix);
    // Preserve the malformed UTF-8 folds in the actual wire request for unicode.
    let wire = input;
    if (name === "unicode-folding") {
      const parts: Buffer[] = [];
      for (const line of input.split("\r\n")) {
        let data = Buffer.from(line); let cap = 75;
        while (data.length > cap) { parts.push(data.subarray(0, cap), Buffer.from("\r\n ")); data = data.subarray(cap); cap = 74; }
        parts.push(data, Buffer.from("\r\n"));
      }
      const res = await request.fetch(href, { method: "PUT", headers: { ...headers, Authorization: "Basic " + Buffer.from(`${USERS.admin.email}:${USERS.admin.password}`).toString("base64") }, data: Buffer.concat(parts) });
      expect(res.status()).toBe(201);
    } else expect((await put(request, href, wire)).status).toBe(201);
    created.push(href);
    // The fixture's own version first: its PUT-back cannot lose the other version's
    // syntax before that version is checked.
    const own = /^VERSION:4\.0/m.test(input) ? "4.0" : "3.0";
    for (const version of [own, own === "4.0" ? "3.0" : "4.0"]) {
      const g = await dav(request, "GET", href, { headers: { Accept: `text/vcard; version=${version}` } });
      expect(g.status, g.body).toBe(200); valid(g.body, version);
      const card = unfold(g.body);
      expect(/^UID(?:;[^:]*)?:([^\r]*)/m.exec(card)?.[1]).toBe(fixtureUids[name]);
      for (const value of values) expect(card, `${name} ${version}: ${value}`).toContain(value);
      if (name === "v40-full") {
        expect(card).toContain("\r\nBDAY:--1210\r\n");
        expect(card).not.toMatch(/^BDAY[^\r\n]*:(?:1604|2000)/m);
        expect(card).toContain(version === "4.0" ? "GENDER:F" : "X-GENDER:Female");
        expect(card).toContain(version === "4.0" ? `RELATED;TYPE=friend:urn:uuid:${prefix}-friend` : `.X-ABRELATEDNAMES:${prefix} Friend`);
      }
      if (name.endsWith("-full")) {
        expect(card).toContain(`N:Lovelace;${prefix} Ada;Augusta;;`);
        expect(card).toContain(`FN:${prefix} Ada Augusta Lovelace`);
        expect(card).toContain("NOTE:Line one\\nLine two\\, comma\\; semicolon\\\\literal\\\\n");
        const photo = /(?:base64,|TYPE=PNG:)([A-Za-z0-9+/=]+)/.exec(input)![1];
        expect(card).toContain((version === "4.0" ? "PHOTO:data:image/png;base64," : "PHOTO;ENCODING=b;TYPE=PNG:") + photo);
        expect(card).toContain("preferred@example.test");
      }
      expect((await put(request, href, g.body)).status).toBe(204);
      const next = await dav(request, "GET", href, { headers: { Accept: `text/vcard; version=${version}` } });
      // 3.0 relationship output is grouped Apple data, which is not imported.
      const expected = version === "3.0" ? g.body.replace(/^item\d+\.X-AB(?:RELATEDNAMES|Label):.*\r\n/gm, "") : g.body;
      expect(withoutRev(next.body)).toBe(withoutRev(expected));
    }
  });
}
test("Apple social profile stays one field over three PUT-backs", async ({ request }) => {
  const href = `${BOOK}${prefix}-apple-ios.vcf`;
  const id = await contactId(request, prefix + " Alice");
  const first = await dav(request, "GET", href);
  const count = (await api(request, "GET", `/api/contacts/${id}/contact_fields`)).data.length;
  for (let i = 0; i < 3; i++) {
    expect((await put(request, href, (await dav(request, "GET", href)).body)).status).toBe(204);
    const card = (await dav(request, "GET", href)).body;
    expect(withoutRev(card)).toBe(withoutRev(first.body));
    expect(unfold(card).match(/twitter\.com/g)).toHaveLength(1);
    expect((await api(request, "GET", `/api/contacts/${id}/contact_fields`)).data).toHaveLength(count);
  }
});
test("natively deleted children stay deleted after PUT-back", async ({ request }) => {
  const href = `${BOOK}${prefix}-deleted.vcf`; created.push(href);
  const body = `BEGIN:VCARD\r\nVERSION:4.0\r\nUID:${prefix}-deleted\r\nN:Deleted;${prefix} Dee;;;\r\nFN:${prefix} Dee Deleted\r\nIMPP;TYPE=HOME:xmpp:dee@example.test\r\nRELATED;TYPE=friend:urn:uuid:${prefix}-friend\r\nitem1.TEL;TYPE=CELL:+15550009999\r\nitem1.X-ABLabel:Mobile\r\nEMAIL;TYPE=WORK:keep@example.test\r\nEND:VCARD\r\n`;
  expect((await put(request, href, body)).status).toBe(201);
  const id = await contactId(request, prefix + " Dee");
  for (const field of (await api(request, "GET", `/api/contacts/${id}/contact_fields`)).data)
    if (field.value !== "keep@example.test") await api(request, "DELETE", `/api/contact_fields/${field.id}`, undefined, 204);
  for (const rel of (await api(request, "GET", `/api/contacts/${id}/relationships`)).data)
    await api(request, "DELETE", `/api/relationships/${rel.id}`, undefined, 204);
  for (const version of ["3.0", "4.0"]) {
    const g = await dav(request, "GET", href, { headers: { Accept: `text/vcard; version=${version}` } });
    expect(g.body).not.toMatch(/IMPP|RELATED|item1\./);
    expect((await put(request, href, g.body)).status).toBe(204);
    expect((await api(request, "GET", `/api/contacts/${id}/contact_fields`)).data.map((f: { value: string }) => f.value)).toEqual(["keep@example.test"]);
    expect((await api(request, "GET", `/api/contacts/${id}/relationships`)).data).toEqual([]);
  }
});
test("relationships to archived and trashed targets survive unchanged PUT-backs", async ({ request }) => {
  for (const hidden of ["archived", "trashed"]) {
    const target = `${BOOK}${prefix}-${hidden}-target.vcf`; const href = `${BOOK}${prefix}-${hidden}-owner.vcf`;
    expect((await put(request, target, vcard({ fn: `${prefix} ${hidden} Target`, uid: `urn:uuid:${prefix}-${hidden}-target` }))).status).toBe(201);
    expect((await put(request, href, `BEGIN:VCARD\r\nVERSION:4.0\r\nUID:${prefix}-${hidden}-owner\r\nN:Owner;${prefix} owner-${hidden};;;\r\nFN:${prefix} owner-${hidden} Owner\r\nRELATED;TYPE=friend:urn:uuid:${prefix}-${hidden}-target\r\nEND:VCARD\r\n`)).status).toBe(201);
    created.push(href);
    const id = await contactId(request, `${prefix} owner-${hidden}`);
    const before = (await api(request, "GET", `/api/contacts/${id}/relationships`)).data;
    expect(before).toHaveLength(1);
    const targetId = before[0].related_contact_id;
    if (hidden === "archived") await api(request, "POST", `/api/contacts/${targetId}/archive`);
    else expect((await dav(request, "DELETE", target)).status).toBe(204);
    for (const version of ["3.0", "4.0"]) {
      const g = await dav(request, "GET", href, { headers: { Accept: `text/vcard; version=${version}` } });
      expect((await put(request, href, g.body)).status).toBe(204);
      expect((await api(request, "GET", `/api/contacts/${id}/relationships`)).data.map((r: { id: number }) => r.id)).toEqual(before.map((r: { id: number }) => r.id));
    }
    if (hidden === "archived") {
      await api(request, "DELETE", `/api/contacts/${targetId}/archive`);
      expect((await dav(request, "DELETE", target)).status).toBe(204);
    }
  }
});
test("an embedded AGENT vCard does not truncate the card", async ({ request }) => {
  const href = `${BOOK}${prefix}-agent.vcf`; created.push(href);
  const body = `BEGIN:VCARD\r\nVERSION:3.0\r\nUID:${prefix}-agent\r\nN:Card;${prefix} Agent;;;\r\nFN:${prefix} Agent Card\r\nAGENT:BEGIN:VCARD\\nFN:Agent\\nEND:VCARD\r\nNOTE:after the agent\r\nEMAIL;TYPE=WORK:after@example.test\r\nEND:VCARD\r\n`;
  expect((await put(request, href, body)).status).toBe(201);
  const card = unfold((await dav(request, "GET", href)).body);
  expect(card).toContain("NOTE:after the agent\r\n");
  expect(card).toContain("EMAIL;TYPE=WORK:after@example.test\r\n");
  expect(card).toContain("AGENT:BEGIN:VCARD\\nFN:Agent\\nEND:VCARD\r\n");
});
test("native names serialize without unsupported prefix and suffix", async ({ request }) => {
  const href = `${BOOK}${prefix}-rename.vcf`; created.push(href);
  const body = `BEGIN:VCARD\r\nVERSION:3.0\r\nUID:${prefix}-rename\r\nN:Lovelace;${prefix} Rena;Augusta;Countess;PhD\r\nFN:Countess ${prefix} Rena Augusta Lovelace PhD\r\nEND:VCARD\r\n`;
  expect((await put(request, href, body)).status).toBe(201);
  const id = await contactId(request, prefix + " Rena");
  await api(request, "PATCH", `/api/contacts/${id}`, { contact: { first_name: `${prefix} Grace`, middle_name: "", last_name: "Hopper" } });
  for (const version of ["3.0", "4.0"]) {
    const card = unfold((await dav(request, "GET", href, { headers: { Accept: `text/vcard; version=${version}` } })).body);
    expect(card).toContain(`N:Hopper;${prefix} Grace;;;\r\n`);
    expect(card).toContain(`FN:${prefix} Grace Hopper\r\n`);
  }
});
test("a BOM, trailing blanks on BEGIN/END and lone-CR line endings are accepted", async ({ request }) => {
  const bodies: Record<string, (b: string) => string> = {
    bom: (b) => "\uFEFF" + b,
    blank: (b) => b.replace("BEGIN:VCARD\r\n", "BEGIN:VCARD\t\r\n").replace("END:VCARD\r\n", "END:VCARD \r\n"),
    cr: (b) => b.replace(/\r\n/g, "\r"),
  };
  for (const [name, shape] of Object.entries(bodies)) {
    const href = `${BOOK}${prefix}-delim-${name}.vcf`; created.push(href);
    expect((await put(request, href, shape(vcard({ fn: `${prefix} Delim ${name}`, email: `${name}@example.test` })))).status).toBe(201);
    expect(unfold((await dav(request, "GET", href)).body)).toContain(`${name}@example.test`);
  }
});
test("V3: unicode survives multiget and the web contact page", async ({ request, page }) => {
  const href = `${BOOK}${prefix}-unicode-folding.vcf`;
  const card = await reportCard(request, href);
  expect(unfold(card)).toContain(`${prefix} 小明😀 مرحبا`);
  await loginUser(page, USERS.admin.email);
  await page.goto(`/contacts/${await contactId(request, prefix + " 小明😀 مرحبا")}`);
  await expect(page).toHaveURL(/\/contacts\/\d+/);
  await expect(page.locator("h1")).toContainText("小明😀 مرحبا");
  const photoId = await contactId(request, prefix + " Ada");
  await page.goto(`/contacts/${photoId}`);
  const avatar = page.locator(`#contact-avatar-${photoId} img`);
  await expect(avatar).toBeVisible();
  expect(await avatar.evaluate((image: HTMLImageElement) => image.complete && image.naturalWidth > 0)).toBe(true);
});
test("V4/V5: avatar survives photo-free sync and 4.0 GET PUT-back", async ({ request }) => {
  const href = `${BOOK}${prefix}-v40-full.vcf`;
  const id = await contactId(request, prefix + " Ada");
  const type = await api(request, "POST", "/api/contact_field_types", { contact_field_type: { name: `${prefix} Native secret` } }, 201);
  const custom = await api(request, "POST", `/api/contacts/${id}/contact_fields`, { contact_field: { contact_field_type_id: type.data.id, value: "Native-only value" } }, 201);
  const note = await api(request, "POST", `/api/contacts/${id}/notes`, { note: { body: `${prefix} native note` } }, 201);
  const reminder = await api(request, "POST", `/api/contacts/${id}/reminders`, { reminder: { type: "one_time", title: `${prefix} native reminder`, anchor_date: "2099-12-10" } }, 201);
  await api(request, "PATCH", `/api/contacts/${id}`, { contact: { favorite: true, first_met_where: "Kith-only place" } });
  const relatives = (await api(request, "GET", `/api/contacts/${id}/relationships`)).data;
  expect(relatives).toHaveLength(0);
  const before = unfold((await dav(request, "GET", href)).body);
  const photo = before.match(/^PHOTO.*$/m)![0];
  const multi = unfold(await reportCard(request, href));
  const sync = unfold(await reportCard(request, href, true));
  expect(multi).toContain(photo); expect(sync).toContain(photo);
  for (const body of [sync.replace(/^PHOTO.*\r\n/gm, ""), (await dav(request, "GET", href, { headers: { Accept: "text/vcard; version=4.0" } })).body]) {
    expect((await put(request, href, body)).status).toBe(204);
    const after = unfold((await dav(request, "GET", href)).body);
    expect(after).toContain(photo);
    expect(withoutRev(after)).toBe(withoutRev(before));
    const fields = (await api(request, "GET", `/api/contacts/${id}/contact_fields`)).data;
    expect(fields).toContainEqual(custom.data);
    expect((await api(request, "GET", `/api/notes/${note.data.id}`)).data.body).toContain("native note");
    expect((await api(request, "GET", `/api/reminders/${reminder.data.id}`)).data.title).toContain("native reminder");
    const scalar = (await api(request, "GET", `/api/contacts/${id}`)).data;
    expect(scalar.favorite).toBe(true); expect(scalar.first_met_where).toBe("Kith-only place");
    expect((await api(request, "GET", `/api/contacts/${id}/relationships`)).data).toEqual(relatives);
  }
});
test("reserialized PUT requires a GET for its validator", async ({ request }) => {
  const href = `${BOOK}${prefix}-validator.vcf`; created.push(href);
  const p = await put(request, href, vcard({ fn: `${prefix} Validator` }));
  expect(p.status).toBe(201); expect(p.headers.etag).toBeUndefined();
  expect((await dav(request, "GET", href)).headers.etag).toMatch(/^".+"$/);
});

test("escaped structured values survive", async ({ request }) => {
  const href = `${BOOK}${prefix}-escaped.vcf`; created.push(href);
  const body = `BEGIN:VCARD\r\nVERSION:4.0\r\nUID:${prefix}-escaped\r\nN:Family\\;Last;${prefix} Given\\;First;Middle\\,Name;Dr;Jr\r\nFN:${prefix} Given\\;First Middle\\,Name Family\\;Last\r\nADR;TYPE=HOME:;Suite\\;2;Street\\;3;City\\,Town;Region;Zip;Country\r\nNOTE:literal \\\\n\r\nEND:VCARD\r\n`;
  expect((await put(request, href, body)).status).toBe(201);
  const card = unfold((await dav(request, "GET", href)).body);
  expect(card).toContain(`N:Family\\;Last;${prefix} Given\\;First;Middle\\,Name;;`);
  expect(card).toContain("ADR;TYPE=HOME:;Suite\\;2;Street\\;3;City\\,Town;Region;Zip;Country");
});

test("one strong tag for both versions, listings and conditional requests", async ({ request }) => {
  const href = `${BOOK}${prefix}-variants.vcf`; created.push(href);
  expect((await put(request, href, vcard({ fn: `${prefix} Variants` }))).status).toBe(201);
  const g3 = await dav(request, "GET", href);
  const g4 = await dav(request, "GET", href, { headers: { Accept: "text/vcard; version=4.0" } });
  expect(g4.body).not.toBe(g3.body);
  expect(g4.headers.etag).toBe(g3.headers.etag);
  expect(g4.headers.vary.toLowerCase()).toContain("accept");
  const propfind = await dav(request, "PROPFIND", href, { headers: { Depth: "0" }, body: `<d:propfind xmlns:d="DAV:"><d:prop><d:getetag/></d:prop></d:propfind>` });
  expect(propText(responseFor(propfind.body, href)!, "getetag")).toBe(g4.headers.etag);
  for (const data of ["", `<c:address-data content-type="text/vcard" version="4.0"/>`]) {
    const report = await dav(request, "REPORT", BOOK, { body: `<c:addressbook-multiget xmlns:c="urn:ietf:params:xml:ns:carddav" xmlns:d="DAV:"><d:prop><d:getetag/>${data}</d:prop><d:href>${href}</d:href></c:addressbook-multiget>` });
    expect(report.status).toBe(207); assertWellFormedXml(report.body);
    expect(propText(responseFor(report.body, href)!, "getetag")).toBe(g4.headers.etag);
  }
  for (const version of ["3.0", "4.0"])
    expect((await dav(request, "GET", href, { headers: { Accept: `text/vcard; version=${version}`, "If-None-Match": g3.headers.etag } })).status).toBe(304);
  const write = await dav(request, "PUT", href, { headers: { ...headers, "If-Match": g3.headers.etag }, body: g4.body });
  expect(write.status).toBe(204);
  expect((await dav(request, "PUT", href, { headers: { ...headers, "If-Match": g4.headers.etag }, body: g4.body })).status).toBe(412);
});
test("text UID is escaped and folded without injecting properties", async ({ request }) => {
  const href = `${BOOK}${prefix}-text-uid.vcf`; created.push(href);
  const uid = "客".repeat(40) + `\\;${prefix}\\nFN:Injected`;
  const body = `BEGIN:VCARD\r\nVERSION:4.0\r\nUID;VALUE=text:${uid}\r\nN:UID;${prefix} Text;;;\r\nFN:${prefix} Text UID\r\nEND:VCARD\r\n`;
  expect((await put(request, href, body)).status).toBe(201);
  for (const version of ["3.0", "4.0"]) {
    const g = await dav(request, "GET", href, { headers: { Accept: `text/vcard; version=${version}` } });
    expect(g.status).toBe(200); valid(g.body, version);
    expect(unfold(g.body)).toContain(`${version === "4.0" ? "UID;VALUE=text" : "UID"}:${uid}`);
  }
});

test("unmapped extras retain syntax across versions while mapped parameters and groups are dropped", async ({ request }) => {
  const href = `${BOOK}${prefix}-extras.vcf`; created.push(href);
  const extra = "KEY;ENCODING=b;TYPE=PGP:AAEC";
  expect((await put(request, href, vcard({ fn: `${prefix} Extras`, extra: [extra, "EMAIL;PID=1.1;TYPE=work:extra@example.test", "item9.X-UNMAPPED:discard"] })) ).status).toBe(201);
  for (const version of ["3.0", "4.0"]) {
    const card = unfold((await dav(request, "GET", href, { headers: { Accept: `text/vcard; version=${version}` } })).body);
    expect(card).toContain(extra + "\r\n");
    expect(card).toContain("extra@example.test");
    expect(card).not.toContain("PID=");
    expect(card).not.toContain("X-UNMAPPED");
  }
});
