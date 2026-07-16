import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { TOKEN_TO_CSSVAR } from "./themeTokens";

// The custom-theme paths revalidate through the RPC `call` wrapper; mock it so
// getTheme outcomes are controllable and no real network is touched. Built-in
// paths never call it, so the existing tests are unaffected.
vi.mock("./rpc", () => ({ call: vi.fn() }));

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

type RpcOutcome<T> = { ok: true; data: T } | { ok: false; error: string };

// A fresh theme module wired to a controllable `call` (its next resolution is
// the getTheme outcome). Grabbed AFTER resetModules so theme.ts and this test
// share the same mocked instance.
async function freshThemeWithRpc<T>(outcome: RpcOutcome<T>) {
  vi.resetModules();
  const rpc = await import("./rpc");
  const call = vi.mocked(rpc.call);
  call.mockResolvedValue(outcome as never);
  const theme = await import("./theme");
  return { theme, call };
}

// Flush the fire-and-forget revalidation (one awaited promise + sync work).
const flush = () => new Promise((resolve) => setTimeout(resolve, 0));

const cssVar = (name: string) => document.documentElement.style.getPropertyValue(name);

beforeEach(() => {
  localStorage.clear();
  delete document.documentElement.dataset.theme;
  document.documentElement.removeAttribute("style");
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

// Seed a valid dala:theme:cache the way theme.ts writes it.
function seedCache(cache: {
  id: string;
  base: "light" | "dark";
  cssVars: Record<string, string>;
  terminal: Record<string, unknown>;
}) {
  localStorage.setItem("dala:theme:cache", JSON.stringify(cache));
}
function readStoredCache(): Record<string, unknown> | null {
  const raw = localStorage.getItem("dala:theme:cache");
  return raw ? JSON.parse(raw) : null;
}

describe("resolveTheme — custom base", () => {
  it("custom resolves to the theme's own base, not the OS", async () => {
    const { resolveTheme } = await freshTheme();
    expect(resolveTheme("custom", true, "light")).toBe("light");
    expect(resolveTheme("custom", false, "dark")).toBe("dark");
  });

  it("custom with an unknown base degrades to the system resolution", async () => {
    const { resolveTheme } = await freshTheme();
    expect(resolveTheme("custom", true, null)).toBe("dark");
    expect(resolveTheme("custom", false)).toBe("light");
  });

  it("effectiveTheme reads the custom base from a matching cache", async () => {
    stubMatchMedia(true); // OS dark — the custom base must still win
    localStorage.setItem("dala:theme", JSON.stringify({ setting: "custom", customId: "abc" }));
    seedCache({ id: "abc", base: "light", cssVars: {}, terminal: {} });
    const { effectiveTheme } = await freshTheme();
    expect(effectiveTheme()).toBe("light");
  });
});

describe("applyCustomTokens / clearCustomTokens", () => {
  it("sets the mapped --color-* vars on <html> and returns a merged ITheme", async () => {
    const { applyCustomTokens } = await freshTheme();
    const term = applyCustomTokens(
      { bg0: "#111111", diffAddFg: "#222222", cmSelection: "#333333", termBackground: "#444444", ansiRed: "#555555" },
      "dark",
    );
    expect(document.documentElement.getAttribute("data-theme")).toBe("dark");
    expect(cssVar("--color-bg0")).toBe("#111111");
    expect(cssVar("--color-diff-add-fg")).toBe("#222222");
    expect(cssVar("--color-cm-selection")).toBe("#333333");
    // term/ANSI tokens do NOT leak into CSS vars.
    expect(cssVar("--color-term-background")).toBe("");
    // The returned terminal ITheme carries the overrides; omitted keys fall back.
    expect(term.background).toBe("#444444");
    expect(term.red).toBe("#555555");
    expect(term.foreground).toBe("#d7dde3"); // dark palette fallback
  });

  it("clearCustomTokens removes EVERY mapped var (iterating the canonical map)", async () => {
    const { applyCustomTokens, clearCustomTokens } = await freshTheme();
    // Set all UI/Git/diff/cm vars.
    const fullTokens = Object.fromEntries(
      Object.keys(TOKEN_TO_CSSVAR).map((k) => [k, "#0a0a0a"]),
    );
    applyCustomTokens(fullTokens, "dark");
    for (const name of Object.values(TOKEN_TO_CSSVAR)) {
      expect(cssVar(name)).toBe("#0a0a0a");
    }
    clearCustomTokens();
    for (const name of Object.values(TOKEN_TO_CSSVAR)) {
      expect(cssVar(name)).toBe("");
    }
  });

  it("switching to a built-in setting clears the custom vars", async () => {
    stubMatchMedia(true);
    const { applyCustomTokens, saveThemeSetting, applyTheme } = await freshTheme();
    applyCustomTokens({ bg0: "#111111" }, "dark");
    expect(cssVar("--color-bg0")).toBe("#111111");
    saveThemeSetting("dark"); // leave custom for a built-in theme
    applyTheme();
    expect(cssVar("--color-bg0")).toBe(""); // fully reset — app.css owns it again
  });
});

describe("custom apply — cache instant path + revalidation", () => {
  it("cache round-trip: no cache → fetch → writes cache + paints the shell", async () => {
    stubMatchMedia(false);
    localStorage.setItem("dala:theme", JSON.stringify({ setting: "custom", customId: "abc" }));
    const { theme } = await freshThemeWithRpc({
      ok: true,
      data: { id: "abc", base: "dark", tokens: { bg0: "#123456", ansiRed: "#abcdef" } },
    });
    theme.applyTheme();
    await flush();

    // Cache written in the pre-baked form.
    const cache = readStoredCache();
    expect(cache?.id).toBe("abc");
    expect(cache?.base).toBe("dark");
    expect((cache?.cssVars as Record<string, string>)["--color-bg0"]).toBe("#123456");
    expect((cache?.terminal as Record<string, string>).red).toBe("#abcdef");
    // Shell painted from the fetched theme.
    expect(document.documentElement.getAttribute("data-theme")).toBe("dark");
    expect(cssVar("--color-bg0")).toBe("#123456");
    // Terminal palette exposed for the terminal view.
    expect(theme.currentTerminalTheme().red).toBe("#abcdef");
  });

  it("a cached custom theme paints instantly before the network resolves", async () => {
    stubMatchMedia(false);
    localStorage.setItem("dala:theme", JSON.stringify({ setting: "custom", customId: "abc" }));
    seedCache({
      id: "abc",
      base: "dark",
      cssVars: { "--color-bg0": "#0b0c0e" },
      terminal: { background: "#0b0c0e" },
    });
    // Never-resolving fetch: only the synchronous instant paint should show.
    const { theme } = await freshThemeWithRpc({ ok: false, error: "pending" });
    expect(theme.applyTheme()).toBe("dark");
    expect(document.documentElement.getAttribute("data-theme")).toBe("dark");
    expect(cssVar("--color-bg0")).toBe("#0b0c0e");
  });

  it("id mismatch: a stale cache is NOT used for the instant paint", async () => {
    stubMatchMedia(false); // OS light → fallback base is light
    localStorage.setItem("dala:theme", JSON.stringify({ setting: "custom", customId: "NEW" }));
    seedCache({
      id: "OLD",
      base: "dark",
      cssVars: { "--color-bg0": "#000000" },
      terminal: { background: "#000000" },
    });
    const { theme } = await freshThemeWithRpc({ ok: false, error: "transient" });
    theme.applyTheme();
    // The OLD cache's base/vars must NOT be painted; fall back to system (light).
    expect(document.documentElement.getAttribute("data-theme")).toBe("light");
    expect(cssVar("--color-bg0")).toBe("");
    await flush();
    // A transient fetch failure keeps the fallback (no crash, no stale apply).
    expect(cssVar("--color-bg0")).toBe("");
  });

  it("deleted theme (getTheme → null) falls the whole app back to system", async () => {
    stubMatchMedia(false); // system resolves light
    localStorage.setItem("dala:theme", JSON.stringify({ setting: "custom", customId: "abc" }));
    seedCache({
      id: "abc",
      base: "dark",
      cssVars: { "--color-bg0": "#123456" },
      terminal: { background: "#123456" },
    });
    const { theme } = await freshThemeWithRpc<null>({ ok: true, data: null });
    theme.applyTheme(); // instant paint from cache (dark)
    expect(document.documentElement.getAttribute("data-theme")).toBe("dark");
    await flush();
    // Revalidation found it deleted: setting reset, cache cleared, shell reset.
    expect(theme.loadThemeChoice()).toEqual({ setting: "system", customId: null });
    expect(readStoredCache()).toBeNull();
    expect(document.documentElement.getAttribute("data-theme")).toBe("light");
    expect(cssVar("--color-bg0")).toBe(""); // custom vars dropped
  });

  it("stale revalidation is ignored after the user switched away", async () => {
    stubMatchMedia(false);
    localStorage.setItem("dala:theme", JSON.stringify({ setting: "custom", customId: "abc" }));
    const { theme } = await freshThemeWithRpc({
      ok: true,
      data: { id: "abc", base: "dark", tokens: { bg0: "#123456" } },
    });
    theme.applyTheme();
    // User leaves custom before the fetch resolves.
    theme.saveThemeSetting("light");
    theme.applyTheme();
    await flush();
    // The in-flight custom result must not clobber the now-built-in shell.
    expect(document.documentElement.getAttribute("data-theme")).toBe("light");
    expect(cssVar("--color-bg0")).toBe("");
  });
});

describe("stored choice — customId back-compat", () => {
  it("keeps custom + a valid customId, drops an invalid one", async () => {
    localStorage.setItem("dala:theme", JSON.stringify({ setting: "custom", customId: "abc" }));
    const a = await freshTheme();
    expect(a.loadThemeChoice()).toEqual({ setting: "custom", customId: "abc" });

    localStorage.setItem("dala:theme", JSON.stringify({ setting: "custom", customId: 42 }));
    const b = await freshTheme();
    expect(b.loadThemeChoice().customId).toBeNull();
  });

  it("the old {setting:'dark'} shape normalizes to a null customId", async () => {
    localStorage.setItem("dala:theme", JSON.stringify({ setting: "dark" }));
    const { loadThemeChoice } = await freshTheme();
    expect(loadThemeChoice()).toEqual({ setting: "dark", customId: null });
  });

  it("an unknown setting still falls back to system", async () => {
    localStorage.setItem("dala:theme", JSON.stringify({ setting: "neon", customId: "abc" }));
    const { loadThemeChoice } = await freshTheme();
    expect(loadThemeChoice().setting).toBe("system");
  });
});
