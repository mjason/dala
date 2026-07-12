// Playwright config for dala's BDD e2e suite.
//
// - Uses the SYSTEM chromium (/usr/bin/chromium) — never `npx playwright
//   install`; downloaded browsers are not wired up in this environment.
// - Single worker: all specs talk to ONE dev server on :4499 and sessions
//   are global server state, so parallel workers would race each other.
// - The fake-media flags make getUserMedia yield a synthetic mic without a
//   permission prompt (needed by voice.spec.js, harmless everywhere else).
const { defineConfig } = require("@playwright/test");

module.exports = defineConfig({
  testDir: ".",
  workers: 1,
  fullyParallel: false,
  timeout: 60_000,
  expect: { timeout: 10_000 },
  reporter: [["list"]],
  use: {
    baseURL: "http://127.0.0.1:4499",
    headless: true,
    permissions: ["microphone"],
    launchOptions: {
      executablePath: "/usr/bin/chromium",
      args: [
        "--no-sandbox",
        "--disable-gpu",
        "--use-fake-device-for-media-stream",
        "--use-fake-ui-for-media-stream",
      ],
    },
  },
  webServer: {
    command: "bash ./start-server.sh",
    url: "http://127.0.0.1:4499",
    timeout: 120_000,
    reuseExistingServer: false,
  },
});
