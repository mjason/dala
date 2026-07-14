import type { ITheme } from "@xterm/xterm";
import type { ResolvedTheme } from "./theme";

const terminalPalettes: Record<ResolvedTheme, ITheme> = {
  dark: {
    background: "#0b0c0e",
    foreground: "#d7dde3",
    cursor: "#4cc38a",
    cursorAccent: "#0b0c0e",
    selectionBackground: "#2d3f4d",
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
  },
  light: {
    background: "#f7f8fa",
    foreground: "#252b33",
    cursor: "#147a52",
    cursorAccent: "#ffffff",
    selectionBackground: "#c8dced",
    scrollbarSliderBackground: "rgba(66, 75, 87, 0.30)",
    scrollbarSliderHoverBackground: "rgba(66, 75, 87, 0.48)",
    scrollbarSliderActiveBackground: "rgba(66, 75, 87, 0.60)",
    black: "#252b33",
    red: "#b83333",
    green: "#24764c",
    yellow: "#8a5a00",
    blue: "#2469a3",
    magenta: "#7b4b96",
    cyan: "#187378",
    white: "#4f5965",
    brightBlack: "#68717d",
    brightRed: "#bd3434",
    brightGreen: "#287c51",
    brightYellow: "#946200",
    brightBlue: "#2871ac",
    brightMagenta: "#8652a0",
    brightCyan: "#1c7a80",
    brightWhite: "#252b33",
  },
};

export function terminalTheme(theme: ResolvedTheme): ITheme {
  return { ...terminalPalettes[theme] };
}

export type CodeMirrorColors = {
  bg0: string;
  bg1: string;
  bg2: string;
  line: string;
  fg: string;
  fgMuted: string;
  mint: string;
  comment: string;
  keyword: string;
  string: string;
  number: string;
  title: string;
  type: string;
  danger: string;
  selection: string;
  scrollbar: string;
  gutter: string;
  gutterText: string;
  activeLine: string;
  hunk: string;
};

const editorPalettes: Record<ResolvedTheme, CodeMirrorColors> = {
  dark: {
    bg0: "#0b0c0e",
    bg1: "#121417",
    bg2: "#1b1e23",
    line: "#24272c",
    fg: "#e6e8eb",
    fgMuted: "#8f96a0",
    mint: "#4cc38a",
    comment: "#6b7280",
    keyword: "#b087c9",
    string: "#5fbf87",
    number: "#d9a860",
    title: "#6d9fd6",
    type: "#5fb8b8",
    danger: "#e5716e",
    selection: "#2d3f4d",
    scrollbar: "#2c3037",
    gutter: "rgba(18, 20, 23, 0.5)",
    gutterText: "rgba(143, 150, 160, 0.45)",
    activeLine: "rgba(27, 30, 35, 0.55)",
    hunk: "rgba(27, 30, 35, 0.6)",
  },
  light: {
    bg0: "#f7f8fa",
    bg1: "#ffffff",
    bg2: "#e9edf2",
    line: "#d2d8e0",
    fg: "#1b2027",
    fgMuted: "#68717d",
    mint: "#147a52",
    comment: "#68717d",
    keyword: "#70418b",
    string: "#24764c",
    number: "#8a5a00",
    title: "#2469a3",
    type: "#187378",
    danger: "#b83333",
    selection: "#c8dced",
    scrollbar: "#b5bdc8",
    gutter: "rgba(233, 237, 242, 0.72)",
    gutterText: "rgba(104, 113, 125, 0.72)",
    activeLine: "rgba(221, 227, 234, 0.5)",
    hunk: "rgba(233, 237, 242, 0.8)",
  },
};

export function codeMirrorColors(theme: ResolvedTheme): CodeMirrorColors {
  return { ...editorPalettes[theme] };
}
