/**
 * App-wide light/dark theme controller. Scope is the WHOLE app — the UI
 * shell (Tailwind tokens in app.css) and the terminal (xterm palette) switch
 * together.
 *
 * The stored SETTING is "system" | "light" | "dark" (default "system"),
 * persisted per browser (localStorage, same idiom as termPrefs). The
 * EFFECTIVE theme is "light" | "dark" — "system" is resolved through
 * `prefers-color-scheme`. Only the effective theme is ever written to
 * `data-theme` on <html>, so `[data-theme=dark]` (daisyUI's dark variant,
 * the token overrides) is always accurate, and there is no ambiguous
 * "system" attribute to reason about at the CSS layer.
 *
 * A tiny inline script in spa_root.html.heex applies the effective theme
 * before first paint (no dark flash on a light-preferring OS); this module
 * re-applies on boot and keeps it in sync with matchMedia (system mode),
 * same-tab setting changes, and cross-tab storage changes.
 */
import { createStore } from "./store";

export type ThemeSetting = "system" | "light" | "dark";
export type EffectiveTheme = "light" | "dark";

type ThemePrefs = { setting: ThemeSetting };

const KEY = "dala:theme";
const EVENT = "dala:theme";
const DEFAULTS: ThemePrefs = { setting: "system" };

const SETTINGS: ThemeSetting[] = ["system", "light", "dark"];

function normalize(raw: Partial<ThemePrefs>): ThemePrefs {
  return {
    setting: SETTINGS.includes(raw.setting as ThemeSetting)
      ? (raw.setting as ThemeSetting)
      : DEFAULTS.setting,
  };
}

const store = createStore<ThemePrefs>(KEY, DEFAULTS, normalize, { event: EVENT });

export function loadThemeSetting(): ThemeSetting {
  return store.load().setting;
}

export function saveThemeSetting(setting: ThemeSetting): ThemeSetting {
  return store.save({ setting }).setting;
}

/** True when the OS/browser prefers a dark color scheme. Dark-first when
 * matchMedia is unavailable — this app has always been dark. */
export function systemPrefersDark(): boolean {
  try {
    return window.matchMedia("(prefers-color-scheme: dark)").matches;
  } catch {
    return true;
  }
}

/** Pure resolver: setting + system preference → effective theme. */
export function resolveTheme(setting: ThemeSetting, systemDark: boolean): EffectiveTheme {
  if (setting === "light") return "light";
  if (setting === "dark") return "dark";
  return systemDark ? "dark" : "light";
}

/** The effective theme right now (stored setting resolved against the OS). */
export function effectiveTheme(): EffectiveTheme {
  return resolveTheme(loadThemeSetting(), systemPrefersDark());
}

// Live subscribers (the terminal re-colors, settings UI reflects) plus the
// last applied effective value, so we only notify on an actual flip.
const listeners = new Set<(theme: EffectiveTheme) => void>();
let applied: EffectiveTheme | null = null;

/** Inside the desktop client, mirror the effective theme to the shell so the
 * native window chrome/background follows the page (best effort; web no-op). */
function reportThemeToClient(theme: EffectiveTheme) {
  const bridge = (
    window as { dala?: { invoke: (cmd: string, args: unknown) => Promise<unknown> } }
  ).dala;
  if (bridge) void bridge.invoke("set_theme", { theme }).catch(() => undefined);
}

/** Resolve and write the effective theme to <html data-theme>, notifying
 * subscribers and the desktop client only when it actually changed. Returns
 * the effective theme. */
export function applyTheme(): EffectiveTheme {
  const theme = effectiveTheme();
  if (typeof document !== "undefined") {
    document.documentElement.dataset.theme = theme;
  }
  if (theme !== applied) {
    applied = theme;
    reportThemeToClient(theme);
    for (const cb of listeners) cb(theme);
  }
  return theme;
}

/** Subscribe to effective-theme flips. Returns an unsubscribe function. */
export function onThemeChange(cb: (theme: EffectiveTheme) => void): () => void {
  listeners.add(cb);
  return () => listeners.delete(cb);
}

/** Boot the controller: apply once, then track the sources that can change
 * the effective theme — the OS scheme (system mode only), same-tab setting
 * changes, and other tabs on this device. Idempotent listeners are fine to
 * register once at startup. */
export function initTheme(): void {
  applyTheme();

  try {
    const mq = window.matchMedia("(prefers-color-scheme: dark)");
    // Only affects "system" mode; applyTheme re-resolves and no-ops otherwise.
    mq.addEventListener?.("change", () => applyTheme());
  } catch {
    // matchMedia unavailable — the stored setting still resolves.
  }

  // Same-tab: the settings UI saves through the store, which broadcasts EVENT.
  window.addEventListener(EVENT, () => applyTheme());
  // Cross-tab: another tab on this device changed the stored setting.
  window.addEventListener("storage", (e) => {
    if (e.key === KEY) applyTheme();
  });
}
