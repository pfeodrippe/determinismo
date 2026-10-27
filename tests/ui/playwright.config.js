// SPDX-License-Identifier: MIT
// The web UI's tests (ui.spec.js), against the serve at DETERMINISMO_URL with the runs the e2e's
// ui check made there (tools/e2e.zig): `zig build e2e -- --only ui`, after `npm ci` and
// `npx playwright install --with-deps chromium` here.
const { defineConfig } = require("@playwright/test");

module.exports = defineConfig({
  testDir: ".",
  // A causality analysis replays a timeline and forks futures at a dozen moments.
  timeout: 20 * 60 * 1000,
  expect: { timeout: 30 * 1000 },
  workers: 1,
  reporter: [["list"]],
  use: {
    baseURL: process.env.DETERMINISMO_URL,
    browserName: "chromium",
    headless: true,
    viewport: { width: 1400, height: 1000 },
  },
});
