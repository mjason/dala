/**
 * xterm color palettes for the two app themes. Kept out of TerminalView so
 * the palette-selection logic is pure and unit-testable. `terminalTheme()`
 * maps an effective app theme ("light"/"dark") to the object xterm's
 * `theme` option expects; TerminalView applies it on mount and live on
 * theme flips (see onThemeChange).
 */
import type { ITheme } from "@xterm/xterm";
import type { EffectiveTheme } from "./theme";

// Dark palette — the original terminal-first neutral scheme. background/
// foreground track --color-bg0 / a soft off-white.
const dark: ITheme = {
  background: "#0b0c0e",
  foreground: "#d7dde3",
  cursor: "#4cc38a",
  cursorAccent: "#0b0c0e",
  selectionBackground: "#2d3f4d",
  // xterm 6 draws its own DOM scrollbar (VS Code's scrollable-element) —
  // ::-webkit-scrollbar CSS never touches it; colors come from the theme
  // and the pill shape from app.css. macOS dark-mode overlay thumb is
  // translucent white, not gray.
  scrollbarSliderBackground: "rgba(255, 255, 255, 0.28)",
  scrollbarSliderHoverBackground: "rgba(255, 255, 255, 0.45)",
  scrollbarSliderActiveBackground: "rgba(255, 255, 255, 0.55)",
  black: "#1a1d21",
  red: "#e5716e",
  green: "#5fbf87",
  yellow: "#d9a860",
  blue: "#6d9fd6",
  magenta: "#b087c9",
  cyan: "#5fb8b8",
  white: "#c9ced4",
  brightBlack: "#5b626b",
  brightRed: "#f0928f",
  brightGreen: "#7fd6a3",
  brightYellow: "#ecc57f",
  brightBlue: "#8fb8e8",
  brightMagenta: "#c9a5dd",
  brightCyan: "#7fd0d0",
  brightWhite: "#e6e8eb",
};

// Light palette — GitHub-Light-ish ANSI over the app's warm off-white
// (--color-bg0 light = #fbfbfa). ANSI colors are the darker "text" variants
// so they stay readable on the pale background; the cursor keeps the brand
// mint (darkened for contrast) and selection is a soft blue that shows on
// white. The scrollbar thumb becomes translucent BLACK (white is invisible
// on light).
const light: ITheme = {
  background: "#fbfbfa",
  foreground: "#1c1e21",
  cursor: "#0c7a4f",
  cursorAccent: "#fbfbfa",
  selectionBackground: "#cfe3fb",
  scrollbarSliderBackground: "rgba(0, 0, 0, 0.22)",
  scrollbarSliderHoverBackground: "rgba(0, 0, 0, 0.38)",
  scrollbarSliderActiveBackground: "rgba(0, 0, 0, 0.48)",
  black: "#24292e",
  red: "#cf222e",
  green: "#116329",
  yellow: "#9a6700",
  blue: "#0969da",
  magenta: "#8250df",
  cyan: "#1b7c83",
  white: "#6e7781",
  brightBlack: "#57606a",
  brightRed: "#a40e26",
  brightGreen: "#1a7f37",
  brightYellow: "#7d4e00",
  brightBlue: "#218bff",
  brightMagenta: "#a475f9",
  brightCyan: "#3192aa",
  brightWhite: "#24292f",
};

export const TERMINAL_PALETTES: Record<EffectiveTheme, ITheme> = { dark, light };

/** The xterm theme object for an effective app theme. */
export function terminalTheme(theme: EffectiveTheme): ITheme {
  return TERMINAL_PALETTES[theme];
}
