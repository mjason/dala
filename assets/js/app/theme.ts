/**
 * App-wide theme controller. Scope is the WHOLE app — the UI shell (Tailwind
 * tokens in app.css) and the terminal (xterm palette) switch together.
 *
 * The stored SETTING is "system" | "light" | "dark" | "custom" (default
 * "system"), plus an optional `customId`, persisted per browser
 * (localStorage). The EFFECTIVE theme is "light" | "dark" — "system" is
 * resolved through `prefers-color-scheme`, and a custom theme resolves to its
 * own `base`. Only the effective base is ever written to `data-theme` on
 * <html>, so `[data-theme=dark]` (the app.css token overrides) stays accurate.
 *
 * Custom themes layer on top: a sparse token map (see themeTokens.ts) sets
 * inline `--color-*` styles on <html> (which beat the `[data-theme]` blocks)
 * for the UI/diff/cm groups, and feeds an xterm ITheme override for the
 * terminal groups. The currently-selected custom theme is mirrored into
 * `dala:theme:cache` so the next boot (and the no-FOUC head script) paints it
 * instantly, then revalidates against the server.
 *
 * A tiny inline script in spa_root.html.heex applies the effective theme
 * before first paint; this module re-applies on boot and keeps it in sync
 * with matchMedia (system mode), same-tab setting changes, and cross-tab
 * storage changes.
 */
import type { ITheme } from "@xterm/xterm";
import { getTheme, type GetThemeFields } from "../ash_rpc";
import { call } from "./rpc";
import { createStore } from "./store";
import { terminalTheme } from "./terminalTheme";
import {
  TOKEN_TO_CSSVAR,
  TOKEN_TO_ITHEME,
  type CssVarTokenKey,
  type IThemeTokenKey,
  type ThemeTokens,
} from "./themeTokens";

export type ThemeSetting = "system" | "light" | "dark" | "custom";
export type EffectiveTheme = "light" | "dark";

/** The stored choice: the setting plus, for "custom", which theme. */
export type ThemeChoice = { setting: ThemeSetting; customId: string | null };

const KEY = "dala:theme";
const EVENT = "dala:theme";
const CACHE_KEY = "dala:theme:cache";
const DEFAULTS: ThemeChoice = { setting: "system", customId: null };

const SETTINGS: ThemeSetting[] = ["system", "light", "dark", "custom"];

/**
 * Validate/repair the stored choice. Keeps back-compat with the old
 * `{setting:"dark"}` shape (no customId → null); an unknown setting falls
 * back to "system"; a non-string/empty customId becomes null.
 */
function normalize(raw: Partial<ThemeChoice>): ThemeChoice {
  const setting = SETTINGS.includes(raw.setting as ThemeSetting)
    ? (raw.setting as ThemeSetting)
    : DEFAULTS.setting;
  const customId =
    typeof raw.customId === "string" && raw.customId.length > 0 ? raw.customId : null;
  return { setting, customId };
}

const store = createStore<ThemeChoice>(KEY, DEFAULTS, normalize, { event: EVENT });

export function loadThemeChoice(): ThemeChoice {
  return store.load();
}

export function loadThemeSetting(): ThemeSetting {
  return store.load().setting;
}

/** Persist a built-in setting, preserving any remembered customId. */
export function saveThemeSetting(setting: ThemeSetting): ThemeSetting {
  return store.save({ setting }).setting;
}

/** Persist a full choice (the setter the appearance UI drives in 1b). */
export function saveThemeChoice(
  setting: ThemeSetting,
  customId: string | null = null,
): ThemeChoice {
  return store.save({ setting, customId });
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

/**
 * Pure resolver: setting + system preference → effective theme. For "custom"
 * the effective base is the custom theme's own base (`customBase`, read from
 * the applied cache); when it is unknown we degrade to the system resolution.
 */
export function resolveTheme(
  setting: ThemeSetting,
  systemDark: boolean,
  customBase?: EffectiveTheme | null,
): EffectiveTheme {
  if (setting === "light") return "light";
  if (setting === "dark") return "dark";
  if (setting === "custom") return customBase ?? (systemDark ? "dark" : "light");
  return systemDark ? "dark" : "light";
}

/** The effective theme right now (stored choice resolved against the OS). */
export function effectiveTheme(): EffectiveTheme {
  const prefs = store.load();
  if (prefs.setting === "custom") {
    const cache = readCache();
    const base = cache && cache.id === prefs.customId ? cache.base : null;
    return resolveTheme("custom", systemPrefersDark(), base);
  }
  return resolveTheme(prefs.setting, systemPrefersDark());
}

// ---- Custom-theme cache (dala:theme:cache) ---------------------------------
// Only the currently-selected custom theme, in a pre-baked form the boot path
// and the no-FOUC head script can paint without any token→target conversion.

type ThemeCache = {
  id: string;
  base: EffectiveTheme;
  cssVars: Record<string, string>;
  terminal: ITheme;
};

function readCache(): ThemeCache | null {
  try {
    const raw = localStorage.getItem(CACHE_KEY);
    if (!raw) return null;
    const parsed = JSON.parse(raw) as Partial<ThemeCache> | null;
    if (
      !parsed ||
      typeof parsed.id !== "string" ||
      (parsed.base !== "light" && parsed.base !== "dark") ||
      typeof parsed.cssVars !== "object" ||
      parsed.cssVars === null ||
      typeof parsed.terminal !== "object" ||
      parsed.terminal === null
    ) {
      return null;
    }
    return parsed as ThemeCache;
  } catch {
    return null;
  }
}

function writeCache(cache: ThemeCache): void {
  try {
    localStorage.setItem(CACHE_KEY, JSON.stringify(cache));
  } catch {
    // storage unavailable — the in-memory apply already happened
  }
}

function clearCache(): void {
  try {
    localStorage.removeItem(CACHE_KEY);
  } catch {
    // ignore
  }
}

// ---- Token → target conversions --------------------------------------------

/** Present UI/diff/cm tokens → `{ "--color-…": value }`. */
function tokensToCssVars(tokens: ThemeTokens): Record<string, string> {
  const out: Record<string, string> = {};
  for (const key of Object.keys(TOKEN_TO_CSSVAR) as CssVarTokenKey[]) {
    const value = tokens[key];
    if (value != null) out[TOKEN_TO_CSSVAR[key]] = value;
  }
  return out;
}

/** Present term/ANSI tokens → an xterm ITheme override object. The mapped
 * fields are all string-valued color slots, so a plain string record is a
 * sound Partial<ITheme>. */
function tokensToITheme(tokens: ThemeTokens): Partial<ITheme> {
  const out: Record<string, string> = {};
  for (const key of Object.keys(TOKEN_TO_ITHEME) as IThemeTokenKey[]) {
    const value = tokens[key];
    if (value != null) out[TOKEN_TO_ITHEME[key]] = value;
  }
  return out as Partial<ITheme>;
}

function buildCache(id: string, base: EffectiveTheme, tokens: ThemeTokens): ThemeCache {
  return {
    id,
    base,
    cssVars: tokensToCssVars(tokens),
    terminal: terminalTheme(base, tokensToITheme(tokens)),
  };
}

function cacheEqual(a: ThemeCache | null, b: ThemeCache | null): boolean {
  return JSON.stringify(a) === JSON.stringify(b);
}

// ---- DOM apply -------------------------------------------------------------

// The fields custom tokens can touch — enough to detect a terminal palette
// flip (Object.values order is stable for a given object literal).
const TERM_SIGNATURE_FIELDS = Object.values(TOKEN_TO_ITHEME);

function termSignature(theme: ITheme): string {
  return TERM_SIGNATURE_FIELDS.map((field) => theme[field] ?? "").join(",");
}

/**
 * Remove EVERY custom `--color-*` inline override (iterating the canonical
 * map, not "what we last set"), so switching back to a built-in theme lets
 * the app.css `[data-theme]` blocks fully own the shell again. Called on the
 * built-in path and before painting a (possibly different) custom theme.
 */
export function clearCustomTokens(): void {
  if (typeof document === "undefined") return;
  const root = document.documentElement;
  for (const cssvar of Object.values(TOKEN_TO_CSSVAR)) {
    root.style.removeProperty(cssvar);
  }
}

/** Set `data-theme` and the present custom `--color-*` inline styles. */
function paintCustomVars(base: EffectiveTheme, cssVars: Record<string, string>): void {
  if (typeof document === "undefined") return;
  const root = document.documentElement;
  clearCustomTokens();
  root.setAttribute("data-theme", base);
  for (const [name, value] of Object.entries(cssVars)) {
    root.style.setProperty(name, value);
  }
}

/**
 * Apply a sparse custom token map at the given base: set `data-theme` + the
 * present `--color-*` inline overrides, then hand the terminal its ITheme
 * (base palette + present term/ANSI overrides). Returns the terminal ITheme.
 */
export function applyCustomTokens(tokens: ThemeTokens, base: EffectiveTheme): ITheme {
  paintCustomVars(base, tokensToCssVars(tokens));
  const terminal = terminalTheme(base, tokensToITheme(tokens));
  commit(base, terminal);
  return terminal;
}

function applyCache(cache: ThemeCache): EffectiveTheme {
  paintCustomVars(cache.base, cache.cssVars);
  return commit(cache.base, cache.terminal);
}

/**
 * Pre-bake and store the boot cache for a custom theme. Called right after a
 * create/update so selecting the theme paints instantly from cache (no
 * fallback-to-base flash, no wait for the first server revalidation) and the
 * next reload's no-FOUC head script already has it.
 */
export function cacheCustomTheme(id: string, base: EffectiveTheme, tokens: ThemeTokens): void {
  writeCache(buildCache(id, base, tokens));
}

// ---- Effective-theme commit + subscribers ----------------------------------

// Live subscribers (the terminal re-colors, settings UI reflects) plus the
// last applied signature (base + terminal palette) so we only notify on an
// actual change — either the shell base or the terminal colors.
const listeners = new Set<(theme: EffectiveTheme) => void>();
let appliedSig: string | null = null;
let currentTerm: ITheme | null = null;

/** Inside the desktop client, mirror the effective theme to the shell so the
 * native window chrome/background follows the page (best effort; web no-op). */
function reportThemeToClient(theme: EffectiveTheme) {
  const bridge = (
    window as { dala?: { invoke: (cmd: string, args: unknown) => Promise<unknown> } }
  ).dala;
  if (bridge) void bridge.invoke("set_theme", { theme }).catch(() => undefined);
}

/**
 * Write the effective base to <html data-theme>, remember the terminal
 * ITheme, and notify subscribers + the desktop client only when the base or
 * the terminal palette actually changed. Returns the effective base.
 */
function commit(base: EffectiveTheme, terminal: ITheme): EffectiveTheme {
  if (typeof document !== "undefined") {
    document.documentElement.dataset.theme = base;
  }
  currentTerm = terminal;
  const sig = `${base}|${termSignature(terminal)}`;
  if (sig !== appliedSig) {
    appliedSig = sig;
    reportThemeToClient(base);
    for (const cb of listeners) cb(base);
  }
  return base;
}

/** The xterm theme object for the effective theme right now — the custom
 * palette when a custom theme is applied, else the built-in base palette. */
export function currentTerminalTheme(): ITheme {
  return currentTerm ?? terminalTheme(effectiveTheme());
}

/** Subscribe to effective-theme changes (base flip OR custom palette swap).
 * The callback receives the effective base; read the terminal palette via
 * currentTerminalTheme(). Returns an unsubscribe function. */
export function onThemeChange(cb: (theme: EffectiveTheme) => void): () => void {
  listeners.add(cb);
  return () => listeners.delete(cb);
}

// ---- Apply entry points ----------------------------------------------------

/** Resolve and apply the effective theme. Built-in paths are synchronous;
 * the custom path paints instantly (from cache when possible) and revalidates
 * against the server in the background. Returns the effective base. */
export function applyTheme(): EffectiveTheme {
  const prefs = store.load();
  if (prefs.setting === "custom") return applyCustom(prefs.customId);
  // Built-in light/dark/system: drop any custom overrides so the app.css
  // blocks own the shell again, then resolve + apply.
  clearCustomTokens();
  const base = resolveTheme(prefs.setting, systemPrefersDark());
  return commit(base, terminalTheme(base));
}

function applyCustom(customId: string | null): EffectiveTheme {
  const cache = readCache();
  if (customId && cache && cache.id === customId) {
    // Instant paint from the cache, then revalidate against the server.
    const base = applyCache(cache);
    void refreshCustom(customId);
    return base;
  }
  // No usable cache: we don't know the custom base yet, so paint a brief base
  // fallback (system-resolved), then fetch the theme and re-apply. With no id
  // there is nothing to fetch — stay on the fallback.
  clearCustomTokens();
  const base = resolveTheme("custom", systemPrefersDark(), null);
  const applied = commit(base, terminalTheme(base));
  if (customId) void refreshCustom(customId);
  return applied;
}

const THEME_FIELDS = ["id", "base", "tokens"] as unknown as GetThemeFields;

type CustomThemeRow = { id: string; base: EffectiveTheme; tokens: ThemeTokens };

/** Fetch the custom theme and re-apply if it changed; a deleted theme
 * (getTheme → null) falls the whole app back to the system setting. */
async function refreshCustom(customId: string): Promise<void> {
  const result = await call<CustomThemeRow | null>(getTheme, {
    input: { id: customId },
    fields: THEME_FIELDS,
  });
  // Transient/network failure — keep whatever we already painted.
  if (!result.ok) return;
  if (result.data == null) {
    // Deleted server-side: forget it and fall back to system.
    resetToSystem();
    return;
  }
  // The choice may have changed while the fetch was in flight.
  const prefs = store.load();
  if (prefs.setting !== "custom" || prefs.customId !== customId) return;
  const next = buildCache(result.data.id, result.data.base, result.data.tokens);
  if (cacheEqual(next, readCache())) return;
  writeCache(next);
  applyCache(next);
}

function resetToSystem(): void {
  clearCache();
  store.save({ setting: "system", customId: null });
  applyTheme();
}

/** Boot the controller: apply once, then track the sources that can change
 * the effective theme — the OS scheme (system mode only), same-tab setting
 * changes, and other tabs on this device. */
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
