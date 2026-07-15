/**
 * The built-in light/dark default value for every one of the 39 theme tokens.
 *
 * The theme editor shows these as the PLACEHOLDER for each colour row (the
 * value an omitted/未覆盖 token falls back to on the selected base) and as the
 * seed colour for the native `<input type="color">` swatch. Switching the
 * editor's base re-seeds the placeholders from the other palette, so a user
 * only ever overrides what they actually want to change.
 *
 * The 18 UI/diff/cm values are transcribed verbatim from app.css (`@theme`
 * for dark, `:root[data-theme="light"]` for light — the same blocks
 * TOKEN_TO_CSSVAR maps onto). The 21 terminal values are derived from the
 * canonical xterm palettes (terminalTheme.ts) via TOKEN_TO_ITHEME, so they
 * cannot drift from what the terminal actually renders.
 */
import { TERMINAL_PALETTES } from "./terminalTheme";
import type { EffectiveTheme } from "./theme";
import {
  TOKEN_TO_CSSVAR,
  TOKEN_TO_ITHEME,
  type CssVarTokenKey,
  type IThemeTokenKey,
  type TokenKey,
} from "./themeTokens";

/** UI/diff/cm defaults — verbatim from assets/css/app.css. */
const UI_BASE: Record<EffectiveTheme, Record<CssVarTokenKey, string>> = {
  dark: {
    bg0: "#0b0c0e",
    bg1: "#121417",
    bg2: "#1b1e23",
    line: "#24272c",
    fg: "#e6e8eb",
    fgMuted: "#8f96a0",
    mint: "#4cc38a",
    danger: "#f0716e",
    diffAddFg: "#5fbf87",
    diffDelFg: "#e5716e",
    diffHunk: "#7fd0d0",
    diffAddBg: "rgba(95, 191, 135, 0.11)",
    diffDelBg: "rgba(229, 113, 110, 0.1)",
    cmGutterBg: "rgba(18, 20, 23, 0.5)",
    cmGutterFg: "rgba(143, 150, 160, 0.45)",
    cmActiveBg: "rgba(27, 30, 35, 0.55)",
    cmHunkBg: "rgba(27, 30, 35, 0.6)",
    cmSelection: "#2d3f4d",
  },
  light: {
    bg0: "#fbfbfa",
    bg1: "#f3f3f1",
    bg2: "#e8e8e4",
    line: "#dcdcd6",
    fg: "#1c1e21",
    fgMuted: "#5f666e",
    mint: "#0c7a4f",
    danger: "#c92f2c",
    diffAddFg: "#116329",
    diffDelFg: "#b31d28",
    diffHunk: "#0969da",
    diffAddBg: "#aae7ba",
    diffDelBg: "#ffd0cd",
    cmGutterBg: "rgba(0, 0, 0, 0.03)",
    cmGutterFg: "#5f666e",
    cmActiveBg: "rgba(0, 0, 0, 0.04)",
    cmHunkBg: "rgba(0, 0, 0, 0.05)",
    cmSelection: "#cfe3fb",
  },
};

/** True when a token maps onto a `--color-*` CSS var (UI/diff/cm group). */
function cssVarToken(key: TokenKey): key is CssVarTokenKey {
  return key in TOKEN_TO_CSSVAR;
}

/** The built-in default value for `key` at the given base palette. */
export function baseTokenValue(base: EffectiveTheme, key: TokenKey): string {
  if (cssVarToken(key)) return UI_BASE[base][key];
  const field = TOKEN_TO_ITHEME[key as IThemeTokenKey];
  return (TERMINAL_PALETTES[base][field] as string | undefined) ?? "";
}

/** The full 39-token default palette for a base (every token filled). */
export function baseTokens(base: EffectiveTheme): Record<TokenKey, string> {
  const out = {} as Record<TokenKey, string>;
  for (const key of Object.keys(TOKEN_TO_CSSVAR) as CssVarTokenKey[]) {
    out[key] = UI_BASE[base][key];
  }
  for (const key of Object.keys(TOKEN_TO_ITHEME) as IThemeTokenKey[]) {
    out[key] = (TERMINAL_PALETTES[base][TOKEN_TO_ITHEME[key]] as string | undefined) ?? "";
  }
  return out;
}
