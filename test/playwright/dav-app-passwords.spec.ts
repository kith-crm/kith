import { test, expect, type Page } from "@playwright/test";
import { prepare, loginOidc, connected, noOverflow, logout, protocolStatus } from "./helpers/oidc";

test.afterEach(async ({ page }) => { await page.close(); });

async function create(page: Page, name: string) {
  const begin = page.getByRole("link", { name: "Create app password", exact: true });
  expect((await begin.boundingBox())!.height).toBeGreaterThanOrEqual(44);
  await begin.click();
  await page.getByLabel("Device name", { exact: true }).fill(name);
  const submit = page.getByRole("button", { name: "Create app password", exact: true });
  expect((await submit.boundingBox())!.height).toBeGreaterThanOrEqual(44);
  await submit.click();
  await expect(page.locator("#dav-secret")).toBeVisible();
  return page.locator("#dav-secret").inputValue();
}
async function dav(page: Page, email: string, password: string) {
  return protocolStatus("PROPFIND", "/dav/principals/", { Authorization: "Basic " + Buffer.from(email + ":" + password).toString("base64"), Depth: "0" });
}

for (const width of [1440, 320, 375, 393]) {
  test(`personal credential create reveal reload revoke and immediate DAV denial at ${width}px`, async ({ page }) => {
    const viewer = await prepare({ role: "viewer" });
    await page.setViewportSize({ width, height: 900 });
    await loginOidc(page, viewer);
    await page.goto("/settings/contact-sync"); await connected(page);
    await expect(page.getByText("No app passwords yet. Create one to connect your first device.", { exact: true })).toBeVisible();
    await expect(page.locator("#carddav-url")).toHaveValue(`${process.env.PLAYWRIGHT_BASE_URL}/dav/principals/`);
    const name = "Phone-" + "x".repeat(74);
    const secret = await create(page, name);
    expect(secret.startsWith("kith_dav_")).toBe(true);
    // Assert booleans so a failed assertion cannot print the credential.
    expect(await dav(page, viewer.email, secret) === 207).toBe(true);
    expect(await dav(page, "other@example.test", secret) === 401).toBe(true);
    expect(await page.evaluate(() => JSON.stringify({ ...localStorage, ...sessionStorage }).includes("kith_dav_"))).toBe(false);
    expect(await page.locator("#dav-secret-copy").getAttribute("data-copy-value")).toBeNull();
    await page.evaluate(() => Object.defineProperty(navigator, "clipboard", { configurable: true, value: { writeText: () => Promise.reject(new Error("Permission denied")) } }));
    const copy = page.locator("#dav-secret-copy").getByRole("button", { name: "Copy", exact: true });
    expect((await copy.boundingBox())!.height).toBeGreaterThanOrEqual(44);
    await copy.click();
    await expect(page.getByRole("status").filter({ hasText: /copy.*manually/i })).toBeVisible();
    await page.locator("#dav-secret").focus(); await page.keyboard.press("ControlOrMeta+A");
    expect(await page.locator("#dav-secret").evaluate((input: HTMLInputElement) => input.selectionEnd! - input.selectionStart! === input.value.length)).toBe(true);
    await noOverflow(page);
    await page.reload(); await connected(page);
    await expect(page.locator("#dav-secret")).toHaveCount(0);
    await page.getByRole("link", { name: "Cancel", exact: true }).click();
    await expect(page.getByText(name, { exact: true })).toBeVisible();
    await page.getByRole("link", { name: "Revoke", exact: true }).click();
    await page.getByRole("button", { name: "Revoke app password", exact: true }).click();
    await expect(page.getByText("App password revoked", { exact: true })).toBeVisible();
    expect(await dav(page, viewer.email, secret) === 401).toBe(true);
    await expect(page.getByText("Revoked", { exact: true })).toBeVisible();
    await page.screenshot({ path: `tmp/oidc-browser/safe-revoked-${process.env.KITH_OIDC_MODE}-${width}.png` });
  });
}

test("app password cannot issue an API token or authenticate web login", async ({ page }) => {
  const viewer = await prepare(); await loginOidc(page, viewer);
  await page.goto("/settings/contact-sync"); await connected(page);
  const secret = await create(page, "DAV only");
  const status = await page.evaluate(async ({ email, secret }) => {
    const response = await fetch("/api/auth/token", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ email, password: secret }) }); return response.status;
  }, { email: viewer.email, secret });
  expect(status).toBe(process.env.KITH_OIDC_PASSWORD === "false" ? 403 : 401);
  await page.getByRole("link", { name: "Done", exact: true }).click();
  await logout(page); await connected(page);
  // Attempt the real web endpoint even on password-disabled instances.
  const submission = page.waitForResponse(response => response.request().method() === "POST" && new URL(response.url()).pathname === "/users/log-in");
  await page.evaluate(({ email, secret }) => {
    const csrf = document.querySelector('meta[name="csrf-token"]')!.getAttribute("content")!;
    const form = document.createElement("form"); form.method = "POST"; form.action = "/users/log-in";
    for (const [name, value] of Object.entries({ _csrf_token: csrf, "user[email]": email, "user[password]": secret })) { const input = document.createElement("input"); input.type = "hidden"; input.name = name; input.value = value; form.appendChild(input); }
    document.body.appendChild(form); form.submit();
  }, { email: viewer.email, secret });
  expect((await submission).status()).toBe(302);
  await expect(page.getByRole("alert").filter({ hasText: process.env.KITH_OIDC_PASSWORD === "false" ? "Password login is disabled." : "Invalid email or password" })).toBeVisible();
  await page.goto("/dashboard"); await expect(page).toHaveURL(/\/users\/log-in$/);
});

test("account DAV password follows the independent password policy", async ({ page }) => {
  const viewer = await prepare(); await loginOidc(page, viewer);
  expect(await dav(page, viewer.email, "ValidP@ssword123!") === (process.env.KITH_OIDC_PASSWORD === "false" ? 401 : 207)).toBe(true);
});

test("navigation clears a revealed credential and server failure recovers", async ({ page }) => {
  const viewer = await prepare(); await loginOidc(page, viewer);
  await page.goto("/settings/contact-sync"); await connected(page);
  await create(page, "Navigation secret");
  await page.goto("/settings/contact-sync"); await connected(page);
  await expect(page.locator("#dav-secret")).toHaveCount(0);
  await page.getByRole("link", { name: "Create app password", exact: true }).click();
  await page.getByLabel("Device name", { exact: true }).fill("Retry after connection failure");
  // A real unavailable websocket/server transport must not show false success.
  await page.context().setOffline(true);
  await page.getByRole("button", { name: "Create app password", exact: true }).click();
  await expect(page.locator("#dav-secret")).toHaveCount(0);
  await page.context().setOffline(false);
  await page.reload(); await connected(page);
  await page.getByLabel("Device name", { exact: true }).fill("Recovered device");
  await page.getByRole("button", { name: "Create app password", exact: true }).click();
  await expect(page.locator("#dav-secret")).toBeVisible();
  await page.goto("/settings/contact-sync"); await connected(page);
  await expect(page.locator("#dav-secret")).toHaveCount(0);
});

test("another non-admin cannot list or revoke the owner's credential", async ({ page }) => {
  const owner = await prepare({ role: "viewer" }); await loginOidc(page, owner);
  await page.goto("/settings/contact-sync"); await connected(page);
  const secret = await create(page, "Owner private device");
  await page.getByRole("link", { name: "Done", exact: true }).click();
  const revokePath = await page.getByRole("link", { name: "Revoke", exact: true }).getAttribute("href");
  await logout(page);
  expect(Number.isInteger(owner.account_id)).toBe(true);
  const other = await prepare({ role: "viewer", account_id: owner.account_id });
  expect(other.account_id === owner.account_id).toBe(true);
  await loginOidc(page, other);
  await page.goto("/settings/contact-sync"); await connected(page);
  await expect(page.getByText("Owner private device", { exact: true })).toHaveCount(0);
  await page.goto(revokePath!);
  await expect(page.getByRole("button", { name: "Revoke app password", exact: true })).toHaveCount(0);
  await expect(page.getByRole("alert").filter({ hasText: "App password is unavailable." })).toBeVisible();
  expect(await dav(page, owner.email, secret) === 207).toBe(true);
  expect(await dav(page, other.email, secret) === 401).toBe(true);
});
