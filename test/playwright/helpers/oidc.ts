import { expect, type Page } from "@playwright/test";
import https from "node:https";
import fs from "node:fs";

export type Viewer = {
  email: string;
  user_id: number;
  account_id?: number;
  subject: string;
  secret?: string;
  recovery?: string;
};
export function control<T = any>(action: string, args: object = {}): Promise<T> {
  if (!process.env.KITH_OIDC_E2E || !process.env.KITH_OIDC_TLS) {
    throw new Error("Run fixtures/oidc/run.sh; OIDC fixtures are mandatory");
  }
  return new Promise((resolve, reject) => {
    const body = JSON.stringify({ action, args });
    const request = https.request({
      ...runnerTLS(),
      path: "/__fixture__",
      method: "POST",
      headers: {
        authorization: `Bearer ${process.env.KITH_TEST_FIXTURE_TOKEN}`,
        "content-type": "application/json",
        "content-length": Buffer.byteLength(body),
      },
    }, response => {
      let result = "";
      response.on("data", chunk => result += chunk);
      response.on("end", () => {
        if (response.statusCode !== 200) {
          reject(new Error(`Fixture control ${action} failed (${response.statusCode})`));
          return;
        }
        try { resolve(JSON.parse(result)); } catch { reject(new Error(`Invalid fixture response for ${action}`)); }
      });
    });
    request.on("error", reject);
    request.setTimeout(15_000, () => request.destroy(new Error("Fixture control timeout")));
    request.end(body);
  });
}
export async function prepare(args: object = {}): Promise<Viewer> { return control("prepare", args); }
export async function selectIdentity(viewer: Viewer) {
  await control("behavior", { mode: "normal" });
  await control("claims", { sub: viewer.subject, email: viewer.email, email_verified: true });
}
export async function connected(page: Page) { await expect(page.locator("[data-phx-main].phx-connected")).toBeVisible(); }
export async function beginOidcLogin(page: Page) {
  await page.goto("/users/log-in");
  await connected(page);
  await page.getByRole("link", { name: "Continue with OpenID Connect", exact: true }).click();
  await expect.poll(() => new URL(page.url()).hostname).toBe("issuer.test");
  await expect(page.getByRole("button", { name: "Authorize", exact: true })).toBeVisible();
}
export async function authorize(page: Page, destination: RegExp = /\/dashboard$/) {
  await page.getByRole("button", { name: "Authorize", exact: true }).click();
  // Callback/issuer queries contain correlation values. Report only the path
  // if navigation fails, never the complete credential-bearing URL.
  await expect.poll(() => new URL(page.url()).pathname).toMatch(destination);
}
export async function loginOidc(page: Page, viewer: Viewer) {
  await selectIdentity(viewer);
  await beginOidcLogin(page);
  await authorize(page);
  await connected(page);
}
export async function noOverflow(page: Page) {
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
}
export async function logout(page: Page) {
  for (const close of await page.getByRole("alert").getByRole("button", { name: "close", exact: true }).all()) await close.click();
  await page.goto("/dashboard");
  await connected(page);
  if ((page.viewportSize()?.width ?? 1280) >= 768) await page.locator('[x-data="userMenu"] > button').click();
  await page.locator('a[href="/users/log-out"]:visible').click();
  await expect(page).toHaveURL(/\/users\/log-in$/);
}

// Protocol probes share the runner's private CA and DNS mapping. They never
// establish browser authentication and avoid HTTP Basic challenge UI prompts.
export function protocolStatus(method: string, path: string, headers: Record<string, string> = {}, body = ""): Promise<number> {
  return new Promise((resolve, reject) => {
    const request = https.request({ ...runnerTLS(), path, method, headers }, response => {
      response.resume();
      response.on("end", () => resolve(response.statusCode!));
    });
    request.on("error", reject);
    request.setTimeout(10_000, () => request.destroy(new Error("Protocol probe timeout")));
    request.end(body);
  });
}


function runnerTLS(): https.RequestOptions {
  if (!process.env.KITH_OIDC_TLS) throw new Error("Missing isolated fixture CA");
  return {
    hostname: "kith.test",
    port: Number(process.env.PORT),
    ca: fs.readFileSync(`${process.env.KITH_OIDC_TLS}/ca.pem`),
    lookup: (_host, options, callback) => options.all
      ? callback(null, [{ address: "127.0.0.1", family: 4 }])
      : callback(null, "127.0.0.1", 4),
  };
}
