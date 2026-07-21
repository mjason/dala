// Playwright config for dala's BDD e2e suite.
//
// - Uses the SYSTEM chromium (/usr/bin/chromium) by default — never `npx
//   playwright install` locally; downloaded browsers are not wired up in
//   this environment. CI overrides via CHROMIUM_BIN (playwright's own
//   chromium there). An empty CHROMIUM_BIN means "playwright default".
// - Single worker: all specs talk to ONE dev server on :4499 and sessions
//   are global server state, so parallel workers would race each other.
// - The fake-media flags make getUserMedia yield a synthetic mic without a
//   permission prompt (needed by voice.spec.js, harmless everywhere else).
const { defineConfig } = require("@playwright/test");

// The default suite runs with GPU disabled so it is reliable on headless CI.
// Opt-in WebGL coverage uses Chromium's software rasterizer; this exercises
// xterm's WebGL canvas and resize path without requiring a physical GPU.
const webglE2e = process.env.DALA_E2E_WEBGL === "1";

module.exports = defineConfig({
  testDir: ".",
  workers: 1,
  // CI runner 慢（2 核），会话创建→holder→xterm 就绪偶发超 10s；本地不重试
  retries: process.env.CI ? 2 : 0,
  fullyParallel: false,
  timeout: 60_000,
  expect: { timeout: 10_000 },
  reporter: [["list"]],
  use: {
    baseURL: "http://127.0.0.1:4499",
    headless: true,
    permissions: ["microphone"],
    launchOptions: {
      ...(process.env.CHROMIUM_BIN === ""
        ? {}
        : { executablePath: process.env.CHROMIUM_BIN || "/usr/bin/chromium" }),
      args: [
        "--no-sandbox",
        ...(webglE2e
          ? [
              "--use-gl=swiftshader",
              "--use-angle=swiftshader",
              "--enable-unsafe-swiftshader",
              "--ignore-gpu-blocklist",
            ]
          : ["--disable-gpu"]),
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
