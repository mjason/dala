const { test, describe } = require("node:test");
const assert = require("node:assert/strict");

const { THEME_BG, normalizeTheme, backgroundFor, coldStartTheme, applyTheme } = require("../src/theme");

// A stand-in for a BrowserWindow: records the last setBackgroundColor call.
function fakeWindow(opts = {}) {
  return {
    isDalaShell: opts.isDalaShell ?? true,
    _destroyed: opts.destroyed ?? false,
    bg: null,
    isDestroyed() {
      return this._destroyed;
    },
    setBackgroundColor(color) {
      this.bg = color;
    },
  };
}

describe("normalizeTheme", () => {
  test("accepts the two effective themes, rejects everything else", () => {
    assert.equal(normalizeTheme("light"), "light");
    assert.equal(normalizeTheme("dark"), "dark");
    assert.equal(normalizeTheme("system"), null);
    assert.equal(normalizeTheme(""), null);
    assert.equal(normalizeTheme(undefined), null);
    assert.equal(normalizeTheme(42), null);
  });
});

describe("backgroundFor", () => {
  test("maps themes to the app bg0 hex, dark for unknown input", () => {
    assert.equal(backgroundFor("light"), THEME_BG.light);
    assert.equal(backgroundFor("dark"), THEME_BG.dark);
    assert.equal(backgroundFor("nonsense"), THEME_BG.dark);
  });
});

describe("coldStartTheme", () => {
  test("follows the OS scheme so the first window doesn't flash the wrong shade", () => {
    // A light-preferring OS must cold-start light, not the old hardcoded dark.
    assert.equal(coldStartTheme({ shouldUseDarkColors: false }), "light");
    assert.equal(coldStartTheme({ shouldUseDarkColors: true }), "dark");
  });

  test("defaults to dark when nativeTheme is unavailable", () => {
    assert.equal(coldStartTheme(undefined), "dark");
    assert.equal(coldStartTheme(null), "dark");
  });

  test("the cold-start theme maps to a real window background", () => {
    // Guards the whole cold-start seam: OS scheme → theme → window bg.
    assert.equal(backgroundFor(coldStartTheme({ shouldUseDarkColors: false })), THEME_BG.light);
    assert.equal(backgroundFor(coldStartTheme({ shouldUseDarkColors: true })), THEME_BG.dark);
  });
});

describe("applyTheme", () => {
  test("sets nativeTheme.themeSource and repaints shell windows", () => {
    const nativeTheme = { themeSource: "system" };
    const shell = fakeWindow();

    const applied = applyTheme(nativeTheme, [shell], "light");

    assert.equal(applied, "light");
    assert.equal(nativeTheme.themeSource, "light");
    assert.equal(shell.bg, THEME_BG.light);
  });

  test("switching back to dark updates both source and background", () => {
    const nativeTheme = { themeSource: "light" };
    const shell = fakeWindow();
    applyTheme(nativeTheme, [shell], "dark");
    assert.equal(nativeTheme.themeSource, "dark");
    assert.equal(shell.bg, THEME_BG.dark);
  });

  test("ignores invalid themes without touching the shell", () => {
    const nativeTheme = { themeSource: "dark" };
    const shell = fakeWindow();
    const applied = applyTheme(nativeTheme, [shell], "system");
    assert.equal(applied, null);
    assert.equal(nativeTheme.themeSource, "dark");
    assert.equal(shell.bg, null);
  });

  test("skips destroyed windows and non-shell (external browser) windows", () => {
    const nativeTheme = { themeSource: "dark" };
    const destroyed = fakeWindow({ destroyed: true });
    const external = fakeWindow({ isDalaShell: false });
    const shell = fakeWindow();

    applyTheme(nativeTheme, [destroyed, external, shell, null], "light");

    assert.equal(destroyed.bg, null);
    assert.equal(external.bg, null);
    assert.equal(shell.bg, THEME_BG.light);
  });
});
