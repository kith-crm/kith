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
