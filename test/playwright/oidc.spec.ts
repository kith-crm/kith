import { test, expect } from "@playwright/test";
import { createHmac } from "node:crypto";
import { prepare, selectIdentity, beginOidcLogin, authorize, loginOidc, connected, control, logout, noOverflow, protocolStatus, type Viewer } from "./helpers/oidc";
import { passwordLogin } from "./helpers/password-login";

test.setTimeout(45_000);
test.afterEach(async ({ page, context }) => {
  for (const open of context.pages()) await open.close();
});

function totp(base32: string): string {
  const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
  let bits = "";
  for (const c of base32.replace(/=/g, "")) bits += alphabet.indexOf(c).toString(2).padStart(5, "0");
  const bytes = Buffer.from(bits.match(/.{8}/g)!.map(b => parseInt(b, 2)));
  const counter = Buffer.alloc(8); counter.writeBigUInt64BE(BigInt(Math.floor(Date.now() / 30000)));
  const digest = createHmac("sha1", bytes).update(counter).digest();
  const offset = digest[19] & 15;
  return ((digest.readUInt32BE(offset) & 0x7fffffff) % 1000000).toString().padStart(6, "0");
}

for (const width of [1366, 1440, 320, 375, 393]) {
  test(`real distinct-site callback rotates session and sends only Lax binding at ${width}px`, async ({ page, context }) => {
    await page.setViewportSize({ width, height: 900 });
    const viewer = await prepare();
    await selectIdentity(viewer);
    await page.goto("/users/log-in");
    const original = (await context.cookies()).find(c => c.name === "_kith_key")?.value;
    await beginOidcLogin(page);
    const cookies = await context.cookies();
    const binding = cookies.find(c => c.name === "__Host-kith_oidc");
    expect(Boolean(binding?.secure && binding?.httpOnly && binding?.sameSite === "Lax" && binding?.path === "/")).toBe(true);
    expect(cookies.find(c => c.name === "_kith_key")?.sameSite).toBe("Strict");
    let callbackCookieNames: string[] = [];
    let dashboardHasSession = false;
    page.on("request", async request => {
      if (new URL(request.url()).pathname === "/dashboard") dashboardHasSession = (await request.headerValue("cookie") ?? "").split(";").some(value => value.trim().startsWith("_kith_key="));
      if (new URL(request.url()).pathname === "/auth/oidc/callback") {
        const header = await request.headerValue("cookie");
        callbackCookieNames = (header ?? "").split(";").map(c => c.trim().split("=")[0]);
      }
    });
    const responsePromise = page.waitForResponse(r => new URL(r.url()).pathname === "/auth/oidc/callback");
    await authorize(page);
    const response = await responsePromise;
    expect(response.headers()["cache-control"]).toBe("no-store");
    expect(response.headers()["referrer-policy"]).toBe("no-referrer");
    expect(callbackCookieNames).toContain("__Host-kith_oidc");
    expect(callbackCookieNames).not.toContain("_kith_key");
    expect(dashboardHasSession).toBe(true);
    expect((await context.cookies()).find(c => c.name === "_kith_key")?.value !== original).toBe(true);
    await page.goto("/settings/contact-sync");
    await expect(page.locator("#dav-connection").getByText(viewer.email, { exact: true })).toBeVisible();
    expect(new URL(page.url()).search).toBe("");
    expect(await page.evaluate(() => JSON.stringify({ local: { ...localStorage }, session: { ...sessionStorage }, html: document.documentElement.innerHTML }).includes("fixture-access"))).toBe(false);
    expect(await page.evaluate(() => /id_token|refresh_token|code_verifier|fixture-secret/.test(document.documentElement.innerHTML))).toBe(false);
    await noOverflow(page);
    await page.screenshot({ path: `tmp/oidc-browser/safe-sync-${process.env.KITH_OIDC_MODE}-${width}.png` });
  });
}

test("initial signup requires explicit terms and creates a personal account", async ({ page }) => {
  const viewer: Viewer = { email: `signup-${Date.now()}@example.test`, subject: `signup-${Date.now()}`, user_id: 0 };
  await selectIdentity(viewer);
  await beginOidcLogin(page);
  if (process.env.KITH_OIDC_REGISTRATION === "false") {
    await authorize(page, /\/users\/log-in$/);
    await expect(page.getByRole("alert").filter({ hasText: "Registration requires enabled signups" })).toBeVisible();
    await expect(page.getByRole("link", { name: "Sign up", exact: true })).toHaveCount(0);
    return;
  }
  await authorize(page, /\/users\/oidc\/register$/);
  await connected(page);
  await page.getByRole("button", { name: "Create account", exact: true }).click();
  await expect(page.getByRole("alert").filter({ hasText: "Please accept the Terms of Service." })).toBeVisible();
  await page.getByLabel("I accept the Terms of Service", { exact: true }).check();
  await page.getByRole("button", { name: "Create account", exact: true }).click();
  await expect(page).toHaveURL(/\/dashboard$/);
  await page.goto("/settings/account");
  await expect(page).toHaveURL(/\/settings\/account$/);
});

test("email collision never takes over the existing account", async ({ page }) => {
  const viewer = await prepare({ linked: false });
  await selectIdentity(viewer);
  await beginOidcLogin(page);
  await authorize(page, /\/users\/log-in$/);
  await expect(page.getByRole("alert").filter({ hasText: /existing account/i })).toBeVisible();
  expect((await control("snapshot", { user_id: viewer.user_id })).identities).toBe(0);
  await page.goto("/dashboard");
  await expect(page).toHaveURL(/\/users\/log-in$/);
});

for (const useRecovery of [false, true]) {
  test(`OIDC requires local MFA, rejects wrong code and completes with ${useRecovery ? "recovery" : "TOTP"}`, async ({ page, context }) => {
    await page.setViewportSize({ width: useRecovery ? 393 : 375, height: 900 });
    const viewer = await prepare({ mfa: true });
    await selectIdentity(viewer);
    await beginOidcLogin(page);
    await authorize(page, /\/users\/two-factor$/);
    await expect(page.getByLabel("Authentication code", { exact: true })).toBeVisible();
    const probe = await context.newPage();
    await probe.goto("/dashboard");
    await expect(probe).toHaveURL(/\/users\/log-in$/);
    await probe.close();
    await Promise.all([page.waitForResponse(response => new URL(response.url()).pathname === "/users/totp-verify"), page.getByLabel("Authentication code", { exact: true }).fill(totp(viewer.secret!) === "000000" ? "111111" : "000000")]);
    await expect(page).toHaveURL(/\/users\/two-factor$/);
    await expect(page.getByRole("alert")).toBeVisible();
    if (useRecovery) {
      await page.getByRole("button", { name: /recovery code/i }).click();
      await page.getByLabel("Recovery code", { exact: true }).fill(viewer.recovery!);
      await page.getByRole("button", { name: "Verify", exact: true }).click();
    } else {
      await page.getByLabel("Authentication code", { exact: true }).fill(totp(viewer.secret!));
    }
    await expect(page).toHaveURL(/\/dashboard$/);
    expect((await control("snapshot", { user_id: viewer.user_id })).recovery).toBe(useRecovery ? 7 : 8);
  });
}

test("two simultaneous flow tabs complete independently", async ({ page, context }) => {
  const viewer = await prepare(); await selectIdentity(viewer);
  await beginOidcLogin(page);
  const second = await context.newPage();
  await beginOidcLogin(second);
  await authorize(page);
  await authorize(second);
  await second.goto("/settings/contact-sync");
  await expect(second.locator("#dav-connection").getByText(viewer.email, { exact: true })).toBeVisible();
});

for (const failure of ["denied", "expired", "missing binding", "timeout", "replayed"]) {
  test(`${failure} callback fails closed through real navigation`, async ({ page, context }) => {
    const viewer = await prepare(); await selectIdentity(viewer); await beginOidcLogin(page);
    if (failure === "denied") {
      const query = new URL(page.url()).searchParams;
      const denied = query.get("redirect_uri")! + "?" + new URLSearchParams({ error: "access_denied", state: query.get("state")! });
      await control("behavior", { mode: "deny", redirect: denied });
    }
    if (failure === "expired") await control("expire");
    if (failure === "missing binding") await context.clearCookies({ name: "__Host-kith_oidc" });
    if (failure === "timeout") await control("behavior", { mode: "timeout" });
    if (failure === "replayed") {
      let callback = "";
      page.on("request", request => { if (new URL(request.url()).pathname === "/auth/oidc/callback") callback = request.url(); });
      await authorize(page);
      expect(Boolean(callback)).toBe(true);
      try { await page.goto(callback); } catch { throw new Error("Replay callback navigation failed"); }
      await expect(page).toHaveURL(/\/users\/log-in$/);
    } else {
      await authorize(page, /\/users\/log-in$/);
    }
    await expect(page.getByRole("alert").filter({ hasText: /unavailable|sign in/i })).toBeVisible();
    expect(new URL(page.url()).search).toBe("");
    await control("behavior", { mode: "normal" });
  });
}

test("key rotation refreshes the issuer JWKS without bypassing TLS", async ({ page }) => {
  const viewer = await prepare(); await loginOidc(page, viewer); await logout(page);
  await control("rotate");
  await loginOidc(page, viewer);
});

test("link and unlink preserve ownership and require provider reauthentication", async ({ page }) => {
  const viewer = await prepare(); await loginOidc(page, viewer);
  await control("stale", { user_id: viewer.user_id });
  await page.goto("/settings/security");
  await expect(page).toHaveURL(/\/users\/log-in$/);
  await connected(page);
  await page.locator("#oidc-reauth-form").getByRole("button").click();
  await expect.poll(() => new URL(page.url()).hostname).toBe("issuer.test");
  expect(new URL(page.url()).searchParams.get("max_age")).toBe("0");
  await authorize(page, /\/settings\/security$/);
  await connected(page);
  await page.getByRole("button", { name: "Unlink", exact: true }).click();
  await page.getByRole("button", { name: "Unlink account", exact: true }).click();
  if (process.env.KITH_OIDC_PASSWORD === "false") {
    await expect(page.locator("#oidc-status")).toHaveText("Connected");
    await expect(page.getByRole("status").filter({ hasText: /keep|last|another/i })).toBeVisible();
  } else {
    await expect(page.locator("#oidc-status")).toHaveText("Not connected");
    await selectIdentity(viewer);
    await page.getByRole("button", { name: "Connect account", exact: true }).click();
    await expect.poll(() => new URL(page.url()).hostname).toBe("issuer.test");
    await authorize(page, /\/settings\/security$/);
    await expect(page.locator("#oidc-status")).toHaveText("Connected");
  }
});

for (const cancel of ["logout", "revoked session"]) {
  test(`pending link rejects ${cancel} of the originating session`, async ({ page, context }) => {
    const viewer = await prepare({ linked: false });
    // This journey specifically starts from existing authenticated settings.
    if (process.env.KITH_OIDC_PASSWORD === "false") {
      const bootstrap = await prepare(); await loginOidc(page, bootstrap);
      await page.goto("/settings/security");
      // Reauth also carries the originating session and has the same revocation boundary.
      await control("stale", { user_id: bootstrap.user_id });
      await page.goto("/settings/security"); await connected(page);
      await page.locator("#oidc-reauth-form").getByRole("button").click();
      viewer.user_id = bootstrap.user_id;
    } else {
      await passwordLogin(page, viewer.email, "ValidP@ssword123!");
      await selectIdentity(viewer); await page.goto("/settings/security"); await connected(page);
      await page.getByRole("button", { name: "Connect account", exact: true }).click();
    }
    await expect.poll(() => new URL(page.url()).hostname).toBe("issuer.test");
    if (cancel === "logout") {
      const other = await context.newPage(); await other.goto("/dashboard"); await connected(other); await logout(other); await other.close();
    } else await control("revoke_sessions", { user_id: viewer.user_id });
    await authorize(page, /\/users\/log-in$/);
    await page.goto("/dashboard"); await expect(page).toHaveURL(/\/users\/log-in$/);
  });
}

test("password policy is enforced by UI and direct web/API requests", async ({ page }) => {
  const viewer = await prepare(); await page.goto("/users/log-in"); await connected(page);
  if (process.env.KITH_OIDC_PASSWORD === "false") {
    await expect(page.locator('input[type="password"]')).toHaveCount(0);
    await expect(page.getByRole("link", { name: /forgot/i })).toHaveCount(0);
    const api = await page.evaluate(async email => (await fetch("/api/auth/token", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ email, password: "ValidP@ssword123!" }) })).status, viewer.email);
    expect(api).toBe(403);
    // Native form submission keeps real CSRF/browser cookies.
    const submission = page.waitForResponse(response => response.request().method() === "POST" && new URL(response.url()).pathname === "/users/log-in");
    await page.evaluate(({ email }) => {
      const form = document.createElement("form"); form.method = "post"; form.action = "/users/log-in";
      const csrf = document.querySelector('meta[name="csrf-token"]')?.getAttribute("content") ?? document.querySelector<HTMLInputElement>('input[name="_csrf_token"]')?.value ?? "";
      for (const [name, value] of Object.entries({ _csrf_token: csrf, "user[email]": email, "user[password]": "ValidP@ssword123!" })) { const input = document.createElement("input"); input.name = name; input.value = value; form.appendChild(input); }
      document.body.appendChild(form); form.submit();
    }, { email: viewer.email });
    expect((await submission).status()).toBe(302);
    await expect(page.getByRole("alert").filter({ hasText: "Password login is disabled." })).toBeVisible();
    await expect(page).toHaveURL(/\/users\/log-in$/);
    await page.goto("/dashboard"); await expect(page).toHaveURL(/\/users\/log-in$/);
  } else {
    await expect(page.locator('input[type="password"]')).toBeVisible();
    await passwordLogin(page, viewer.email, "ValidP@ssword123!");
  }
});

test("a different identity already owned by another user cannot be linked", async ({ page }) => {
  const owner = await prepare();
  const attacker = await prepare(); await loginOidc(page, attacker);
  await selectIdentity(owner); await page.goto("/settings/security"); await connected(page);
  await page.evaluate(() => {
    const form = document.createElement("form"); form.method = "POST"; form.action = "/users/oidc/link";
    const input = document.createElement("input"); input.name = "_csrf_token"; input.value = document.querySelector('meta[name="csrf-token"]')!.getAttribute("content")!; form.appendChild(input); document.body.appendChild(form); form.submit();
  });
  await expect.poll(() => new URL(page.url()).hostname).toBe("issuer.test");
  await authorize(page, /\/users\/log-in$/);
  expect((await control("snapshot", { user_id: owner.user_id })).identities).toBe(1);
  expect((await control("snapshot", { user_id: attacker.user_id })).identities).toBe(1);
  await page.goto("/dashboard");
  await expect(page).toHaveURL(/\/users\/log-in$/);
});

test("unknown unverified identity cannot register and unavailable discovery can be retried", async ({ page }) => {
  await control("behavior", { mode: "unavailable" });
  await page.goto("/users/log-in"); await connected(page);
  await page.getByRole("link", { name: "Continue with OpenID Connect", exact: true }).click();
  await expect(page).toHaveURL(/\/users\/log-in$/);
  await expect(page.getByRole("alert").filter({ hasText: /unavailable/i })).toBeVisible();
  const viewer = { subject: `unverified-${Date.now()}`, email: `unverified-${Date.now()}@example.test`, user_id: 0 };
  await selectIdentity(viewer); await control("claims", { sub: viewer.subject, email: viewer.email, email_verified: false });
  await beginOidcLogin(page); await authorize(page, /\/users\/log-in$/);
  await expect(page.getByRole("alert").filter({ hasText: /verified email/i })).toBeVisible();
  await page.goto("/dashboard"); await expect(page).toHaveURL(/\/users\/log-in$/);
});

test("cancelled registration cannot be resumed", async ({ page }) => {
  const viewer = { subject: `cancel-${Date.now()}`, email: `cancel-${Date.now()}@example.test`, user_id: 0 };
  await selectIdentity(viewer); await beginOidcLogin(page);
  if (process.env.KITH_OIDC_REGISTRATION === "false") {
    await authorize(page, /\/users\/log-in$/);
    await expect(page.getByRole("alert").filter({ hasText: /enabled signups/i })).toBeVisible();
  } else {
    await authorize(page, /\/users\/oidc\/register$/);
    await connected(page);
    await page.getByRole("button", { name: "Cancel", exact: true }).click();
    await expect(page).toHaveURL(/\/users\/log-in$/);
    await page.goto("/users/oidc/register");
    await expect(page).toHaveURL(/\/users\/log-in$/);
  }
  await page.goto("/dashboard"); await expect(page).toHaveURL(/\/users\/log-in$/);
});

test("fixture controls reject missing and incorrect run tokens", async () => {
  expect(await protocolStatus("POST", "/__fixture__", { "content-type": "application/json" }, JSON.stringify({ action: "expire", args: {} }))).toBe(404);
  expect(await protocolStatus("POST", "/__fixture__", { authorization: "Bearer incorrect", "content-type": "application/json" }, JSON.stringify({ action: "expire", args: {} }))).toBe(404);
});
