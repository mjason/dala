import { describe, expect, it } from "vitest";
import { clampWidth, PANEL_W } from "./usePanelLayout";

describe("clampWidth", () => {
  it("keeps in-range values, rounded", () => {
    expect(clampWidth(300, 180, 440)).toBe(300);
    expect(clampWidth(300.6, 180, 440)).toBe(301);
  });

  it("clamps below min and above max", () => {
    expect(clampWidth(10, 180, 440)).toBe(180);
    expect(clampWidth(9999, 180, 440)).toBe(440);
  });

  it("never lets max drop below min (tiny windows)", () => {
    // e.g. qs panel: max = window.innerWidth - 160 can be < min on tiny windows
    expect(clampWidth(500, 380, 200)).toBe(380);
    expect(clampWidth(100, 380, 200)).toBe(380);
  });

  it("handles NaN-free defaults for every panel", () => {
    expect(clampWidth(PANEL_W.sidebar, 180, 440)).toBe(PANEL_W.sidebar);
    expect(clampWidth(PANEL_W.drawer, 260, 720)).toBe(PANEL_W.drawer);
    expect(clampWidth(PANEL_W.git, 280, 800)).toBe(PANEL_W.git);
  });
});
