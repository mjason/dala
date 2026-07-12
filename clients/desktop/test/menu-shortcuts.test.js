// Drift pin: main.js hardcodes default menu accelerators that mirror the
// web app's default keybindings (assets/js/app/keybindings.ts, entries with
// clientMenu: true, converted through comboToAccelerator). Neither side
// imports the other — the web side is TypeScript bundled elsewhere — so this
// test parses both source files and fails when they diverge.
const { test, describe } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const KEYBINDINGS_TS = path.join(__dirname, "..", "..", "..", "assets", "js", "app", "keybindings.ts");
const MAIN_JS = path.join(__dirname, "..", "main.js");

// BINDINGS entries flagged for the client menu, e.g.
//   { id: "composer", ..., default: "mod+shift+k", ..., clientMenu: true },
function parseClientMenuBindings(source) {
  const bindings = {};
  const entry = /\{\s*id:\s*"([^"]+)"[^}]*?default:\s*"([^"]+)"[^}]*?clientMenu:\s*true[^}]*\}/g;
  for (const [, id, combo] of source.matchAll(entry)) bindings[id] = combo;
  return bindings;
}

// The `let menuShortcuts = { composer: "...", ... }` literal in main.js.
function parseMenuShortcuts(source) {
  const block = source.match(/let menuShortcuts = \{([\s\S]*?)\};/);
  assert.ok(block, "main.js must declare `let menuShortcuts = { ... };`");
  const shortcuts = {};
  for (const [, key, accel] of block[1].matchAll(/(\w+):\s*"([^"]+)"/g)) {
    shortcuts[key] = accel;
  }
  return shortcuts;
}

// Mirror of comboToAccelerator in keybindings.ts, for the combo shapes the
// client menu uses (mod/ctrl/alt/shift + single key or backtick).
function comboToAccelerator(combo) {
  const parts = combo.toLowerCase().split("+");
  const key = parts[parts.length - 1];
  const mods = new Set(parts.slice(0, -1));
  const accelKey = key === "`" ? "`" : key.length === 1 ? key.toUpperCase() : null;
  assert.ok(accelKey, `unsupported key in combo "${combo}"`);
  return [
    mods.has("mod") ? "CmdOrCtrl" : "",
    mods.has("ctrl") && !mods.has("mod") ? "Ctrl" : "",
    mods.has("alt") ? "Alt" : "",
    mods.has("shift") ? "Shift" : "",
    accelKey,
  ]
    .filter(Boolean)
    .join("+");
}

describe("menu shortcut defaults stay in sync with keybindings.ts", () => {
  const webSource = fs.readFileSync(KEYBINDINGS_TS, "utf8");
  const mainSource = fs.readFileSync(MAIN_JS, "utf8");
  const webBindings = parseClientMenuBindings(webSource);
  const menuShortcuts = parseMenuShortcuts(mainSource);

  test("web side still declares exactly the expected clientMenu bindings", () => {
    assert.deepEqual(webBindings, {
      composer: "mod+shift+k",
      voice: "mod+shift+m",
      quickShell: "ctrl+shift+`",
    });
  });

  test("main.js declares an accelerator for each clientMenu binding, no extras", () => {
    assert.deepEqual(Object.keys(menuShortcuts).sort(), Object.keys(webBindings).sort());
  });

  test("each main.js default equals the converted web default", () => {
    for (const [id, combo] of Object.entries(webBindings)) {
      assert.equal(
        menuShortcuts[id],
        comboToAccelerator(combo),
        `menuShortcuts.${id} drifted from keybindings.ts default "${combo}"`
      );
    }
  });

  test("expected accelerators, spelled out", () => {
    assert.deepEqual(menuShortcuts, {
      composer: "CmdOrCtrl+Shift+K",
      quickShell: "Ctrl+Shift+`",
      voice: "CmdOrCtrl+Shift+M",
    });
  });
});
