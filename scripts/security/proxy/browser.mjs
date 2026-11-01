// Real Chromium + the production LiveView client through the actual Caddy proxy.
// This script never constructs a synthetic Phoenix socket or calls the resolver.
import assert from "node:assert/strict";
import { writeFile } from "node:fs/promises";
import path from "node:path";
import { chromium, expect } from "@playwright/test";

const baseURL = process.env.KITH_PROXY_BROWSER_URL;
const reportDirectory = process.env.KITH_PROXY_REPORT_DIRECTORY;
assert(baseURL && reportDirectory, "Pass the loopback Caddy URL and report directory");
const forgedClient = "192.0.2.222";
const email = `proxy-smoke-signup-${Date.now()}@example.test`;
const errors = [];
const browser = await chromium.launch({ args: ["--host-resolver-rules=MAP localhost 127.0.0.1"] });

async function avoidWindowBoundary() {
  const remaining = 60_000 - Date.now() % 60_000;
  if (remaining < 15_000) await new Promise(resolve => setTimeout(resolve, remaining + 50));
}

function header(headers, name) {
  return Object.entries(headers).find(([key]) => key.toLowerCase() === name.toLowerCase())?.[1];
}

try {
  const context = await browser.newContext({
    baseURL,
    extraHTTPHeaders: {
      "X-Kith-Client-IP": forgedClient,
      "X-Forwarded-For": "198.51.100.222",
      "X-Kith-Probe-ID": "browser-signup",
    },
  });
  const page = await context.newPage();
  page.setDefaultTimeout(15_000);
  page.on("pageerror", error => errors.push(error.message));
  const cdp = await context.newCDPSession(page);
  await cdp.send("Network.enable");
  const handshakes = [];
  const handshakeStatuses = [];
  cdp.on("Network.webSocketWillSendHandshakeRequest", event => handshakes.push(event.request.headers));
  cdp.on("Network.webSocketHandshakeResponseReceived", event => handshakeStatuses.push(event.response.status));
  const saves = [];
  const replies = new Set();
  page.on("websocket", socket => {
    socket.on("framesent", ({ payload }) => {
      try {
        const [, ref, , event, value] = JSON.parse(payload.toString());
        if (event === "event" && value.event === "save") saves.push(ref);
      } catch {
        // Non-JSON control frames are not application saves.
      }
    });
    socket.on("framereceived", ({ payload }) => {
      try {
        const [, ref, , event, value] = JSON.parse(payload.toString());
        if (event === "phx_reply" && value.status === "ok") replies.add(ref);
      } catch {
        // Non-JSON control frames are not save acknowledgements.
      }
    });
  });

  await avoidWindowBoundary();
  const response = await page.goto("/users/register");
  assert.equal(response.status(), 200);
  const verifiedClient = response.headers()["x-kith-verified-client"];
  assert(verifiedClient, "The actual HTTP endpoint must expose the fixture observation");
  assert.notEqual(verifiedClient, forgedClient);
  assert.equal(response.headers()["x-kith-socket-peer"], "172.30.44.2");
  await expect(page.locator("[data-phx-main].phx-connected")).toBeVisible();
  assert(await page.evaluate(() => window.liveSocket.socket.conn instanceof WebSocket));
  await expect.poll(() => handshakeStatuses.includes(101)).toBe(true);
  assert(handshakes.some(headers => header(headers, "x-kith-client-ip") === forgedClient),
    "The browser must actually send the forged header on its WebSocket handshake");

  for (let attempt = 1; attempt <= 6; attempt++) {
    await page.locator("#user_email").fill(email);
    await page.locator("#user_password").fill("short");
    await page.getByRole("button", { name: "Create an account", exact: true }).click();
    await expect.poll(() => saves.length).toBe(attempt);
    await expect.poll(() => replies.has(saves[attempt - 1])).toBe(true);
    if (attempt <= 5) {
      await expect(page.locator("body")).not.toContainText("Too many signup attempts");
      await expect(page.locator("#registration_form")).toContainText("should be at least 12 character");
    }
  }

  await expect(page.locator("body")).toContainText("Too many signup attempts");
  assert.equal(await page.locator("#registration_form").getAttribute("phx-trigger-action"), null);
  assert(await page.evaluate(() => window.liveSocket.socket.conn instanceof WebSocket));
  assert.deepEqual(errors, [], "The packaged browser assets must execute without page errors");

  // Keep CSRF and the browser's real session/origin checks active. These are
  // actual HTTP requests to the login controller, with forged identity headers.
  await page.goto("/users/log-in");
  const csrf = await page.locator('meta[name="csrf-token"]').getAttribute("content");
  assert(csrf);
  await avoidWindowBoundary();
  const loginFetches = [];
  for (let attempt = 1; attempt <= 11; attempt++) {
    // Context-level headers also apply to fetch; update them explicitly so
    // each actual outgoing login request carries its distinct forged values.
    await context.setExtraHTTPHeaders({
      "X-Kith-Client-IP": `192.0.2.${attempt}`,
      "X-Forwarded-For": `198.51.100.${attempt}`,
      "X-Kith-Probe-ID": `browser-login-${attempt}`,
    });
    const login = await page.evaluate(async ({ csrf, email, attempt }) => {
      const response = await fetch("/users/log-in", {
        method: "POST",
        credentials: "same-origin",
        headers: {
          "Content-Type": "application/x-www-form-urlencoded",
          "X-CSRF-Token": csrf,
          "X-Kith-Client-IP": `192.0.2.${attempt}`,
          "X-Forwarded-For": `198.51.100.${attempt}`,
          "X-Kith-Probe-ID": `browser-login-${attempt}`,
        },
        body: new URLSearchParams({
          _csrf_token: csrf,
          "user[email]": email,
          "user[password]": "invalid-fixture-password",
        }),
      });
      return {
        status: response.status,
        redirected: response.redirected,
        client: response.headers.get("x-kith-verified-client"),
        peer: response.headers.get("x-kith-socket-peer"),
        retry_after: response.headers.get("retry-after"),
      };
    }, { csrf, email, attempt });
    assert.equal(login.client, verifiedClient);
    assert.equal(login.peer, "172.30.44.2");
    if (attempt <= 10) {
      // Browser fetch follows the controller's 302. The server-side fixture
      // separately records each actual POST status and named-backend counter.
      assert.equal(login.status, 200);
      assert.equal(login.redirected, true);
    } else {
      assert.equal(login.status, 429);
      assert.equal(login.redirected, false);
      assert(Number(login.retry_after) >= 1);
    }
    loginFetches.push(login);
  }

  const report = {
    status: "passed",
    browser: "Chromium",
    verified_client: verifiedClient,
    forged_client: forgedClient,
    email,
    websocket_handshake_status: 101,
    forged_websocket_header_observed: true,
    websocket_save_count: saves.length,
    sixth_signup_attempt_blocked: true,
    browser_login_fetches: loginFetches,
    origin_checks_disabled: false,
    page_errors: errors,
  };
  await writeFile(path.join(reportDirectory, "browser-signup.json"), JSON.stringify(report, null, 2) + "\n");
  console.log("PASS: actual Caddy/WebSocket signup forgery is throttled at six saves; HTTP login blocks attempt eleven");
  await context.close();
} finally {
  await browser.close();
}
