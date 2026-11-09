// Actual Android only. Never install a driver, bypass TLS, or install session cookies.
import { _android as android, expect } from "@playwright/test";
import { createHmac } from "node:crypto";
import fs from "node:fs";
import https from "node:https";

let phase = "authorized Android discovery";
let device, context;
const watchdog = setTimeout(() => {
  console.error(`FAIL: Android validation timed out during ${phase}; no acceptance recorded`);
  process.exit(1);
}, 180_000);
function requireValue(name) {
  if (!process.env[name]) throw new Error("Missing prerequisite");
  return process.env[name];
}
function secureURL(value) {
  const url = new URL(value);
  if (url.protocol !== "https:" || url.username || url.password || url.search || url.hash)
    throw new Error("Trusted HTTPS origin required");
  return url;
}
function totp(secret) {
  let bits = "";
  for (const c of secret.replace(/=/g, "")) {
    const n = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".indexOf(c);
    if (n < 0) throw new Error("Invalid fixture secret");
    bits += n.toString(2).padStart(5, "0");
  }
  const key = Buffer.from(bits.match(/.{8}/g).map(b => parseInt(b, 2)));
  const counter = Buffer.alloc(8);
  counter.writeBigUInt64BE(BigInt(Math.floor(Date.now() / 30_000)));
  const digest = createHmac("sha1", key).update(counter).digest();
  return ((digest.readUInt32BE(digest[19] & 15) & 0x7fffffff) % 1_000_000).toString().padStart(6, "0");
}
try {
  // omitDriverInstall is mandatory: a missing preprovisioned driver fails the run.
  const devices = await Promise.race([
    android.devices({ omitDriverInstall: true }),
    new Promise((_, reject) => setTimeout(() => reject(new Error("Connect exactly one authorized Android test device")), 10_000)),
  ]);
  if (devices.length !== 1) throw new Error("Connect exactly one authorized Android test device");
  device = devices[0];
  phase = "HTTPS and protected fixture prerequisites (see Android runbook)";
  const app = secureURL(requireValue("KITH_ANDROID_TEST_URL"));
  const issuer = secureURL(requireValue("KITH_ANDROID_ISSUER_URL"));
  if (app.hostname === issuer.hostname || process.env.KITH_OIDC_E2E !== "1" ||
      !["true", "false"].includes(process.env.KITH_OIDC_PASSWORD)) throw new Error("Fixture prerequisites missing");
  const ca = fs.readFileSync(`${requireValue("KITH_OIDC_TLS")}/ca.pem`);
  const token = requireValue("KITH_TEST_FIXTURE_TOKEN");
  function request(method, path, headers = {}, body = "") {
    return new Promise((resolve, reject) => {
      const req = https.request(new URL(path, app), { method, ca, headers }, response => {
        let data = "";
        response.on("data", chunk => data += chunk);
        response.on("end", () => resolve({ status: response.statusCode, data }));
      });
      req.on("error", () => reject(new Error("Trusted fixture request failed")));
      req.setTimeout(15_000, () => req.destroy(new Error("Fixture timeout")));
      req.end(body);
    });
  }
  async function control(action, args = {}) {
    const result = await request("POST", "/__fixture__", {
      authorization: `Bearer ${token}`, "content-type": "application/json",
    }, JSON.stringify({ action, args }));
    if (result.status !== 200) throw new Error("Protected fixture control failed");
    return JSON.parse(result.data);
  }
  context = await device.launchBrowser();
  context.setDefaultTimeout(15_000);
  const page = await context.newPage();
  async function connected() { await expect(page.locator("[data-phx-main].phx-connected")).toBeVisible(); }
  async function path(expected) { await expect.poll(() => new URL(page.url()).pathname).toBe(expected); }
  async function authorize(destination) {
    await expect.poll(() => new URL(page.url()).origin).toBe(issuer.origin);
    await page.getByRole("button", { name: "Authorize", exact: true }).tap();
    await path(destination);
  }
  const viewer = await control("prepare", { mfa: true });
  await control("behavior", { mode: "normal" });
  await control("claims", { sub: viewer.subject, email: viewer.email, email_verified: true });
  phase = "Android login, callback and local MFA";
  await page.goto(new URL("/users/log-in", app).href);
  await connected();
  if (!(await page.getByRole("link", { name: /Continue with/ }).isVisible()))
    throw new Error("OIDC login action missing on Android");
  await page.getByRole("link", { name: /Continue with/ }).tap();
  await authorize("/users/two-factor");
  const probe = await context.newPage();
  await probe.goto(new URL("/dashboard", app).href);
  await expect.poll(() => new URL(probe.url()).pathname).toBe("/users/log-in");
  await probe.close();
  const code = page.getByLabel("Authentication code", { exact: true });
  await code.tap();
  await expect(code).toBeFocused();
  await code.fill(totp(viewer.secret) === "000000" ? "111111" : "000000");
  await expect(page.getByRole("alert")).toBeVisible();
  await path("/users/two-factor");
  await code.fill(totp(viewer.secret));
  await path("/dashboard");
  await connected();
  phase = "Android settings selector, back and fresh authentication";
  await page.goto(new URL("/settings/contact-sync", app).href);
  await connected();
  const selector = page.getByLabel("Settings", { exact: true });
  await expect(selector).toBeEnabled();
  await selector.selectOption("/settings/security");
  await path("/settings/security");
  await device.press("KEYCODE_BACK");
  await path("/settings/contact-sync");
  await control("stale", { user_id: viewer.user_id });
  await page.goto(new URL("/settings/security", app).href);
  await path("/users/log-in");
  await connected();
  await page.locator("#oidc-reauth-form").getByRole("button").tap();
  await expect.poll(() => new URL(page.url()).searchParams.get("max_age")).toBe("0");
  await authorize("/users/two-factor");
  await page.getByLabel("Authentication code", { exact: true }).fill(totp(viewer.secret));
  await path("/settings/security");
  await connected();
  await selector.selectOption("/settings/contact-sync");
  await path("/settings/contact-sync");
  await connected();
  phase = "Android credential touch, focus, reveal and revocation";
  await page.getByRole("link", { name: "Create app password", exact: true }).tap();
  const name = page.getByLabel("Device name", { exact: true });
  await name.tap();
  await expect(name).toBeFocused();
  await name.fill("Android validation ephemeral");
  // OS keyboard opening/occlusion and native selection still require observation.
  await device.press("KEYCODE_BACK");
  const submit = page.getByRole("button", { name: "Create app password", exact: true });
  await submit.focus();
  await expect(submit).toBeInViewport();
  if ((await submit.boundingBox()).height < 44) throw new Error("Touch target too small");
  await submit.tap();
  await expect(page.locator("#dav-secret")).toBeVisible();
  const secret = await page.locator("#dav-secret").inputValue();
  const dav = async password => (await request("PROPFIND", "/dav/principals/", {
    authorization: "Basic " + Buffer.from(`${viewer.email}:${password}`).toString("base64"), Depth: "0",
  })).status;
  if (await dav(secret) !== 207) throw new Error("App password DAV probe failed");
  if (await dav("ValidP@ssword123!") !== (process.env.KITH_OIDC_PASSWORD === "false" ? 401 : 207))
    throw new Error("Account password policy mismatch");
  await page.locator("#dav-secret").tap();
  await expect(page.locator("#dav-secret")).toBeFocused();
  if (!(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth))) throw new Error("Horizontal overflow");
  await page.reload(); await connected();
  await expect(page.locator("#dav-secret")).toHaveCount(0);
  await page.getByRole("link", { name: "Cancel", exact: true }).tap();
  await page.getByRole("link", { name: "Revoke", exact: true }).tap();
  await page.getByRole("button", { name: "Revoke app password", exact: true }).tap();
  await expect(page.getByText("App password revoked", { exact: true })).toBeVisible();
  if (await dav(secret) !== 401) throw new Error("Revoked credential accepted");
  console.log("PASS: automated actual Android Chrome subset; manual keyboard/select/link, DAVx5 and Authentik acceptance require separate evidence");
} catch {
  // Playwright errors may include input values or callback URLs: never print them.
  console.error(`FAIL: ${phase}. Connect exactly one authorized Android test device and satisfy docs/design/oidc-android-validation.md prerequisites. No acceptance recorded.`);
  process.exitCode = 1;
} finally {
  await context?.close().catch(() => {});
  await device?.close().catch(() => {});
  clearTimeout(watchdog);
}
// An unavailable ADB service may leave its discovery socket open.
process.exit(process.exitCode ?? 0);
