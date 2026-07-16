/**
 * The single shared contract for custom themes: the 46 design tokens a
 * CustomTheme may override, and how each token maps onto a render target.
 *
 * Two disjoint groups partition the 46 keys:
 *  - 25 UI / Git / diff / CodeMirror tokens → app.css `--color-*` custom properties,
 *    applied as inline styles on <html> so a custom value beats the
 *    `[data-theme]` blocks (TOKEN_TO_CSSVAR).
 *  - 21 terminal tokens (5 base + 16 ANSI) → xterm ITheme fields
 *    (TOKEN_TO_ITHEME).
 *
 * The server stores `tokens` SPARSELY — an omitted key falls back to the
 * theme's base palette (built-in light/dark). These camelCase key names are
 * the wire contract with the Ash resource; they must match verbatim.
 */
import type { ITheme } from "@xterm/xterm";

/** UI shell tokens → Tailwind `@theme` custom properties in app.css. */
export const UI_KEYS = [
  "bg0",
  "bg1",
  "bg2",
  "line",
  "fg",
  "fgMuted",
  "mint",
  "danger",
] as const;

/** Git file-state tokens → `--color-git-*`. */
export const GIT_KEYS = [
  "gitAdded",
  "gitModified",
  "gitDeleted",
  "gitRenamed",
  "gitUntracked",
  "gitConflict",
  "gitIgnored",
] as const;

/** Diff signal tokens → `--color-diff-*` (app.css :root). */
export const DIFF_KEYS = ["diffAddFg", "diffDelFg", "diffHunk", "diffAddBg", "diffDelBg"] as const;

/** CodeMirror chrome tokens → `--color-cm-*` (app.css :root). */
export const CM_KEYS = [
  "cmGutterBg",
  "cmGutterFg",
  "cmActiveBg",
  "cmHunkBg",
  "cmSelection",
] as const;

/** Terminal base tokens → xterm ITheme base fields. */
export const TERM_BASE_KEYS = [
  "termBackground",
  "termForeground",
  "termCursor",
  "termCursorAccent",
  "termSelectionBackground",
] as const;

/** The 16 ANSI tokens → xterm ITheme color fields. */
export const ANSI_KEYS = [
  "ansiBlack",
  "ansiRed",
  "ansiGreen",
  "ansiYellow",
  "ansiBlue",
  "ansiMagenta",
  "ansiCyan",
  "ansiWhite",
  "ansiBrightBlack",
  "ansiBrightRed",
  "ansiBrightGreen",
  "ansiBrightYellow",
  "ansiBrightBlue",
  "ansiBrightMagenta",
  "ansiBrightCyan",
  "ansiBrightWhite",
] as const;

/** All 46 token keys, in a stable group order. */
export const TOKEN_KEYS = [
  ...UI_KEYS,
  ...GIT_KEYS,
  ...DIFF_KEYS,
  ...CM_KEYS,
  ...TERM_BASE_KEYS,
  ...ANSI_KEYS,
] as const;

export type TokenKey = (typeof TOKEN_KEYS)[number];

/** The 24 keys backed by a `--color-*` CSS variable (UI + Git + diff + cm). */
export type CssVarTokenKey =
  | (typeof UI_KEYS)[number]
  | (typeof GIT_KEYS)[number]
  | (typeof DIFF_KEYS)[number]
  | (typeof CM_KEYS)[number];

/** The 21 keys backed by an xterm ITheme field (term base + ANSI). */
export type IThemeTokenKey = (typeof TERM_BASE_KEYS)[number] | (typeof ANSI_KEYS)[number];

/**
 * A sparse token override map — the server `tokens` column and the shape the
 * client applies. Omitted keys fall back to the base palette.
 */
export type ThemeTokens = Partial<Record<TokenKey, string>>;

/**
 * The 25 UI / Git / diff / cm tokens → their EXACT app.css `--color-*` names.
 * Verified against assets/css/app.css. Inline styles set from this map on
 * <html> beat the `[data-theme]` token blocks, so a custom value always wins.
 */
export const TOKEN_TO_CSSVAR: Record<CssVarTokenKey, `--color-${string}`> = {
  // UI (@theme block)
  bg0: "--color-bg0",
  bg1: "--color-bg1",
  bg2: "--color-bg2",
  line: "--color-line",
  fg: "--color-fg",
  fgMuted: "--color-fg-muted",
  mint: "--color-mint",
  danger: "--color-danger",
  // Git states
  gitAdded: "--color-git-added",
  gitModified: "--color-git-modified",
  gitDeleted: "--color-git-deleted",
  gitRenamed: "--color-git-renamed",
  gitUntracked: "--color-git-untracked",
  gitConflict: "--color-git-conflict",
  gitIgnored: "--color-git-ignored",
  // diff signals (:root)
  diffAddFg: "--color-diff-add-fg",
  diffDelFg: "--color-diff-del-fg",
  diffHunk: "--color-diff-hunk",
  diffAddBg: "--color-diff-add-bg",
  diffDelBg: "--color-diff-del-bg",
  // CodeMirror chrome (:root)
  cmGutterBg: "--color-cm-gutter-bg",
  cmGutterFg: "--color-cm-gutter-fg",
  cmActiveBg: "--color-cm-active-bg",
  cmHunkBg: "--color-cm-hunk-bg",
  cmSelection: "--color-cm-selection",
};

/**
 * The 21 terminal tokens → their xterm ITheme field names. Verified against
 * assets/js/app/terminalTheme.ts and TerminalView's `theme` object.
 */
export const TOKEN_TO_ITHEME: Record<IThemeTokenKey, keyof ITheme> = {
  // term base
  termBackground: "background",
  termForeground: "foreground",
  termCursor: "cursor",
  termCursorAccent: "cursorAccent",
  termSelectionBackground: "selectionBackground",
  // ANSI
  ansiBlack: "black",
  ansiRed: "red",
  ansiGreen: "green",
  ansiYellow: "yellow",
  ansiBlue: "blue",
  ansiMagenta: "magenta",
  ansiCyan: "cyan",
  ansiWhite: "white",
  ansiBrightBlack: "brightBlack",
  ansiBrightRed: "brightRed",
  ansiBrightGreen: "brightGreen",
  ansiBrightYellow: "brightYellow",
  ansiBrightBlue: "brightBlue",
  ansiBrightMagenta: "brightMagenta",
  ansiBrightCyan: "brightCyan",
  ansiBrightWhite: "brightWhite",
};
