import { defineConfig, devices } from "@playwright/test";

export default defineConfig({
  timeout: 30_000,
  expect: { timeout: 5_000 },
  fullyParallel: true,
  retries: 0,
  reporter: "list",
  use: {
    baseURL: process.env.PLAYWRIGHT_BASE_URL ?? "http://127.0.0.1:4000",
    trace: "retain-on-failure",
  },
  projects: [
    {
      name: "smoke",
      testDir: "./e2e",
      use: { ...devices["Desktop Chrome"], channel: "chromium" },
    },
    {
      name: "e2e",
      testDir: "./test/playwright",
      testMatch: "**/*.spec.ts",
      use: { ...devices["Desktop Chrome"], channel: "chromium" },
    },
  ],
});
