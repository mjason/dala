import { describe, expect, it } from "vitest";
import { TERMINAL_PALETTES, terminalTheme } from "./terminalTheme";

describe("terminalTheme", () => {
  it("maps the dark app theme to the dark terminal palette (bg0)", () => {
    const t = terminalTheme("dark");
    expect(t).toBe(TERMINAL_PALETTES.dark);
    expect(t.background).toBe("#0b0c0e");
    expect(t.foreground).toBe("#d7dde3");
  });

  it("maps the light app theme to the light terminal palette (off-white bg)", () => {
    const t = terminalTheme("light");
    expect(t).toBe(TERMINAL_PALETTES.light);
    expect(t.background).toBe("#fbfbfa");
    expect(t.foreground).toBe("#1c1e21");
  });

  it("the two palettes have distinct backgrounds and cursors", () => {
    expect(terminalTheme("light").background).not.toBe(terminalTheme("dark").background);
    expect(terminalTheme("light").cursor).not.toBe(terminalTheme("dark").cursor);
  });

  it("light scrollbar sliders are translucent black (visible on a pale bg)", () => {
    expect(terminalTheme("light").scrollbarSliderBackground).toContain("rgba(0, 0, 0");
    expect(terminalTheme("dark").scrollbarSliderBackground).toContain("rgba(255, 255, 255");
  });

  it("a one-arg call still returns the shared palette by reference", () => {
    // Existing callers (mount, no custom theme) must keep working unchanged.
    expect(terminalTheme("dark")).toBe(TERMINAL_PALETTES.dark);
    expect(terminalTheme("light")).toBe(TERMINAL_PALETTES.light);
  });

  it("merges overrides over the base palette; omitted keys fall back", () => {
    const merged = terminalTheme("dark", {
      background: "#101010",
      red: "#ff0000",
    });
    // A fresh object, not the shared palette.
    expect(merged).not.toBe(TERMINAL_PALETTES.dark);
    // Overrides win.
    expect(merged.background).toBe("#101010");
    expect(merged.red).toBe("#ff0000");
    // Every OTHER field falls back to the full base palette — including all
    // 16 ANSI slots and the non-token scrollbar colors.
    expect(merged.foreground).toBe(TERMINAL_PALETTES.dark.foreground);
    expect(merged.brightWhite).toBe(TERMINAL_PALETTES.dark.brightWhite);
    expect(merged.green).toBe(TERMINAL_PALETTES.dark.green);
    expect(merged.scrollbarSliderBackground).toBe(
      TERMINAL_PALETTES.dark.scrollbarSliderBackground,
    );
  });

  it("an empty overrides object leaves the full palette intact (fresh copy)", () => {
    const merged = terminalTheme("light", {});
    expect(merged).not.toBe(TERMINAL_PALETTES.light);
    expect(merged).toEqual(TERMINAL_PALETTES.light);
  });
});
