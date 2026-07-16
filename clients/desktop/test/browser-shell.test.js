const { test, describe } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const main = fs.readFileSync(path.join(__dirname, "../main.js"), "utf8");
const toolbar = fs.readFileSync(path.join(__dirname, "../src/browser.html"), "utf8");

describe("external browser shell", () => {
  test("keeps the remote document in a sandboxed WebContentsView", () => {
    assert.match(main, /new WebContentsView/);
    assert.match(main, /sandbox:\s*true/);
    assert.match(main, /win\.contentView\.addChildView\(view\)/);
  });

  test("only the local toolbar invokes the system-browser command", () => {
    assert.match(toolbar, /open_current_in_system_browser/);
    assert.match(toolbar, /title="Open in system browser"/);
    assert.match(toolbar, /aria-label="Open in system browser"/);
    // A thin-stroke SVG globe, not the chunky 🌐 emoji.
    assert.match(toolbar, /<svg[^>]*stroke="currentColor"/);
    assert.doesNotMatch(toolbar, /🌐/);
    assert.match(main, /browserWindowFor\(event\)/);
    assert.match(main, /shell\.openExternal\(url\)/);
  });

  test("open_external is server-frame-gated and http(s)-only", () => {
    const start = main.indexOf('ipcMain.handle("open_external"');
    const handler = main.slice(start, main.indexOf("ipcMain.handle(", start + 1));
    // Only the server page's own top frame may ask (see ipc-guards.test.js)…
    assert.match(handler, /assertServerFrame\(event\)/);
    // …and only for http(s) targets (no file:, javascript:, …).
    assert.match(handler, /httpUrl\(url\)/);
    assert.match(handler, /shell\.openExternal\(target\)/);
  });

  test("uses one compact custom titlebar instead of stacking a toolbar", () => {
    assert.match(main, /titleBarStyle:\s*"hiddenInset"/);
    assert.match(main, /titleBarOverlay/);
    assert.match(main, /BROWSER_TITLEBAR_HEIGHT = 40/);
    assert.match(toolbar, /-webkit-app-region:\s*drag/);
    assert.match(toolbar, /-webkit-app-region:\s*no-drag/);
  });
});
