import { describe, expect, it } from "vitest";
import { codeMirrorColors, terminalTheme } from "./themePalette";

function luminance(hex: string): number {
  const channels = [1, 3, 5].map((index) => Number.parseInt(hex.slice(index, index + 2), 16) / 255);
  const [red, green, blue] = channels.map((value) =>
    value <= 0.04045 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4,
  );
  return 0.2126 * red + 0.7152 * green + 0.0722 * blue;
}

function contrast(first: string, second: string): number {
  const values = [luminance(first), luminance(second)].sort((a, b) => b - a);
  return (values[0] + 0.05) / (values[1] + 0.05);
}

describe("theme engine palettes", () => {
  it("provides distinct light and dark terminal chrome and ANSI colors", () => {
    const light = terminalTheme("light");
    const dark = terminalTheme("dark");

    expect(light.background).not.toBe(dark.background);
    expect(light.foreground).not.toBe(dark.foreground);
    expect(light.selectionBackground).not.toBe(dark.selectionBackground);
    expect(light.black).not.toBe(dark.black);
    expect(light.white).not.toBe(dark.white);
  });

  it("keeps all light terminal ANSI colors readable on the terminal background", () => {
    const palette = terminalTheme("light");
    const ansi = [
      "black",
      "red",
      "green",
      "yellow",
      "blue",
      "magenta",
      "cyan",
      "white",
      "brightBlack",
      "brightRed",
      "brightGreen",
      "brightYellow",
      "brightBlue",
      "brightMagenta",
      "brightCyan",
      "brightWhite",
    ] as const;

    for (const color of ansi) {
      expect(contrast(palette[color]!, palette.background!), color).toBeGreaterThanOrEqual(4.5);
    }
  });

  it("provides distinct light and dark editor chrome and syntax colors", () => {
    const light = codeMirrorColors("light");
    const dark = codeMirrorColors("dark");

    expect(light.bg0).not.toBe(dark.bg0);
    expect(light.fg).not.toBe(dark.fg);
    expect(light.keyword).not.toBe(dark.keyword);
    expect(light.selection).not.toBe(dark.selection);
  });
});
