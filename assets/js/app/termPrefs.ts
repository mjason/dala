/**
 * Terminal appearance preferences: font, size, line height, cursor. Stored
 * per browser (localStorage) and applied to every open terminal live via a
 * window event — they are viewer preferences, not session state.
 */
import { createStore } from "./store";

export type CursorStyle = "bar" | "block" | "underline";

export type TermPrefs = {
  /** Extra font stack put before the bundled fallback; "" = bundled font. */
  fontFamily: string;
  fontSize: number;
  lineHeight: number;
  cursorStyle: CursorStyle;
  cursorBlink: boolean;
  /** Animated (eased) wheel scrolling instead of per-tick jumps. */
  smoothScroll: boolean;
  /** Wheel distance multiplier (xterm scrollSensitivity). */
  scrollSensitivity: number;
  /** Selecting text copies it immediately (canvas text has no native copy). */
  copyOnSelect: boolean;
  /** mosh-style typeahead: printable keys render immediately, the server
   * echo is reconciled when it arrives — hides the network round-trip. */
  localEcho: boolean;
};

export const DEFAULT_PREFS: TermPrefs = {
  fontFamily: "",
  fontSize: 14,
  lineHeight: 1.2,
  cursorStyle: "bar",
  cursorBlink: true,
  smoothScroll: true,
  scrollSensitivity: 2,
  copyOnSelect: true,
  localEcho: false,
};

/** xterm smoothScrollDuration (ms) when smooth scrolling is on. */
export const SMOOTH_SCROLL_MS = 120;

export const SCROLL_SENSITIVITY_RANGE = { min: 0.5, max: 6 } as const;
export const FONT_SIZE_RANGE = { min: 10, max: 24 } as const;
export const LINE_HEIGHT_RANGE = { min: 1, max: 1.8 } as const;

const KEY = "dala:term-prefs";
const EVENT = "dala:term-prefs";

const clamp = (value: number, min: number, max: number) =>
  Math.min(Math.max(value, min), max);

function normalize(raw: Partial<TermPrefs>): TermPrefs {
  const styles: CursorStyle[] = ["bar", "block", "underline"];
  return {
    fontFamily: typeof raw.fontFamily === "string" ? raw.fontFamily : DEFAULT_PREFS.fontFamily,
    fontSize: clamp(
      Math.round(Number(raw.fontSize) || DEFAULT_PREFS.fontSize),
      FONT_SIZE_RANGE.min,
      FONT_SIZE_RANGE.max,
    ),
    lineHeight: clamp(
      Number(raw.lineHeight) || DEFAULT_PREFS.lineHeight,
      LINE_HEIGHT_RANGE.min,
      LINE_HEIGHT_RANGE.max,
    ),
    cursorStyle: styles.includes(raw.cursorStyle as CursorStyle)
      ? (raw.cursorStyle as CursorStyle)
      : DEFAULT_PREFS.cursorStyle,
    cursorBlink:
      typeof raw.cursorBlink === "boolean" ? raw.cursorBlink : DEFAULT_PREFS.cursorBlink,
    smoothScroll:
      typeof raw.smoothScroll === "boolean" ? raw.smoothScroll : DEFAULT_PREFS.smoothScroll,
    scrollSensitivity: clamp(
      Number(raw.scrollSensitivity) || DEFAULT_PREFS.scrollSensitivity,
      SCROLL_SENSITIVITY_RANGE.min,
      SCROLL_SENSITIVITY_RANGE.max,
    ),
    copyOnSelect:
      typeof raw.copyOnSelect === "boolean" ? raw.copyOnSelect : DEFAULT_PREFS.copyOnSelect,
    localEcho: typeof raw.localEcho === "boolean" ? raw.localEcho : DEFAULT_PREFS.localEcho,
  };
}

const store = createStore<TermPrefs>(KEY, DEFAULT_PREFS, normalize, { event: EVENT });

export function loadPrefs(): TermPrefs {
  return store.load();
}

export function savePrefs(patch: Partial<TermPrefs>): TermPrefs {
  return store.save(patch);
}

export function resetPrefs(): TermPrefs {
  return savePrefs({ ...DEFAULT_PREFS });
}

export function onPrefsChange(callback: (prefs: TermPrefs) => void): () => void {
  const handler = (e: Event) => callback((e as CustomEvent<TermPrefs>).detail);
  window.addEventListener(EVENT, handler);
  return () => window.removeEventListener(EVENT, handler);
}

const BUNDLED_STACK = '"JetBrainsMono NFM", monospace';

/** Full xterm font stack: the user's fonts first, bundled font as fallback. */
export function fontStack(prefs: TermPrefs): string {
  const custom = prefs.fontFamily
    .split(",")
    .map((name) => name.trim())
    .filter(Boolean)
    .map((name) => (/^["']|^[a-z-]+$/.test(name) ? name : `"${name}"`))
    .join(", ");
  return custom ? `${custom}, ${BUNDLED_STACK}` : BUNDLED_STACK;
}
