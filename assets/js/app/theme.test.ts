import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

// Controllable matchMedia: a single MediaQueryList whose `matches` can be
// flipped, firing any registered change listeners (jsdom has no media engine).
function stubMatchMedia(prefersDark: boolean) {
  const listeners = new Set<(e: MediaQueryListEvent) => void>();
  const mql = {
    matches: prefersDark,
    media: "(prefers-color-scheme: dark)",
    onchange: null,
    addEventListener: (_type: string, cb: (e: MediaQueryListEvent) => void) => listeners.add(cb),
    removeEventListener: (_type: string, cb: (e: MediaQueryListEvent) => void) =>
      listeners.delete(cb),
    addListener: (cb: (e: MediaQueryListEvent) => void) => listeners.add(cb),
    removeListener: (cb: (e: MediaQueryListEvent) => void) => listeners.delete(cb),
    dispatchEvent: () => true,
  };
  vi.stubGlobal("matchMedia", vi.fn(() => mql));
  return {
    set(dark: boolean) {
      mql.matches = dark;
      listeners.forEach((cb) => cb({ matches: dark } as MediaQueryListEvent));
    },
  };
}

// Fresh module per test — theme.ts keeps module-level applied/listeners state.
async function freshTheme() {
  vi.resetModules();
  return import("./theme");
}

beforeEach(() => {
  localStorage.clear();
  delete document.documentElement.dataset.theme;
  delete (window as { dala?: unknown }).dala;
});

afterEach(() => {
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});

describe("resolveTheme (pure)", () => {
  it("system follows the OS scheme", async () => {
    const { resolveTheme } = await freshTheme();
    expect(resolveTheme("system", true)).toBe("dark");
    expect(resolveTheme("system", false)).toBe("light");
  });

  it("an explicit setting always wins over the OS scheme", async () => {
    const { resolveTheme } = await freshTheme();
    expect(resolveTheme("light", true)).toBe("light");
    expect(resolveTheme("dark", false)).toBe("dark");
  });
});

describe("stored setting", () => {
  it("defaults to system and persists valid settings", async () => {
    const { loadThemeSetting, saveThemeSetting } = await freshTheme();
    expect(loadThemeSetting()).toBe("system");
    saveThemeSetting("light");
    expect(loadThemeSetting()).toBe("light");
    saveThemeSetting("dark");
    expect(loadThemeSetting()).toBe("dark");
  });

  it("falls back to system on a garbage stored value", async () => {
    localStorage.setItem("dala:theme", JSON.stringify({ setting: "chartreuse" }));
    const { loadThemeSetting } = await freshTheme();
    expect(loadThemeSetting()).toBe("system");

    localStorage.setItem("dala:theme", "not json{");
    const again = await freshTheme();
    expect(again.loadThemeSetting()).toBe("system");
  });
});

describe("effectiveTheme", () => {
  it("resolves the stored setting against the OS", async () => {
    stubMatchMedia(true);
    const { effectiveTheme, saveThemeSetting } = await freshTheme();
    expect(effectiveTheme()).toBe("dark"); // system + OS dark
    saveThemeSetting("light");
    expect(effectiveTheme()).toBe("light"); // explicit wins
  });

  it("defaults to dark when matchMedia is unavailable", async () => {
    vi.stubGlobal("matchMedia", undefined);
    const { effectiveTheme } = await freshTheme();
    expect(effectiveTheme()).toBe("dark");
  });
});

describe("applyTheme", () => {
  it("writes the effective theme to <html data-theme>", async () => {
    stubMatchMedia(false); // OS light
    const { applyTheme } = await freshTheme();
    expect(applyTheme()).toBe("light");
    expect(document.documentElement.dataset.theme).toBe("light");
  });

  it("notifies subscribers only on an actual flip", async () => {
    const media = stubMatchMedia(true);
    const { applyTheme, onThemeChange } = await freshTheme();
    const seen = vi.fn();
    onThemeChange(seen);

    applyTheme(); // dark (first apply is a change from null)
    expect(seen).toHaveBeenLastCalledWith("dark");
    applyTheme(); // still dark — no new notification
    expect(seen).toHaveBeenCalledTimes(1);

    media.set(false); // OS → light, but only matters once applyTheme re-runs
    applyTheme();
    expect(seen).toHaveBeenLastCalledWith("light");
    expect(seen).toHaveBeenCalledTimes(2);
  });

  it("reports the effective theme to the desktop client bridge", async () => {
    stubMatchMedia(false);
    const invoke = vi.fn().mockResolvedValue(undefined);
    (window as { dala?: { invoke: typeof invoke } }).dala = { invoke };
    const { applyTheme } = await freshTheme();
    applyTheme();
    expect(invoke).toHaveBeenCalledWith("set_theme", { theme: "light" });
  });
});

describe("initTheme", () => {
  it("reacts to an OS scheme change while in system mode", async () => {
    const media = stubMatchMedia(true);
    const { initTheme } = await freshTheme();
    initTheme();
    expect(document.documentElement.dataset.theme).toBe("dark");

    media.set(false); // OS flips to light
    expect(document.documentElement.dataset.theme).toBe("light");
  });

  it("ignores OS changes when a manual override is set", async () => {
    const media = stubMatchMedia(true);
    const { initTheme, saveThemeSetting } = await freshTheme();
    saveThemeSetting("dark");
    initTheme();
    expect(document.documentElement.dataset.theme).toBe("dark");

    media.set(false); // OS light, but override is dark
    expect(document.documentElement.dataset.theme).toBe("dark");
  });

  it("re-applies when the setting changes in the same tab", async () => {
    stubMatchMedia(true);
    const { initTheme, saveThemeSetting } = await freshTheme();
    initTheme();
    expect(document.documentElement.dataset.theme).toBe("dark");
    saveThemeSetting("light"); // broadcasts dala:theme → controller re-applies
    expect(document.documentElement.dataset.theme).toBe("light");
  });

  it("switching a manual override back to system re-follows the OS live", async () => {
    const media = stubMatchMedia(false); // OS light
    const { initTheme, saveThemeSetting } = await freshTheme();
    saveThemeSetting("dark");
    initTheme();
    expect(document.documentElement.dataset.theme).toBe("dark"); // override wins

    saveThemeSetting("system"); // back to follow-OS → re-resolves against light
    expect(document.documentElement.dataset.theme).toBe("light");

    media.set(true); // and keeps tracking the OS: dark again, no reconfigure
    expect(document.documentElement.dataset.theme).toBe("dark");
  });

  it("re-applies when another tab changes the setting (storage event)", async () => {
    stubMatchMedia(true); // OS dark
    const { initTheme } = await freshTheme();
    initTheme();
    expect(document.documentElement.dataset.theme).toBe("dark");

    // Another tab on this device wrote a light override; the browser fires a
    // cross-tab `storage` event for our key → the controller re-applies.
    localStorage.setItem("dala:theme", JSON.stringify({ setting: "light" }));
    window.dispatchEvent(new StorageEvent("storage", { key: "dala:theme" }));
    expect(document.documentElement.dataset.theme).toBe("light");

    // A storage event for some other key must not disturb the theme.
    localStorage.setItem("dala:theme", JSON.stringify({ setting: "dark" }));
    window.dispatchEvent(new StorageEvent("storage", { key: "unrelated" }));
    expect(document.documentElement.dataset.theme).toBe("light");
  });
});

// The no-FOUC inline <script> in spa_root.html.heex resolves the theme before
// first paint. It must run inline (pre-bundle) so it cannot be imported and
// unit-tested directly; instead we pin the SAME resolve branches on theme.ts's
// pure functions — the values the controller maintains once the bundle boots —
// so the head script and the module cannot silently diverge. LIMITATION: this
// asserts parity of the logic, not that the HEEx string itself is byte-correct.
describe("no-FOUC head-script parity (spa_root.html.heex)", () => {
  it("garbage or missing stored value resolves as system → follows the OS", async () => {
    localStorage.setItem("dala:theme", JSON.stringify({ setting: "chartreuse" }));
    stubMatchMedia(false); // OS light
    const { loadThemeSetting, effectiveTheme } = await freshTheme();
    expect(loadThemeSetting()).toBe("system");
    expect(effectiveTheme()).toBe("light");
  });

  it("system honors the matchMedia light/dark branch; missing matchMedia → dark", async () => {
    const { resolveTheme } = await freshTheme();
    expect(resolveTheme("system", true)).toBe("dark");
    expect(resolveTheme("system", false)).toBe("light");

    vi.stubGlobal("matchMedia", undefined);
    const again = await freshTheme();
    expect(again.effectiveTheme()).toBe("dark"); // no matchMedia → dark, like the head script's catch
  });

  it("an explicit stored light/dark is honored over the OS scheme", async () => {
    stubMatchMedia(true); // OS dark
    const { saveThemeSetting, effectiveTheme } = await freshTheme();
    saveThemeSetting("light");
    expect(effectiveTheme()).toBe("light");
  });
});
