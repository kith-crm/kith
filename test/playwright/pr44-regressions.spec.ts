import { test, expect, type Page, type APIRequestContext } from "@playwright/test";
import { execFileSync } from "node:child_process";
import path from "node:path";

// This suite needs the explicit local harness, never a production server.
test.skip(process.env.PR44_E2E !== "1", "Run with the local PR44 harness documented in fixtures/pr44/README.md");
test.describe.configure({ mode: "serial" });
test.setTimeout(180_000);

const fixtureURL = process.env.PR44_MONICA_URL ?? "http://127.0.0.1:8094";
const mailpitURL = process.env.MAILPIT_URL ?? "http://127.0.0.1:8025";
const controlScript = path.resolve("test/playwright/fixtures/pr44/control.exs");

type Account = { email: string; token: string; account_id: number; user_id: number; [key: string]: any };

function control(action: string, payload: object = {}): any {
  const output = execFileSync("mix", ["run", "--no-start", "--no-compile", controlScript, action, JSON.stringify(payload)], {
    env: { ...process.env, MIX_ENV: "test", PR44_E2E: "1", PR44_SERVER: "0" },
    encoding: "utf8", timeout: 120_000, maxBuffer: 4 * 1024 * 1024,
  });
  const line = output.split(/\r?\n/).findLast((value) => value.startsWith("PR44_RESULT="));
  if (!line) throw new Error(`Control did not return JSON: ${output}`);
  return JSON.parse(line.slice("PR44_RESULT=".length));
}

async function connected(page: Page) {
  await expect(page.locator("[data-phx-main].phx-connected")).toBeVisible();
}

async function login(page: Page, account: Account) {
  await page.goto("/users/log-in");
  await connected(page);
  await page.getByRole("textbox", { name: /email/i }).fill(account.email);
  await page.locator('input[type="password"]').fill("ValidP@ssword123!");
  await page.getByRole("button", { name: /log in/i }).click();
  await expect(page).toHaveURL(/\/(dashboard|contacts)$/);
}

async function contactAction(page: Page, id: number, action: "delete" | "archive" | "unarchive") {
  await page.goto(`/contacts/${id}`);
  await connected(page);
  await page.locator("button:has(.hero-ellipsis-horizontal)").first().click();
  await page.locator(`button[phx-click='${action}']`).click();
}

async function startImport(page: Page, account: Account) {
  await page.goto("/settings/import");
  await connected(page);
  await page.getByRole("radio", { name: /Monica CRM \(API\)/ }).check();
  await page.getByPlaceholder("https://your-monica-instance.com").fill(fixtureURL);
  await page.getByPlaceholder("https://your-monica-instance.com").blur();
  await page.getByPlaceholder("Your Monica API key").fill("pr44-fixture-token");
  await page.getByPlaceholder("Your Monica API key").blur();
  await page.getByRole("button", { name: "Continue", exact: true }).click();
  await expect(page.getByText("Review import settings")).toBeVisible();
  await page.getByRole("button", { name: "Start import", exact: true }).click();
  await expect(page.getByText(/Import in progress/)).toBeVisible();
  // The CLI and web server are separate BEAM nodes. Assert persisted completion;
  // the CLI's local PubSub broadcast is deliberately not a UI synchronization aid.
  const state = control("drain_import", account);
  expect(state.import_status).toBe("completed");
  return state;
}

async function mailbox(request: APIRequestContext, email: string) {
  const response = await request.get(`${mailpitURL}/api/v1/search`, { params: { query: `to:${email}` } });
  expect(response.ok()).toBeTruthy();
  const result = await response.json();
  return result.messages ?? [];
}

async function api(request: APIRequestContext, account: Account, route: string, method = "GET", data?: object) {
  const response = await request.fetch(route, {
    method, headers: { Authorization: `Bearer ${account.token}` }, data,
  });
  expect(response.ok(), `${method} ${route}: ${await response.text()}`).toBeTruthy();
  return response.status() === 204 ? null : response.json();
}

test.beforeEach(async ({ page }) => {
  page.on("dialog", async (dialog) => { await dialog.accept(); });
});

test("a saved Not duplicates decision survives transitive auto-merge and reruns", async ({ page }) => {
  const account = control("prepare", { scenario: "duplicates" });
  await login(page, account);
  await page.goto(`/contacts/duplicates/cluster/${Math.min(account.a, account.c)}`);
  await connected(page);
  await page.getByRole("button", { name: "Not duplicates", exact: true }).click();
  await expect(page).toHaveURL(/\/contacts\/duplicates$/);
  await expect(page.getByText("Marked as not duplicates")).toBeVisible();

  const state = control("automerge", account);
  expect(state.live_ids).toHaveLength(2);
  expect(state.a_survivor).not.toBe(state.c_survivor);
  expect(state.live_ids).toContain(state.a_survivor);
  expect(state.live_ids).toContain(state.c_survivor);
  expect(state.dismissed).toBeGreaterThan(0);
  expect(state.results[1].merged).toBe(0);
  await page.goto("/contacts");
  await connected(page);
  await expect(page.locator("tbody tr")).toHaveCount(2);
});

test("permanent deletion cleans mappings and re-import restores all ten notes", async ({ page }) => {
  const account = control("prepare", { scenario: "import" });
  await login(page, account);
  const first = await startImport(page, account);
  expect(first.contacts).toHaveLength(1);
  expect(first.notes).toEqual(Array.from({ length: 10 }, (_, n) => `PR44 note ${String(n + 1).padStart(2, "0")}`));
  const firstId = first.contacts[0].id;
  await page.goto(`/contacts/${firstId}`);
  await connected(page);
  await expect(page.getByText("PR44 note 01", { exact: true }).first()).toBeVisible();

  await contactAction(page, firstId, "delete");
  await expect(page).toHaveURL(/\/contacts$/);
  expect(control("import_snapshot", account).mappings).toBe(first.mappings);
  await page.goto("/contacts/trash");
  await connected(page);
  await page.locator(`button[phx-click='permanent-delete'][phx-value-id='${firstId}']`).click();
  await expect(page.getByRole("button", { name: "Delete Forever" })).toHaveCount(0);
  const deleted = control("import_snapshot", account);
  expect(deleted.contacts).toHaveLength(0);
  expect(deleted.notes).toHaveLength(0);
  expect(deleted.messages).toHaveLength(0);
  expect(deleted.mappings).toBe(0);

  const second = await startImport(page, account);
  expect(second.contacts).toHaveLength(1);
  expect(second.contacts[0].id).not.toBe(firstId);
  expect(second.notes).toEqual(first.notes);
  await page.goto(`/contacts/${second.contacts[0].id}`);
  await connected(page);
  await expect(page.getByText("PR44 note 01", { exact: true }).first()).toBeVisible();
  await expect(page.getByText("PR44 note 10", { exact: true }).first()).toBeVisible();
});

test("a disabled reminder discards its queued email without sending mail", async ({ page, request }) => {
  const account = control("prepare", { scenario: "reminder" });
  await login(page, account);
  const queued = control("dispatch", account);
  expect(queued.status).toBe("pending");
  expect(queued.email_jobs).toBe(1);
  expect(await mailbox(request, account.email)).toHaveLength(0);
  await api(request, account, `/api/reminders/${account.reminder_id}`, "PATCH", { reminder: { active: false } });
  const delivered = control("deliver", account);
  expect(delivered.discarded).toBe(1);
  expect(delivered.completed).toBe(0);
  expect(await mailbox(request, account.email)).toHaveLength(0);
});

test("a deceased contact's Visit grave reminder is visible and delivers real email", async ({ page, request }) => {
  const account = control("prepare", { scenario: "reminder", deceased: true });
  await login(page, account);
  await page.goto("/reminders/upcoming");
  await connected(page);
  await expect(page.getByText(/Visit grave/)).toBeVisible();
  expect(control("dispatch", account).status).toBe("pending");
  expect(control("deliver", account).completed).toBe(1);
  await expect.poll(async () => (await mailbox(request, account.email)).map((message: any) => message.Subject)).toEqual(["Reminder: Visit grave"]);
});

test("a real UI snooze stays snoozed while archived and wakes only once after unarchiving", async ({ page, request }) => {
  const account = control("prepare", { scenario: "reminder", deceased: true });
  await login(page, account);
  const queued = control("dispatch", account);
  await page.goto("/reminders/upcoming");
  await connected(page);
  await page.locator("summary").filter({ hasText: "Snooze" }).click();
  await page.getByRole("button", { name: "3 days", exact: true }).click();
  await expect(page.getByText("Reminder snoozed for 3 days")).toBeVisible();
  expect(control("reminder_snapshot", account).status).toBe("snoozed");
  await contactAction(page, account.contact_id, "archive");
  await expect(page.getByText(/Mona Reminder archived\./)).toBeVisible();
  control("expire_snooze", account);
  const sleeping = control("dispatch", account);
  expect(sleeping.status).toBe("snoozed");
  expect(sleeping.email_jobs).toBe(queued.email_jobs);
  expect(await mailbox(request, account.email)).toHaveLength(0);

  await contactAction(page, account.contact_id, "unarchive");
  await expect(page.getByText(/Mona Reminder unarchived\./)).toBeVisible();
  expect(control("dispatch", account).status).toBe("pending");
  const awake = control("dispatch", account);
  expect(awake.email_jobs).toBe(queued.email_jobs + 1);
  const delivered = control("deliver", account);
  expect(delivered.completed).toBe(1);
  expect(delivered.discarded).toBe(1);
  await expect.poll(async () => (await mailbox(request, account.email)).length).toBe(1);
});

test("import preserves identical opposite-direction messages and remains stable on retry", async ({ page, request }) => {
  const account = control("prepare", { scenario: "import" });
  await login(page, account);
  const imported = await startImport(page, account);
  expect(imported.messages.map((message: any) => message.direction)).toEqual(["received", "sent"]);
  expect(imported.messages.map((message: any) => message.body)).toEqual(["OK", "OK"]);
  const retried = control("retry_misc", { ...account, import_id: imported.import_id });
  expect(retried.messages).toEqual(imported.messages);
  const conversationId = imported.messages[0].conversation_id;
  const response = await api(request, account, `/api/conversations/${conversationId}/messages`);
  expect(response.data).toHaveLength(2);
  expect(response.data.map((message: any) => message.direction).sort()).toEqual(["received", "sent"]);
  await page.goto(`/contacts/${imported.contacts[0].id}`);
  await connected(page);
  await expect(page.getByText("Fixture exchange", { exact: true }).first()).toBeVisible();
});

test("shipped contact editor rejects paste/drop injection and persists sanitized formatting", async ({ page, request }) => {
  const account = control("prepare", { scenario: "editor" });
  await login(page, account);
  await page.goto(`/contacts/${account.contact_id}`);
  await connected(page);

  // Use the application-loaded Trix, its real LiveView hook, and the real modal.
  // The fallback controller is the prerequisite for the drop advisory.
  await page.evaluate(() => { (window as any).Trix.config.input.level2Enabled = false; });
  await page.locator('button[phx-click="open-entry-modal"][phx-value-type="note"]').click();
  const form = page.locator('form[phx-submit="save-entry"]');
  const editor = form.locator("trix-editor");
  const hidden = form.locator('input[name="entry[body]"]');
  await expect(editor).toBeVisible();
  await expect.poll(() => editor.evaluate((element: any) =>
    element.editorController?.inputController instanceof (window as any).Trix.controllers.Level0InputController
  )).toBe(true);
  await editor.focus();

  // GHSA-53g2-mvcc-q9x3: attachment attributes must not bypass URL filtering.
  await editor.evaluate((element) => {
    const clipboardData = new DataTransfer();
    clipboardData.setData("text/html", `<span data-trix-attachment='{}' data-trix-attributes='{"href":"javascript:window.editorXSS=1"}'>Pasted payload text</span><strong>Kept bold</strong><a href="https://example.com/">Safe link</a><div>First paragraph</div><div>Second paragraph</div><div>Drop target</div>`);
    element.dispatchEvent(new ClipboardEvent("paste", { clipboardData, bubbles: true, cancelable: true }));
  });
  await expect(editor).toContainText("Pasted payload text");
  await expect(editor.locator("strong")).toHaveText("Kept bold");
  await expect(editor.locator('a[href="https://example.com/"]')).toHaveText("Safe link");
  await expect(hidden).not.toHaveValue(/javascript:|editorXSS/);

  // GHSA-53p3-c7vp-4mcc: application/x-trix-document drop attributes are untrusted.
  await editor.evaluate((element: any) => {
    element.editor.setSelectedRange([element.editor.getDocument().getLength() - 1, element.editor.getDocument().getLength() - 1]);
    const dataTransfer = new DataTransfer();
    dataTransfer.setData("application/x-trix-document", JSON.stringify([{ text: [{ type: "string", string: "Dropped safe italic", attributes: { href: "javascript:window.editorXSS=1", italic: true } }], attributes: [] }]));
    const bounds = element.getBoundingClientRect();
    element.dispatchEvent(new DragEvent("drop", { dataTransfer, bubbles: true, cancelable: true, clientX: bounds.left + 20, clientY: bounds.bottom - 10 }));
  });
  await expect(editor).toContainText("Dropped safe italic");
  await expect(editor.locator("em")).toHaveText("Dropped safe italic");
  await expect(hidden).not.toHaveValue(/javascript:|editorXSS/);
  expect(await page.evaluate(() => (window as any).editorXSS)).toBeUndefined();

  // Bypass client filtering in the actual submitted field to prove server-side
  // sanitation independently; these bytes never enter an executable DOM sink.
  await hidden.evaluate((input: HTMLInputElement) => {
    input.value += '<img src="x" onerror="window.editorXSS=1"><a href="javascript:window.editorXSS=1">Server-filtered link</a><iframe srcdoc="bad"></iframe><p><strong>Server-safe bold</strong></p>';
  });
  await form.getByRole("button", { name: "Save", exact: true }).click();
  await expect(editor).toHaveCount(0);

  const saved = await api(request, account, `/api/contacts/${account.contact_id}/notes`);
  expect(saved.data).toHaveLength(1);
  const body = saved.data[0].body;
  expect(body).toContain("Pasted payload text");
  expect(body).toContain("<strong>Kept bold</strong>");
  expect(body).toContain("<em>Dropped safe italic</em>");
  expect(body).toContain('href="https://example.com/"');
  expect(body).toContain("Server-filtered link");
  expect(body).toContain("<strong>Server-safe bold</strong>");
  expect(body).toContain("<div>First paragraph</div><div>Second paragraph</div>");
  expect(body).not.toMatch(/javascript:|editorXSS|<img|<iframe|onerror|srcdoc/i);

  await page.reload();
  await connected(page);
  // Reopen the stored note through the normal UI and assert formatting survives
  // the server sanitizer and the hook's initial-content loading after reload.
  const editButton = page.locator(`button[phx-click="edit-entry"][phx-value-type="note"][phx-value-id="${saved.data[0].id}"]`);
  await editButton.locator("..").locator("..").locator(":scope > button").click();
  await editButton.click();
  await expect(editor.locator("strong")).toHaveText(["Kept bold", "Server-safe bold"]);
  await expect(editor.locator("div").filter({ hasText: /^First paragraph$/ })).toBeVisible();
  await expect(editor.locator("div").filter({ hasText: /^Second paragraph/ })).toBeVisible();
  await expect(editor.locator("em")).toHaveText("Dropped safe italic");
  await expect(editor.locator('a[href="https://example.com/"]')).toHaveText("Safe link");
  await expect(hidden).not.toHaveValue(/javascript:|editorXSS|<img|<iframe|onerror|srcdoc/i);
  expect(await page.evaluate(() => (window as any).editorXSS)).toBeUndefined();
});

test("editing a legacy multiline note preserves breaks and escaped markup as text", async ({ page, request }) => {
  const account = control("prepare", { scenario: "editor" });
  const original = 'First line\nSecond line\n\nThird paragraph &amp; &lt;img src=x onerror=window.editorXSS=1&gt;';
  const created = await api(request, account, `/api/contacts/${account.contact_id}/notes`, "POST", { note: { body: original } });
  expect(created.data.body).toBe(original);
  await login(page, account);
  await page.goto(`/contacts/${account.contact_id}`);
  await connected(page);

  const editButton = page.locator(`button[phx-click="edit-entry"][phx-value-type="note"][phx-value-id="${created.data.id}"]`);
  async function openNote() {
    await editButton.locator("..").locator("..").locator(":scope > button").click();
    await editButton.click();
  }
  await openNote();
  const form = page.locator('form[phx-submit="save-entry"]');
  const editor = form.locator("trix-editor");
  const expectedText = 'First line\nSecond line\n\nThird paragraph & <img src=x onerror=window.editorXSS=1>';
  await expect.poll(() => editor.evaluate((element: any) => element.editor.getDocument().toString())).toBe(`${expectedText}\n`);
  await expect(editor.locator("img")).toHaveCount(0);
  expect(await page.evaluate(() => (window as any).editorXSS)).toBeUndefined();

  // Editing forces the hook to serialize editor HTML, rather than resubmitting
  // the original textarea-era value unchanged.
  await editor.evaluate((element: any) => {
    const end = element.editor.getDocument().getLength() - 1;
    element.editor.setSelectedRange([end, end]);
    element.editor.insertString(" edited");
  });
  await form.getByRole("button", { name: "Save", exact: true }).click();
  await expect(editor).toHaveCount(0);
  const saved = await api(request, account, `/api/notes/${created.data.id}`);
  expect(saved.data.body).toContain("edited");
  expect(saved.data.body).not.toContain("<img");
  expect(saved.data.body).toContain("&lt;img");

  await page.reload();
  await connected(page);
  await openNote();
  await expect.poll(() => editor.evaluate((element: any) => element.editor.getDocument().toString())).toBe(`${expectedText} edited\n`);
  await expect(editor.locator("img")).toHaveCount(0);
  expect(await page.evaluate(() => (window as any).editorXSS)).toBeUndefined();
});
