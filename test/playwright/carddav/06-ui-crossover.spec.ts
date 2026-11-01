import { wireUid } from "../helpers/dav";
import { test, expect, type APIRequestContext, type Page, type Locator } from "@playwright/test";
import { randomUUID } from "node:crypto";
import { dav, discoverHref, USERS, hrefs, responseFor, propText, vcard, runPrefix, assertWellFormedXml } from "../helpers/dav";
import { loginUser } from "../helpers/auth";
import { createContact, goToContact } from "../helpers/contacts";

// UI <-> DAV crossover. Every write is made in a real browser (or over
// DAV and then checked in the browser); every case starts from a fresh sync
// token, ctag and ETag and checks what a CardDAV client would see.

test.describe.configure({ mode: "serial" });

const BOOK = "/dav/addressbooks/default/";
const NS = `xmlns:d="DAV:" xmlns:card="urn:ietf:params:xml:ns:carddav" xmlns:cs="http://calendarserver.org/ns/"`;
const VCARD_HEADERS = { "Content-Type": "text/vcard; charset=utf-8" };
const P = `${runPrefix()}-ui`;
const unfold = (s: string) => s.replace(/\r\n[ \t]/g, "");
const storedHrefs = new Map<number, string>();
async function defaultHref(request: APIRequestContext, id: number): Promise<string> {
  if (storedHrefs.has(id)) return storedHrefs.get(id)!;
  const auth = await request.post("/api/auth/token", { data: USERS.admin });
  expect(auth.status()).toBe(201);
  const token = (await auth.json()).token;
  const contact = await request.get(`/api/contacts/${id}`, { headers: { Authorization: `Bearer ${token}` } });
  expect(contact.status()).toBe(200);
  const href = await discoverHref(request, (await contact.json()).data.first_name);
  await request.delete("/api/auth/token", { headers: { Authorization: `Bearer ${token}` } });
  storedHrefs.set(id, href);
  return href;
}

// ── DAV helpers ──────────────────────────────────────────────────────────

interface BookState {
  token: string;
  ctag: string;
}

async function bookState(request: APIRequestContext): Promise<BookState> {
  const res = await dav(request, "PROPFIND", BOOK, {
    headers: { Depth: "0" },
    body: `<?xml version="1.0" encoding="UTF-8"?><d:propfind ${NS}><d:prop><d:sync-token/><cs:getctag/></d:prop></d:propfind>`,
  });
  expect(res.status).toBe(207);
  const token = propText(res.body, "sync-token");
  const ctag = propText(res.body, "getctag");
  expect(token, res.body).toBeTruthy();
  expect(ctag, res.body).toBeTruthy();
  return { token: token!, ctag: ctag! };
}

async function depth1(request: APIRequestContext): Promise<string[]> {
  const res = await dav(request, "PROPFIND", BOOK, {
    headers: { Depth: "1" },
    body: `<?xml version="1.0" encoding="UTF-8"?><d:propfind ${NS}><d:prop><d:getetag/></d:prop></d:propfind>`,
  });
  expect(res.status).toBe(207);
  assertWellFormedXml(res.body);
  return hrefs(res.body);
}

/** Incremental sync from `token`; returns the response block for `href` (or undefined). */
async function syncFrom(request: APIRequestContext, token: string, href: string) {
  const res = await dav(request, "REPORT", BOOK, {
    headers: { Depth: "1" },
    body:
      `<?xml version="1.0" encoding="UTF-8"?><d:sync-collection ${NS}><d:sync-token>${token}</d:sync-token>` +
      `<d:sync-level>1</d:sync-level><d:prop><d:getetag/><card:address-data/></d:prop></d:sync-collection>`,
  });
  expect(res.status, res.body.slice(0, 400)).toBe(207);
  assertWellFormedXml(res.body);
  return responseFor(res.body, href);
}

async function expectSyncChanged(request: APIRequestContext, token: string, href: string, etag?: string) {
  const block = await syncFrom(request, token, href);
  expect(block, `sync from ${token} must report ${href}`).toBeDefined();
  expect(block!).not.toContain("404 Not Found");
  if (etag) expect(propText(block!, "getetag")).toBe(etag);
}

async function expectSyncRemoved(request: APIRequestContext, token: string, href: string) {
  const block = await syncFrom(request, token, href);
  expect(block, `sync from ${token} must report ${href} as removed`).toBeDefined();
  expect(block!).toContain("404 Not Found");
}

async function getCard(request: APIRequestContext, href: string, accept?: string) {
  const res = await dav(request, "GET", href, accept ? { headers: { Accept: accept } } : {});
  return { status: res.status, etag: res.headers["etag"], body: unfold(res.body) };
}

async function getOk(request: APIRequestContext, href: string) {
  const card = await getCard(request, href);
  expect(card.status, card.body.slice(0, 300)).toBe(200);
  expect(card.etag).toBeTruthy();
  return card;
}

/**
 * Runs `step` and asserts the DAV-visible consequences of a write: a new ETag,
 * a new ctag, and an incremental sync from the previous token that reports the
 * contact with its new ETag. Returns the card as served afterwards.
 */
async function expectWriteVisible(request: APIRequestContext, href: string, step: () => Promise<void>) {
  const before = await getOk(request, href);
  const state = await bookState(request);
  await step();
  const after = await getOk(request, href);
  expect(after.etag, "ETag must change").not.toBe(before.etag);
  expect((await bookState(request)).ctag, "ctag must change").not.toBe(state.ctag);
  await expectSyncChanged(request, state.token, href, after.etag);
  return after;
}

async function put(request: APIRequestContext, href: string, body: string, headers: Record<string, string> = {}) {
  const res = await dav(request, "PUT", href, { headers: { ...VCARD_HEADERS, ...headers }, body });
  expect([201, 204], res.body.slice(0, 300)).toContain(res.status);
  return res;
}

const lines = (body: string, name: string) =>
  body.split("\r\n").filter((l) => new RegExp(`^(?:[\\w-]+\\.)?${name}[;:]`, "i").test(l));

// ── UI helpers ───────────────────────────────────────────────────────────

let page: Page;

test.beforeAll(async ({ browser }) => {
  page = await browser.newPage();
  page.on("dialog", (d) => d.accept());
  await loginUser(page, USERS.admin.email, USERS.admin.password);
});

test.afterAll(async () => {
  await page.close();
});

async function settle() {
  await page.waitForLoadState("networkidle");
}

/** A visible live component on the contact page, found by its heading text. */
function section(heading: RegExp): Locator {
  return page
    .locator("[data-phx-component]")
    .filter({ visible: true })
    .filter({ has: page.locator("span, h3", { hasText: heading }) })
    .last();
}

async function idByName(name: string): Promise<number> {
  await page.goto("/contacts");
  await settle();
  await page.locator('input[name="search"]').filter({ visible: true }).first().fill(name);
  const link = page.locator('a[href^="/contacts/"]').filter({ hasText: name }).first();
  await link.waitFor({ state: "visible", timeout: 10_000 });
  const m = (await link.getAttribute("href"))!.match(/\/contacts\/(\d+)/);
  expect(m, "contact link").toBeTruthy();
  return parseInt(m![1], 10);
}

async function addContactField(contactId: number, typeName: RegExp, value: string) {
  await goToContact(page, contactId);
  const box = section(/^Contact$/);
  await box.getByRole("button", { name: "+ Add" }).click();
  const select = box.locator('select[name="contact_field[contact_field_type_id]"]');
  const option = select.locator("option").filter({ hasText: typeName }).first();
  await select.selectOption((await option.getAttribute("value"))!);
  await box.locator('input[name="contact_field[value]"]').fill(value);
  await box.getByRole("button", { name: "Save", exact: true }).click();
  await expect(box.getByText(value, { exact: false }).first()).toBeVisible();
}

async function deleteContactField(contactId: number, value: string) {
  await goToContact(page, contactId);
  const box = section(/^Contact$/);
  const row = box.locator("div.group").filter({ hasText: value }).first();
  await row.hover();
  await row.getByRole("button", { name: "Del" }).click();
  await expect(box.locator("div.group").filter({ hasText: value })).toHaveCount(0);
}

async function addAddress(contactId: number, a: { line1: string; city: string; postal: string; country: string }) {
  await goToContact(page, contactId);
  const box = section(/^Addresses$/);
  await box.locator(`#add-address-${contactId}`).click();
  await box.locator('input[name="address[line1]"]').fill(a.line1);
  await box.locator('input[name="address[city]"]').fill(a.city);
  await box.locator('input[name="address[postal_code]"]').fill(a.postal);
  await box.locator('[name="address[country]"]').fill(a.country);
  await box.getByRole("button", { name: "Save", exact: true }).click();
  await expect(box.getByText(a.line1).first()).toBeVisible();
}

async function addTag(contactId: number, tagName: string) {
  await goToContact(page, contactId);
  await page.locator('button[phx-click="toggle-tag-dropdown"]').filter({ visible: true }).first().click();
  await page.locator('input[name="tag_search"]').filter({ visible: true }).first().pressSequentially(tagName);
  await page.locator('button[phx-click="add-tag"]').filter({ hasText: tagName }).filter({ visible: true }).first().click();
  await expect(page.locator('button[phx-click="toggle-tag-dropdown"]').filter({ visible: true }).first()).toBeVisible();
  await expect(page.locator('button[phx-click="add-tag"]').filter({ visible: true })).toHaveCount(0);
}

async function editContact(contactId: number, fill: Record<string, string>) {
  await page.goto(`/contacts/${contactId}/edit`);
  await settle();
  for (const [name, value] of Object.entries(fill)) {
    await page.locator(`[name="contact[${name}]"]`).fill(value);
  }
  await page.getByRole("button", { name: /save changes/i }).click();
  await page.waitForURL(new RegExp(`/contacts/${contactId}$`), { timeout: 10_000 });
  await settle();
}

async function contactMenuAction(contactId: number, event: "archive" | "unarchive" | "delete") {
  await goToContact(page, contactId);
  await page.locator("button:has(.hero-ellipsis-horizontal)").filter({ visible: true }).first().click();
  await page.locator(`button[phx-click="${event}"]:not([phx-target])`).filter({ visible: true }).first().click();
  const flash = { archive: /archived\./, unarchive: /unarchived\./, delete: /moved to trash/ }[event];
  await expect(page.getByText(flash).first()).toBeVisible();
  await settle();
}

async function restoreFromTrash(name: string) {
  await page.goto("/contacts/trash");
  await settle();
  const row = page.locator("tr").filter({ hasText: name });
  await row.getByRole("button", { name: /restore/i }).click();
  await expect(page.getByText(/has been restored/i)).toBeVisible();
}

// ── Cases ────────────────────────────────────────────────────────────────

// Shared across U1–U3 and U5: one contact created in the UI.
let uiId = 0;
const uiFirst = `${P}-u1`;
const uiLast = "Crossover";

test("U1: a contact created in the UI appears in Depth 1, incremental sync and GET", async ({ request }) => {
  const state = await bookState(request);
  uiId = await createContact(page, { firstName: uiFirst, lastName: uiLast });
  const href = await defaultHref(request, uiId);

  expect(await depth1(request)).toContain(href);
  const card = await getOk(request, href);
  expect(card.body).toContain(`FN:${uiFirst} ${uiLast}\r\n`);
  expect(card.body).toContain(`N:${uiLast};${uiFirst};`);
  await expectSyncChanged(request, state.token, href, card.etag);
  expect((await bookState(request)).ctag).not.toBe(state.ctag);
});

test("U2: editing the name, then the birthday, in the UI changes ETag, ctag and sync", async ({ request }) => {
  const href = await defaultHref(request, uiId);

  let card = await expectWriteVisible(request, href, () => editContact(uiId, { first_name: `${uiFirst}-renamed` }));
  expect(card.body).toContain(`FN:${uiFirst}-renamed ${uiLast}\r\n`);

  card = await expectWriteVisible(request, href, () => editContact(uiId, { birthdate: "1984-07-09" }));
  expect(card.body).toContain("BDAY:1984-07-09\r\n");
  const v4 = await getCard(request, href, "text/vcard; version=4.0");
  expect(v4.body).toContain("BDAY:19840709\r\n");
});

test("U3: adding a phone, email, address and tag in the UI, then deleting one, is visible to DAV", async ({ request }) => {
  const href = await defaultHref(request, uiId);
  const phone = "+15550107777";
  const email = `${P}-u3@example.test`;
  const tagName = `${P}-u3tag`;

  // A tag must exist before the UI can attach it: a DAV PUT with CATEGORIES makes one.
  await put(request, `${BOOK}${P}-u3-tagseed.vcf`, vcard({ fn: `${P}-u3 tag seed`, extra: [`CATEGORIES:${tagName}`] }), {
    "If-None-Match": "*",
  });

  let card = await expectWriteVisible(request, href, () => addContactField(uiId, /phone/i, phone));
  expect(lines(card.body, "TEL").join("\n")).toContain(phone);

  card = await expectWriteVisible(request, href, () => addContactField(uiId, /email/i, email));
  expect(lines(card.body, "EMAIL").join("\n")).toContain(email);

  card = await expectWriteVisible(request, href, () =>
    addAddress(uiId, { line1: "12 Crossover Lane", city: "Springfield", postal: "12345", country: "US" }),
  );
  expect(lines(card.body, "ADR").join("\n")).toContain("12 Crossover Lane");

  card = await expectWriteVisible(request, href, () => addTag(uiId, tagName));
  expect(lines(card.body, "CATEGORIES").join("\n")).toContain(tagName);

  card = await expectWriteVisible(request, href, () => deleteContactField(uiId, phone));
  expect(lines(card.body, "TEL")).toHaveLength(0);
  expect(lines(card.body, "EMAIL").join("\n")).toContain(email);
});

test("U3b: renaming a tag in Settings changes the ETag and sync of the cards that carry it", async ({ request }) => {
  const href = await defaultHref(request, uiId);
  const oldName = `${P}-u3tag`;
  const newName = `${P}-u3tag-renamed`;

  const card = await expectWriteVisible(request, href, async () => {
    await page.goto("/settings/tags");
    await settle();
    const row = page.locator("div.flex.items-center.justify-between").filter({ hasText: oldName }).last();
    await row.locator('button[phx-click="edit"]').click();
    await page.locator('input[name="tag[name]"]').fill(newName);
    await page.getByRole("button", { name: "Update" }).click();
    await expect(page.locator("span.badge", { hasText: newName })).toBeVisible();
  });
  expect(lines(card.body, "CATEGORIES").join("\n")).toContain(newName);
  expect(card.body).not.toMatch(new RegExp(`${oldName}(?!-renamed)`));
});

test("U3c: renaming a relationship's target in the UI changes the owner's card, ETag and sync", async ({ request }) => {
  const ownerUid = randomUUID();
  const targetUid = randomUUID();
  const ownerHref = `${BOOK}${ownerUid}.vcf`;
  const targetHref = `${BOOK}${targetUid}.vcf`;
  const target = `${P}-u3c target`;
  await put(request, targetHref, vcard({ fn: target, uid: targetUid }), { "If-None-Match": "*" });
  await put(
    request,
    ownerHref,
    vcard({ fn: `${P}-u3c owner`, uid: ownerUid, version: "4.0", extra: [`RELATED;TYPE=friend:urn:uuid:${targetUid}`] }),
    { "If-None-Match": "*" },
  );
  expect((await getOk(request, ownerHref)).body).toContain(`X-ABRELATEDNAMES:${target}`);
  const targetId = await idByName(target);

  const card = await expectWriteVisible(request, ownerHref, () =>
    editContact(targetId, { first_name: `${P}-u3c renamed`, last_name: "Target" }),
  );
  expect(card.body).toContain(`X-ABRELATEDNAMES:${P}-u3c renamed Target`);
});

test("U3d: children of a DAV-decorated card deleted in the UI stay deleted (via the UI)", async ({ request }) => {
  const uid = randomUUID();
  const href = `${BOOK}${uid}.vcf`;
  const name = `${P}-u3d`;
  const tag = `${P}-u3d-tag`;
  await put(
    request,
    href,
    vcard({
      fn: `${name} Apple`,
      uid,
      extra: [
        "item1.TEL;type=CELL;type=pref:+15550103333",
        "item1.X-ABLabel:_$!<Mobile>!$_",
        `item2.EMAIL;type=INTERNET:${name}@example.test`,
        "item2.X-ABLabel:_$!<Home>!$_",
        `CATEGORIES:${tag}`,
      ],
    }),
    { "If-None-Match": "*" },
  );
  const id = await idByName(`${name} Apple`);

  await expectWriteVisible(request, href, () => deleteContactField(id, "3333"));
  const card = await expectWriteVisible(request, href, async () => {
    await goToContact(page, id);
    await page.locator('button[phx-click="remove-tag"]').filter({ visible: true }).first().click();
    await expect(page.locator('button[phx-click="remove-tag"]').filter({ visible: true })).toHaveCount(0);
  });
  expect(lines(card.body, "TEL"), card.body).toHaveLength(0);
  expect(lines(card.body, "CATEGORIES"), card.body).toHaveLength(0);
  expect(card.body).not.toContain("_$!<Mobile>!$_");
  expect(lines(card.body, "EMAIL").join("\n")).toContain(`${name}@example.test`);
  expect(card.body).toContain("_$!<Home>!$_");

  // An identical PUT-back of what the client now sees resurrects nothing.
  await put(request, href, card.body, { "If-Match": card.etag! });
  const again = await getOk(request, href);
  expect(lines(again.body, "TEL")).toHaveLength(0);
  expect(lines(again.body, "CATEGORIES")).toHaveLength(0);
  await goToContact(page, id);
  await expect(section(/^Contact$/).getByText("3333")).toHaveCount(0);
});

test("U4: DAV shared edits appear in UI while client NOTE stays separate from private description", async ({ request }) => {
  const href = await defaultHref(request, uiId);
  const beforePrivate = await getOk(request, href);
  const privateState = await bookState(request);
  await goToContact(page, uiId);
  const about = section(/^About$/);
  await about.getByRole("button", { name: "Edit", exact: true }).click();
  await about.locator('textarea[name="contact[description]"]').fill(`${P}-u4 private description`);
  await about.getByRole("button", { name: "Save", exact: true }).click();
  await expect(about.getByText(`${P}-u4 private description`, { exact: true })).toBeVisible();
  const before = await getOk(request, href);
  expect(before.body).toBe(beforePrivate.body);
  expect(before.etag).toBe(beforePrivate.etag);
  expect(await syncFrom(request, privateState.token, href)).toBeUndefined();
  const body = before.body
    .replace(/^FN:.*$/m, `FN:${P}-u4 Edited`)
    .replace(/^N:.*$/m, `N:Edited;${P}-u4;;;`)
    .replace(/^NOTE:.*\r\n/m, "")
    .replace("END:VCARD", `NOTE:${P}-u4 note from DAV\r\nTEL;TYPE=CELL:+15550104444\r\nEND:VCARD`);
  await put(request, href, body, { "If-Match": before.etag! });

  await goToContact(page, uiId);
  await page.reload();
  await settle();
  await expect(page.getByRole("heading", { name: new RegExp(`${P}-u4 Edited`) }).first()).toBeVisible();
  await expect(section(/^Contact$/).getByText(/555.*010.*4444|5550104444/).first()).toBeVisible();
  await expect(page.getByText(`${P}-u4 note from DAV`, { exact: true })).toHaveCount(0);
  await expect(page.getByText(`${P}-u4 private description`, { exact: true })).toBeVisible();
  expect((await getOk(request, href)).body).toContain(`NOTE:${P}-u4 note from DAV`);
});

test("U5: trash in the UI hides the contact from DAV; restore brings it back at the same href", async ({ request }) => {
  const href = await defaultHref(request, uiId);
  const name = `${P}-u4 Edited`;
  let state = await bookState(request);

  await contactMenuAction(uiId, "delete");
  expect((await getCard(request, href)).status).toBe(404);
  expect(await depth1(request)).not.toContain(href);
  await expectSyncRemoved(request, state.token, href);

  state = await bookState(request);
  await restoreFromTrash(name);
  const card = await getOk(request, href);
  expect(card.body).toContain(`FN:${name}`);
  expect(await depth1(request)).toContain(href);
  await expectSyncChanged(request, state.token, href, card.etag);
});

test("U6: merging A into B in the UI removes A's href and gives B the merged fields", async ({ request }) => {
  const uuidA = randomUUID().toUpperCase();
  const uuidB = randomUUID().toUpperCase();
  const hrefA = `${BOOK}${uuidA}.vcf`;
  const hrefB = `${BOOK}${uuidB}.vcf`;
  const nameA = `${P}-u6a Merge`;
  const nameB = `${P}-u6b Merge`;

  // Grouped phone/email values become native fields; their Apple groups and labels are dropped.
  await put(
    request,
    hrefA,
    vcard({
      fn: nameA,
      uid: uuidA,
      extra: ["item1.TEL;type=CELL:+15550106001", "item1.X-ABLabel:_$!<Mobile>!$_", `NOTE:${P} note A`],
    }),
    { "If-None-Match": "*" },
  );
  await put(
    request,
    hrefB,
    vcard({
      fn: nameB,
      uid: uuidB,
      extra: [`item1.EMAIL;type=INTERNET:${P}-u6b@example.test`, "item1.X-ABLabel:_$!<Work>!$_", "X-B-ONLY:kept"],
    }),
    { "If-None-Match": "*" },
  );
  const idA = await idByName(nameA);
  const idB = await idByName(nameB);
  const beforeB = await getOk(request, hrefB);
  const state = await bookState(request);

  await page.goto(`/contacts/duplicates/cluster/${idB}?with=${idA}`);
  await settle();
  const makePrimaryB = page.locator(`button[phx-click="set-primary"][phx-value-id="${idB}"]`);
  if (await makePrimaryB.count()) await makePrimaryB.click();
  await page.getByRole("button", { name: /merge 2 contacts/i }).click();
  await page.waitForURL(new RegExp(`/contacts/${idB}$`), { timeout: 15_000 });

  expect((await getCard(request, hrefA)).status).toBe(404);
  expect(await depth1(request)).not.toContain(hrefA);
  await expectSyncRemoved(request, state.token, hrefA);

  const afterB = await getOk(request, hrefB);
  expect(afterB.etag).not.toBe(beforeB.etag);
  await expectSyncChanged(request, state.token, hrefB, afterB.etag);
  expect(afterB.body).toContain(`UID:${wireUid(uuidB)}\r\n`);
  const tels = lines(afterB.body, "TEL");
  const emails = lines(afterB.body, "EMAIL");
  expect(tels, afterB.body).toHaveLength(1);
  expect(tels[0]).toContain("+15550106001");
  expect(emails, afterB.body).toHaveLength(1);
  expect(emails[0]).toContain(`${P}-u6b@example.test`);
  expect(lines(afterB.body, "X-B-ONLY")).toHaveLength(1);
  expect(afterB.body).toContain(`item1.EMAIL;type=INTERNET:${P}-u6b@example.test`);
  expect(afterB.body).toContain("item1.X-ABLabel:_$!<Work>!$_");
  const auth = await request.post("/api/auth/token", { data: USERS.admin });
  expect(auth.status()).toBe(201);
  const token = (await auth.json()).token;
  const nativeFields = await request.get(`/api/contacts/${idB}/contact_fields`, { headers: { Authorization: `Bearer ${token}` } });
  expect(nativeFields.status()).toBe(200);
  const fields = (await nativeFields.json()).data;
  expect(fields.map((f: { value: string }) => f.value).sort()).toEqual(["+15550106001", `${P}-u6b@example.test`].sort());

  // A second sync shows nothing new for B, and a PUT-back of B keeps one of each.
  await put(request, hrefB, afterB.body, { "If-Match": afterB.etag! });
  const again = await getOk(request, hrefB);
  expect(lines(again.body, "TEL")).toHaveLength(1);
  expect(lines(again.body, "EMAIL")).toHaveLength(1);
  const repeated = await request.get(`/api/contacts/${idB}/contact_fields`, { headers: { Authorization: `Bearer ${token}` } });
  expect(repeated.status()).toBe(200);
  expect((await repeated.json()).data).toEqual(fields);
  await request.delete("/api/auth/token", { headers: { Authorization: `Bearer ${token}` } });
});

test("U7: archive in the UI is a removal for DAV; unarchive is an addition", async ({ request }) => {
  const name = `${P}-u7`;
  const id = await createContact(page, { firstName: name, lastName: "Archive" });
  const href = await defaultHref(request, id);
  await getOk(request, href);

  let state = await bookState(request);
  await contactMenuAction(id, "archive");
  await expect(page.getByText("Archived").first()).toBeVisible();
  expect((await getCard(request, href)).status).toBe(404);
  expect(await depth1(request)).not.toContain(href);
  await expectSyncRemoved(request, state.token, href);
  expect((await bookState(request)).ctag).not.toBe(state.ctag);

  state = await bookState(request);
  await contactMenuAction(id, "unarchive");
  const card = await getOk(request, href);
  expect(await depth1(request)).toContain(href);
  await expectSyncChanged(request, state.token, href, card.etag);
});

test("U8: DELETE over DAV puts the contact in the UI Trash; a UI restore brings it back", async ({ request }) => {
  const uuid = randomUUID().toUpperCase();
  const href = `${BOOK}${uuid}.vcf`;
  const name = `${P}-u8 Deleted`;
  await put(request, href, vcard({ fn: name, uid: uuid }), { "If-None-Match": "*" });
  const { etag } = await getOk(request, href);

  const del = await dav(request, "DELETE", href, { headers: { "If-Match": etag! } });
  expect(del.status).toBe(204);
  expect((await getCard(request, href)).status).toBe(404);

  const state = await bookState(request);
  await page.goto("/contacts/trash");
  await settle();
  await expect(page.locator("tr").filter({ hasText: name })).toHaveCount(1);
  await restoreFromTrash(name);

  const card = await getOk(request, href);
  expect(card.body).toContain(`UID:${wireUid(uuid)}\r\n`);
  expect(card.body).toContain(`FN:${name}\r\n`);
  await expectSyncChanged(request, state.token, href, card.etag);
});

test("U9: a contact PUT to <uuid>.vcf and edited in the UI is served at that href", async ({ request }) => {
  const uuid = randomUUID();
  const href = `${BOOK}${uuid}.vcf`;
  const name = `${P}-u9`;
  await put(request, href, vcard({ fn: `${name} Original`, uid: uuid, tel: "+15550109999" }), { "If-None-Match": "*" });
  const id = await idByName(`${name} Original`);

  let card = await expectWriteVisible(request, href, () => editContact(id, { first_name: name, last_name: "UiEdited" }));
  expect(card.body).toContain(`FN:${name} UiEdited\r\n`);
  expect(card.body).toContain(`UID:${wireUid(uuid)}\r\n`);

  card = await expectWriteVisible(request, href, () => addContactField(id, /email/i, `${P}-u9@example.test`));
  expect(lines(card.body, "EMAIL").join("\n")).toContain(`${P}-u9@example.test`);
  expect(await defaultHref(request, id)).toBe(href);
  expect(await depth1(request)).toContain(href);
});

test("family-only contacts can be created and edited in the browser while nameless edits are rejected", async ({ request }) => {
  const family = `${P}-family-only`;
  const href = `${BOOK}${randomUUID()}.vcf`;
  const body = `BEGIN:VCARD\r\nVERSION:3.0\r\nFN:${family}\r\nN:${family};;;;\r\nEND:VCARD\r\n`;
  await put(request, href, body);
  const id = await idByName(family);

  await editContact(id, { occupation: "Family-only browser edit" });
  let card = await getOk(request, href);
  expect(card.body).toContain(`FN:${family}\r\n`);
  expect(card.body).toContain(`N:${family};;;;\r\n`);
  expect(card.body).toContain("TITLE:Family-only browser edit\r\n");

  await page.goto(`/contacts/${id}/edit`);
  await settle();
  await page.locator('[name="contact[last_name]"]').fill("");
  await page.getByRole("button", { name: /save changes/i }).click();
  await expect(page.locator("#contact-form").getByText(/can't be blank/)).toBeVisible();
  await expect(page).toHaveURL(new RegExp(`/contacts/${id}/edit$`));
  expect((await getOk(request, href)).body).toContain(`FN:${family}\r\n`);

  const createdFamily = `${P}-family-created`;
  const createdId = await createContact(page, { firstName: "", lastName: createdFamily });
  const createdHref = await discoverHref(request, createdFamily);
  await editContact(createdId, { occupation: "Created without a given name" });
  card = await getOk(request, createdHref);
  expect(card.body).toContain(`FN:${createdFamily}\r\n`);
  expect(card.body).toContain(`N:${createdFamily};;;;\r\n`);

  const auth = await request.post("/api/auth/token", { data: USERS.admin });
  expect(auth.status()).toBe(201);
  const token = (await auth.json()).token;
  for (const [contactId, last] of [[id, family], [createdId, createdFamily]] as const) {
    const response = await request.get(`/api/contacts/${contactId}`, { headers: { Authorization: `Bearer ${token}` } });
    expect(response.status()).toBe(200);
    expect((await response.json()).data).toMatchObject({ first_name: "", last_name: last, display_name: last });
  }
  await request.delete("/api/auth/token", { headers: { Authorization: `Bearer ${token}` } });
  expect((await dav(request, "DELETE", href)).status).toBe(204);
  expect((await dav(request, "DELETE", createdHref)).status).toBe(204);
});
