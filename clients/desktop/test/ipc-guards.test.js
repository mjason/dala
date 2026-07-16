const { test, describe } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const main = fs.readFileSync(path.join(__dirname, "../main.js"), "utf8");

function handlerBody(name) {
  const start = main.indexOf(`ipcMain.handle("${name}"`);
  assert.notEqual(start, -1, `handler ${name} present`);
  // Up to the next handler registration (good enough for these small bodies).
  const rest = main.slice(start + 1);
  const next = rest.indexOf("ipcMain.handle(");
  return rest.slice(0, next === -1 ? undefined : next);
}

describe("shell window navigation is pinned to its own origin", () => {
  test("createShellWindow installs a will-navigate guard routing off-origin out", () => {
    const start = main.indexOf("function createShellWindow");
    const body = main.slice(start, main.indexOf("\nfunction ", start + 1));
    assert.match(body, /webContents\.on\("will-navigate"/);
    assert.match(body, /sameOrigin\(url, win\.serverUrl\)/);
    assert.match(body, /event\.preventDefault\(\)/);
    assert.match(body, /openBrowserWindow\(url\)/);
  });

  test("sameOrigin compares URL origins and is safe on bad input", () => {
    assert.match(main, /function sameOrigin\(a, b\)/);
    assert.match(main, /new URL\(a\)\.origin === new URL\(b\)\.origin/);
  });
});

describe("sensitive bridge calls require the server page's own frame", () => {
  test("serverFrame checks shell window + top frame + same origin", () => {
    assert.match(main, /function serverFrame\(event\)/);
    assert.match(main, /win\.isDalaShell/);
    assert.match(main, /event\.sender === win\.webContents/);
    assert.match(main, /sameOrigin\(frameUrl, win\.serverUrl\)/);
  });

  test("open_external, clip_write, notify all assert the server frame", () => {
    assert.match(handlerBody("open_external"), /assertServerFrame\(event\)/);
    assert.match(handlerBody("clip_write"), /assertServerFrame\(event\)/);
    assert.match(handlerBody("notify"), /assertServerFrame\(event\)/);
  });

  test("open_external still refuses non-http(s) targets", () => {
    assert.match(handlerBody("open_external"), /httpUrl\(url\)/);
  });
});

describe("set_shortcuts is server-frame-gated and accelerator-validated", () => {
  test("gated on serverFrame and only accepts validated accelerators", () => {
    const body = handlerBody("set_shortcuts");
    assert.match(body, /if \(!serverFrame\(event\)\) return/);
    assert.match(body, /validAccelerator\(value\)/);
  });

  test("validAccelerator rejects bare CmdOrCtrl edit/system keys but keeps real combos", () => {
    // Extract the function and eval it in isolation (pure, no electron deps).
    const src = main.slice(main.indexOf("const ACCEL_RE"), main.indexOf("// Shared window-open policy"));
    const validAccelerator = new Function(`${src}; return validAccelerator;`)();
    for (const good of ["CmdOrCtrl+Shift+K", "Ctrl+Shift+`", "CmdOrCtrl+Shift+M", "Alt+Shift+F5"]) {
      assert.equal(validAccelerator(good), true, good);
    }
    for (const bad of ["CmdOrCtrl+C", "CmdOrCtrl+V", "CmdOrCtrl+Q", "CmdOrCtrl+W", "F", "", "not-an-accel", 42]) {
      assert.equal(validAccelerator(bad), false, String(bad));
    }
  });
});
