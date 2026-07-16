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
    assert.match(main, /browserWindowFor\(event\)/);
    assert.match(main, /shell\.openExternal\(url\)/);
  });
});
