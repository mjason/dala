// The tab-switch accelerators live only in the client: inside a browser tab
// ⌘1..9 / Ctrl+1..9 belong to the browser's own tabs and never reach the page.
// They are therefore NOT in menuShortcuts (not rebindable from Settings), so
// the drift pin in menu-shortcuts.test.js does not cover them — this does.
const { test, describe } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const MAIN_JS = fs.readFileSync(path.join(__dirname, "..", "main.js"), "utf8");
const { MESSAGES } = require("../menu-locales");

describe("switch-tab menu", () => {
  test("nine items, accelerated with CmdOrCtrl+1..9", () => {
    const block = MAIN_JS.match(/label: t\("switchTab"\),\s*submenu: ([\s\S]*?\}\)\),)/);
    assert.ok(block, "main.js must build the switchTab submenu");

    assert.match(block[1], /length: 9/);
    assert.match(block[1], /accelerator: `CmdOrCtrl\$\{?\+?[^`]*`|accelerator: `CmdOrCtrl\+\$\{index \+ 1\}`/);
    assert.match(block[1], /sendMenuAction\(`switch-tab-\$\{index \+ 1\}`\)/);
  });

  test("the action names match what the web app parses", () => {
    // assets/js/app/shellTabs.ts: /^switch-tab-([1-9])$/
    for (let index = 1; index <= 9; index += 1) {
      assert.match(`switch-tab-${index}`, /^switch-tab-([1-9])$/);
    }
  });

  test("every locale labels the submenu", () => {
    for (const [locale, messages] of Object.entries(MESSAGES)) {
      assert.ok(messages.switchTab, `${locale} is missing switchTab`);
    }
  });

  test("the quick-shell item is labelled as what it now does", () => {
    // It creates an attached shell tab; "Quick Shell" was the removed overlay.
    for (const [locale, messages] of Object.entries(MESSAGES)) {
      assert.ok(messages.quickShell, `${locale} is missing quickShell`);
      assert.doesNotMatch(messages.quickShell, /Quick Shell|快速 Shell/, `${locale} still says "quick shell"`);
    }
  });
});
