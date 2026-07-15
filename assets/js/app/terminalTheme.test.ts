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
});
